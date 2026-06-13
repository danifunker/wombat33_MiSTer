-- MAME Lua script: capture FPU instruction state from maciihmu.
--
-- Drives MAME as an FPU oracle to produce JSON test corpora that the
-- SingleStepTests/fpu bench can consume.
--
-- Strategy: per test we plant a small instruction stream at $1000:
--   preload  → init-state dump → test instruction → final-state dump → STOP
-- Then we hijack PC, resume the CPU, wait for PC to reach the STOP, pause
-- again, read both dump windows back from RAM, advance to the next test.
--
-- Implementation is a frame-driven state machine. The Lua engine only
-- gets control between MAME frames (via the periodic/frame_done hooks),
-- so we cannot block waiting for the CPU to run — we let it run for a
-- frame, then come back and check progress.
--
-- USAGE
-- -----
--   ../mame/maciihmu maciihmu -bios original -skip_gameinfo \
--     -debug -debugger none -window -nothrottle \
--     -autoboot_delay 1 \
--     -autoboot_script SingleStepTests/gen/mame_fpu_capture.lua
--
-- Why these flags:
--   maciihmu maciihmu : binary name + system arg (yes, twice)
--   -bios original    : rev. A ROM
--   -skip_gameinfo    : skip system info screen
--   -debug            : skips the disclaimer/warnings screens
--                       (UI's display_startup_screens uses
--                        DEBUG_FLAG_ENABLED to disable both)
--   -debugger none    : but DON'T open the debugger UI window
--   -nothrottle       : run as fast as host can (we want to exit ASAP)
--   -autoboot_delay 1 : let one second pass before our Lua hook fires
--                       so the boot ROM has time to flip the overlay
--                       bit and map RAM at $0..
--
-- MAME exits automatically once the corpus is written.

local FPU_OUT_PATH = "/tmp/fpu_corpus.json"

local PROG_BASE   = 0x00001000
local INIT_DUMP   = 0x00002000
local FINAL_DUMP  = 0x00002200
-- Exception vector table — we own all 256 vectors so any spurious trap
-- (F-line, address error, FPU protocol, bus error, etc) lands at
-- stop_pc instead of bouncing into the boot ROM's handlers.
local VEC_BASE    = 0x00000000
local VEC_COUNT   = 256

-- Tests are generated below the emit helpers (search "TEST GENERATOR").
-- Each entry produces ONE corpus entry: { name, preload, test }.
local tests

-- ----------------------------------------------------------------------
-- Handles + helpers
-- ----------------------------------------------------------------------
local cpu, prog
local function init_handles()
    cpu  = manager.machine.devices[":maincpu"]
    prog = cpu.spaces["program"]
end

local function rget(name) return cpu.state[name].value end
local function rset(name, v) cpu.state[name].value = v end

local function write_bytes(addr, bytes)
    for i, b in ipairs(bytes) do
        prog:write_u8(addr + i - 1, b)
    end
end

local function read_bytes(addr, n)
    local out = {}
    for i = 0, n - 1 do out[#out + 1] = prog:read_u8(addr + i) end
    return out
end

local function hexstr(bytes)
    local out = {}
    for i = 1, #bytes do out[i] = string.format("%02x", bytes[i]) end
    return table.concat(out)
end

-- Instruction emitters --------------------------------------------------

-- FMOVE.X FPn,(An)+  --  4 bytes of opcode/ext, writes 12 bytes of data.
-- MAME's m68kfpu doesn't implement FMOVE.X to abs.L (EA mode 7 reg 1) —
-- it bails with "WRITE_EA_FPE: unhandled mode 7, reg 1" — so we use the
-- postincrement form with an address register we've pre-loaded.
-- ext encoding:
--   bits 15-13 = 011  (move FP -> EA)
--   bits 12-10 = 010  (size = X, extended-precision real)
--   bits  9-7  = SSS  (source FP register)
--   bits  6-0  = 0    (k-factor, ignored for X)
local function emit_fmove_x_to_an_postinc(fpn, an)
    local opword = 0xF218 | (an & 7)
    local ext    = 0x6800 | (fpn << 7)
    return {
        (opword >> 8) & 0xFF, opword & 0xFF,
        (ext    >> 8) & 0xFF, ext    & 0xFF,
    }
end

-- MOVEA.L #imm32,An  --  6 bytes
local function emit_movea_l_imm_to_an(an, imm)
    local opword = 0x207C | ((an & 7) << 9)
    return {
        (opword >> 8) & 0xFF, opword & 0xFF,
        (imm >> 24) & 0xFF, (imm >> 16) & 0xFF,
        (imm >>  8) & 0xFF,  imm        & 0xFF,
    }
end

-- MOVE.L Dn,(abs.L)  --  6 bytes
local function emit_move_l_dn_to_abs(dn, abs_addr)
    local opword = 0x23C0 | (dn & 7)
    return {
        (opword >> 8) & 0xFF, opword & 0xFF,
        (abs_addr >> 24) & 0xFF, (abs_addr >> 16) & 0xFF,
        (abs_addr >>  8) & 0xFF,  abs_addr        & 0xFF,
    }
end

-- MOVE.L An,(abs.L)  --  6 bytes
local function emit_move_l_an_to_abs(an, abs_addr)
    local opword = 0x23C8 | (an & 7)
    return {
        (opword >> 8) & 0xFF, opword & 0xFF,
        (abs_addr >> 24) & 0xFF, (abs_addr >> 16) & 0xFF,
        (abs_addr >>  8) & 0xFF,  abs_addr        & 0xFF,
    }
end

-- FMOVE.L FPcr,(abs.L)  --  8 bytes. ext encoding:
--   bits 15-13 = 101  (move FP system control reg -> EA)
--   bit  12    = FPCR (1 -> include)
--   bit  11    = FPSR
--   bit  10    = FPIAR
--   bits  9-0  = 0
-- Caller passes one of: 0x1000 (FPCR), 0x0800 (FPSR), 0x0400 (FPIAR).
local function emit_fmove_l_fpcr_to_abs(reg_mask, abs_addr)
    local opword = 0xF239  -- coproc id 1, mode=111/reg=001 (abs.L)
    local ext = 0xA000 | reg_mask
    return {
        (opword >> 8) & 0xFF, opword & 0xFF,
        (ext    >> 8) & 0xFF, ext    & 0xFF,
        (abs_addr >> 24) & 0xFF, (abs_addr >> 16) & 0xFF,
        (abs_addr >>  8) & 0xFF,  abs_addr        & 0xFF,
    }
end

-- State dump block: A0..A7, FP0..FP7, D0..D7, FPCR/FPSR/FPIAR.
-- We dump A regs FIRST (while A0 is still original), then sacrifice A0
-- as the FP postincrement pointer.
-- Layout in RAM[dump_base..]:
--   +0x00..0x5F : FP0..FP7 (12 bytes each)
--   +0x60..0x7F : D0..D7 (4 bytes each)
--   +0x80..0x9F : A0..A7 (4 bytes each)
--   +0xA0..0xA3 : FPCR
--   +0xA4..0xA7 : FPSR
--   +0xA8..0xAB : FPIAR
local function emit_state_dump(dump_base)
    local out = {}
    local function append(t)
        for _, b in ipairs(t) do out[#out + 1] = b end
    end
    -- A regs first (writes the test-time A0..A7 into the dump).
    for an = 0, 7 do
        append(emit_move_l_an_to_abs(an, dump_base + 0x80 + an * 4))
    end
    -- Now repurpose A0 as the FP register dump pointer.
    append(emit_movea_l_imm_to_an(0, dump_base))
    for fpn = 0, 7 do
        append(emit_fmove_x_to_an_postinc(fpn, 0))
    end
    -- D regs: A0 is clobbered but D regs are independent.
    for dn = 0, 7 do
        append(emit_move_l_dn_to_abs(dn, dump_base + 0x60 + dn * 4))
    end
    append(emit_fmove_l_fpcr_to_abs(0x1000, dump_base + 0xA0)) -- FPCR
    append(emit_fmove_l_fpcr_to_abs(0x0800, dump_base + 0xA4)) -- FPSR
    append(emit_fmove_l_fpcr_to_abs(0x0400, dump_base + 0xA8)) -- FPIAR
    return out
end

-- Read the dump block back from RAM into a snapshot table.
local function read_snap(base)
    local snap = { fp = {}, d = {}, a = {} }
    for fpn = 0, 7 do
        snap.fp[fpn] = hexstr(read_bytes(base + fpn * 12, 12))
    end
    for dn = 0, 7 do
        local b = read_bytes(base + 0x60 + dn * 4, 4)
        snap.d[dn] = (b[1] << 24) | (b[2] << 16) | (b[3] << 8) | b[4]
    end
    for an = 0, 7 do
        local b = read_bytes(base + 0x80 + an * 4, 4)
        snap.a[an] = (b[1] << 24) | (b[2] << 16) | (b[3] << 8) | b[4]
    end
    local function read_u32(off)
        local b = read_bytes(base + off, 4)
        return (b[1] << 24) | (b[2] << 16) | (b[3] << 8) | b[4]
    end
    snap.fpcr  = read_u32(0xA0)
    snap.fpsr  = read_u32(0xA4)
    snap.fpiar = read_u32(0xA8)
    return snap
end

-- ======================================================================
-- TEST GENERATOR
--
-- Operand pool: each value is a 12-byte 68881 extended-precision big-
-- endian representation. Loaded into FP registers via FMOVE.X #imm,FPn
-- so the preload exercises no conversion (the value lands in the FP
-- register exactly as written).
-- ======================================================================

local OPERANDS = {
    -- Trivial values
    pos_zero   = {0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00},
    neg_zero   = {0x80,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00},
    pos_one    = {0x3F,0xFF,0x00,0x00, 0x80,0x00,0x00,0x00, 0x00,0x00,0x00,0x00},
    neg_one    = {0xBF,0xFF,0x00,0x00, 0x80,0x00,0x00,0x00, 0x00,0x00,0x00,0x00},
    pos_two    = {0x40,0x00,0x00,0x00, 0x80,0x00,0x00,0x00, 0x00,0x00,0x00,0x00},
    neg_two    = {0xC0,0x00,0x00,0x00, 0x80,0x00,0x00,0x00, 0x00,0x00,0x00,0x00},
    pos_half   = {0x3F,0xFE,0x00,0x00, 0x80,0x00,0x00,0x00, 0x00,0x00,0x00,0x00},
    neg_half   = {0xBF,0xFE,0x00,0x00, 0x80,0x00,0x00,0x00, 0x00,0x00,0x00,0x00},
    pos_three  = {0x40,0x00,0x00,0x00, 0xC0,0x00,0x00,0x00, 0x00,0x00,0x00,0x00},
    -- Famous constants (correct to extended precision)
    pi         = {0x40,0x00,0x00,0x00, 0xC9,0x0F,0xDA,0xA2, 0x21,0x68,0xC2,0x35},
    pi_half    = {0x3F,0xFF,0x00,0x00, 0xC9,0x0F,0xDA,0xA2, 0x21,0x68,0xC2,0x35},
    pi_quarter = {0x3F,0xFE,0x00,0x00, 0xC9,0x0F,0xDA,0xA2, 0x21,0x68,0xC2,0x35},
    e          = {0x40,0x00,0x00,0x00, 0xAD,0xF8,0x54,0x58, 0xA2,0xBB,0x4A,0x9A},
    ten        = {0x40,0x02,0x00,0x00, 0xA0,0x00,0x00,0x00, 0x00,0x00,0x00,0x00},
    -- Magnitude extremes
    big        = {0x40,0x40,0x00,0x00, 0x80,0x00,0x00,0x00, 0x00,0x00,0x00,0x00}, -- 2^65
    tiny       = {0x3F,0xC0,0x00,0x00, 0x80,0x00,0x00,0x00, 0x00,0x00,0x00,0x00}, -- 2^-63
    -- Specials
    pos_inf    = {0x7F,0xFF,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00},
    neg_inf    = {0xFF,0xFF,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00},
    qnan       = {0x7F,0xFF,0x00,0x00, 0xC0,0x00,0x00,0x00, 0x00,0x00,0x00,0x00},
}

-- FMOVE.X #imm,FPn  --  4 bytes opword/ext + 12 bytes extended-precision
-- opword F23C: coproc 1, EA mode 111/reg 100 (immediate)
-- ext: bits 15-13 = 010 (EA->FP), bits 12-10 = 010 (size X),
--      bits 9-7 = dest FPn, bits 6-0 = 0
local function emit_fmove_x_imm_to_fp(fpn, op_bytes)
    local opword = 0xF23C
    local ext    = 0x4800 | (fpn << 7)
    local out = {
        (opword >> 8) & 0xFF, opword & 0xFF,
        (ext    >> 8) & 0xFF, ext    & 0xFF,
    }
    for _, b in ipairs(op_bytes) do out[#out + 1] = b end
    return out
end

-- Register-direct FP op: FPm -> FPn, R/M = 0.
-- opword: 0xF200 (no EA needed; src is the SSS field in ext).
-- ext: bit 15 = 0, bit 14 = 0 (R/M=0 -> source is an FP reg),
--      bits 12-10 = SSS (src FP reg), bits 9-7 = DDD (dst FP reg),
--      bits 6-0 = opmode.
local function emit_fop_x_reg_to_reg(opmode, src_fpn, dst_fpn)
    local opword = 0xF200
    local ext    = ((src_fpn & 7) << 10)
                 | ((dst_fpn & 7) << 7)
                 |  (opmode  & 0x7F)
    return {
        (opword >> 8) & 0xFF, opword & 0xFF,
        (ext    >> 8) & 0xFF, ext    & 0xFF,
    }
end

local function concat_bytes(...)
    local out = {}
    for _, t in ipairs({...}) do
        for _, b in ipairs(t) do out[#out + 1] = b end
    end
    return out
end

local function make_dyadic_test(op, a_name, b_name)
    return {
        name = string.format("%s.X FP1,FP0 (%s,%s)", op.name, a_name, b_name),
        preload = concat_bytes(
            emit_fmove_x_imm_to_fp(0, OPERANDS[a_name]),
            emit_fmove_x_imm_to_fp(1, OPERANDS[b_name])
        ),
        test = emit_fop_x_reg_to_reg(op.opmode, 1, 0),  -- src=FP1, dst=FP0
    }
end

local function make_monadic_test(op, a_name)
    return {
        name = string.format("%s.X FP0 (%s)", op.name, a_name),
        preload = emit_fmove_x_imm_to_fp(0, OPERANDS[a_name]),
        test = emit_fop_x_reg_to_reg(op.opmode, 0, 0),
    }
end

local DYADIC_OPS = {
    {name="FADD",    opmode=0x22},
    {name="FSUB",    opmode=0x28},
    {name="FMUL",    opmode=0x23},
    {name="FDIV",    opmode=0x20},
    {name="FCMP",    opmode=0x38},  -- writes FPCC only, no result reg
    {name="FMOD",    opmode=0x21},
    {name="FREM",    opmode=0x25},
    {name="FSCALE",  opmode=0x26},
    {name="FSGLDIV", opmode=0x24},
    {name="FSGLMUL", opmode=0x27},
}

local MONADIC_OPS = {
    {name="FABS",    opmode=0x18},
    {name="FNEG",    opmode=0x1A},
    {name="FSQRT",   opmode=0x04},
    {name="FINT",    opmode=0x01},
    {name="FINTRZ",  opmode=0x03},
    {name="FGETEXP", opmode=0x1E},
    {name="FGETMAN", opmode=0x1F},
    {name="FTST",    opmode=0x3A},  -- writes FPCC only
}

-- Transcendentals that MAME's m68kfpu actually implements. Skipped (real
-- hardware does these but MAME crashes with "unimplemented opmode"):
--   FASIN  (0x0C), FACOS  (0x1C), FATANH (0x0D),
--   FSINH  (0x02), FCOSH  (0x19), FTANH  (0x09).
-- These should still be tested on real hardware once we have a Mac-side
-- bench, but until MAME implements them they can't be oracle-checked.
local TRANSCENDENTAL_OPS = {
    {name="FSIN",    opmode=0x0E},
    {name="FCOS",    opmode=0x1D},
    {name="FTAN",    opmode=0x0F},
    {name="FATAN",   opmode=0x0A},
    {name="FETOX",   opmode=0x10},
    {name="FETOXM1", opmode=0x08},
    {name="FLOGN",   opmode=0x14},
    {name="FLOG10",  opmode=0x15},
    {name="FLOG2",   opmode=0x16},
    {name="FLOGNP1", opmode=0x06},
    {name="FTENTOX", opmode=0x12},
    {name="FTWOTOX", opmode=0x11},
}

-- Operand pairs for the dyadic sweep. Chosen to exercise: identity,
-- commutativity, sign combos, magnitude differences, infinity arithmetic,
-- NaN propagation, division-by-zero, and modulo-style ops.
local DYADIC_PAIRS = {
    {"pos_one",  "pos_one"},   -- 1 op 1
    {"pos_one",  "pos_two"},   -- 1 op 2
    {"pos_two",  "pos_one"},   -- 2 op 1 (non-commutative check)
    {"pos_one",  "neg_one"},   -- 1 op -1
    {"pi",       "e"},         -- transcendental constants
    {"pos_one",  "pos_zero"},  -- 1 op 0 (DIV by zero!)
    {"pos_zero", "pos_one"},   -- 0 op 1
    {"pos_inf",  "pos_one"},   -- inf arithmetic
    {"pos_inf",  "pos_inf"},   -- inf op inf
    {"pos_one",  "qnan"},      -- NaN propagation
    {"big",      "tiny"},      -- magnitude mismatch
    {"ten",      "pos_three"}, -- non-power-of-two
}

-- Operands for monadic ops -- broad coverage of sign / magnitude / special.
local MONADIC_VALUES = {
    "pos_zero", "neg_zero",
    "pos_one",  "neg_one",
    "pos_two",  "pos_half",
    "pi",       "e",
    "pos_inf",  "neg_inf",
    "qnan",
}

-- Operands for transcendentals: same idea but tighter, since each op
-- has a different "natural" domain.
local TRANS_VALUES = {
    "pos_zero", "pos_half", "pos_one", "pi_quarter", "pi",
}

-- ----------------------------------------------------------------------
-- Assemble the full `tests` list.
-- ----------------------------------------------------------------------
tests = {
    -- Smoke tests (preserved from the bring-up phase; cheap insurance).
    { name = "DBG: MOVEQ #5,D0 (no FPU)",
      preload = {},
      test    = { 0x70, 0x05 } },
    { name = "FMOVE.L #1,FP0 (sanity)",
      preload = {},
      test    = { 0x70, 0x01, 0xF2, 0x00, 0x40, 0x00 } },
}

for _, op in ipairs(DYADIC_OPS) do
    for _, pair in ipairs(DYADIC_PAIRS) do
        tests[#tests + 1] = make_dyadic_test(op, pair[1], pair[2])
    end
end

for _, op in ipairs(MONADIC_OPS) do
    for _, val in ipairs(MONADIC_VALUES) do
        tests[#tests + 1] = make_monadic_test(op, val)
    end
end

for _, op in ipairs(TRANSCENDENTAL_OPS) do
    for _, val in ipairs(TRANS_VALUES) do
        tests[#tests + 1] = make_monadic_test(op, val)
    end
end

print(string.format("Corpus has %d tests "
    .. "(%d dyadic, %d monadic, %d transcendental, 2 smoke).",
    #tests,
    #DYADIC_OPS * #DYADIC_PAIRS,
    #MONADIC_OPS * #MONADIC_VALUES,
    #TRANSCENDENTAL_OPS * #TRANS_VALUES))

-- ----------------------------------------------------------------------
-- Emit a self-contained C header (fpu_tests.h) with the same test
-- specs as a static array, so the Mac-side bench can consume the
-- identical corpus without re-encoding anything. Always written
-- alongside the MAME run so the header and the oracle JSONL stay in
-- lockstep.
-- ----------------------------------------------------------------------
local TESTS_H_PATH = "/tmp/fpu_tests.h"

local function emit_tests_h(path)
    local f = io.open(path, "w")
    if f == nil then
        print("WARNING: cannot write " .. path)
        return
    end
    f:write("/* Auto-generated by SingleStepTests/gen/mame_fpu_capture.lua.\n")
    f:write(" * Do not edit by hand -- regenerate by re-running the script. */\n")
    f:write("#ifndef FPU_TESTS_H\n")
    f:write("#define FPU_TESTS_H\n\n")
    -- Compute actual max widths so we don't over-allocate in C land.
    local max_pre, max_tst = 0, 0
    for _, t in ipairs(tests) do
        if #t.preload > max_pre then max_pre = #t.preload end
        if #t.test    > max_tst then max_tst = #t.test    end
    end
    -- Round up for headroom when new tests are added.
    local pre_cap = math.max(max_pre, 40)
    local tst_cap = math.max(max_tst,  8)
    f:write(string.format("#define FPU_TEST_MAX_PRELOAD %d  /* widest preload observed: %d */\n",
        pre_cap, max_pre))
    f:write(string.format("#define FPU_TEST_MAX_TEST    %d  /* widest test bytes observed: %d */\n",
        tst_cap, max_tst))
    f:write("\n")
    f:write("typedef struct {\n")
    f:write("    const char *name;\n")
    f:write("    unsigned char preload[FPU_TEST_MAX_PRELOAD];\n")
    f:write("    unsigned short preload_len;\n")
    f:write("    unsigned char test[FPU_TEST_MAX_TEST];\n")
    f:write("    unsigned short test_len;\n")
    f:write("} FpuTestSpec;\n\n")
    f:write("static const FpuTestSpec g_fpu_tests[] = {\n")
    for _, t in ipairs(tests) do
        local pre_str
        if #t.preload == 0 then
            pre_str = "{0}"
        else
            local parts = {}
            for _, b in ipairs(t.preload) do
                parts[#parts + 1] = string.format("0x%02X", b)
            end
            pre_str = "{" .. table.concat(parts, ",") .. "}"
        end
        local tst_parts = {}
        for _, b in ipairs(t.test) do
            tst_parts[#tst_parts + 1] = string.format("0x%02X", b)
        end
        local tst_str = "{" .. table.concat(tst_parts, ",") .. "}"
        f:write(string.format("    {%q,\n", t.name))
        f:write(string.format("      %s, %d,\n", pre_str, #t.preload))
        f:write(string.format("      %s, %d},\n", tst_str, #t.test))
    end
    f:write("};\n\n")
    f:write("#define FPU_N_TESTS "
        .. "((unsigned short)(sizeof(g_fpu_tests)/sizeof(g_fpu_tests[0])))\n\n")
    f:write("#endif /* FPU_TESTS_H */\n")
    f:close()
    print(string.format("Wrote C header (%d tests) to %s", #tests, path))
end

emit_tests_h(TESTS_H_PATH)

-- ----------------------------------------------------------------------
-- JSON Lines emission. One JSON object per line so a partial run leaves
-- a valid file even if MAME crashes mid-corpus on an unimplemented FPU
-- instruction. Consumers do  `[json.loads(l) for l in open(path)]`.
-- ----------------------------------------------------------------------
local function snap_to_string(s)
    local buf = { "{\"d\":[" }
    for i = 0, 7 do
        buf[#buf + 1] = (i == 0 and "" or ",") .. tostring(s.d[i])
    end
    buf[#buf + 1] = "],\"a\":["
    for i = 0, 7 do
        buf[#buf + 1] = (i == 0 and "" or ",") .. tostring(s.a[i])
    end
    buf[#buf + 1] = "],\"fp\":["
    for i = 0, 7 do
        buf[#buf + 1] = (i == 0 and "" or ",") .. '"' .. s.fp[i] .. '"'
    end
    buf[#buf + 1] = string.format(
        "],\"fpcr\":%d,\"fpsr\":%d,\"fpiar\":%d}",
        s.fpcr, s.fpsr, s.fpiar)
    return table.concat(buf)
end

local function emit_entry(file, name, initial, final)
    file:write(string.format("{\"name\":%q,\"initial\":%s,\"final\":%s}\n",
        name, snap_to_string(initial), snap_to_string(final)))
    file:flush()
end

-- ----------------------------------------------------------------------
-- Frame-driven state machine
--
-- Phases:
--   WAIT_RAM    : poll RAM at $1000 each frame until writable.
--   SETUP_NEXT  : pause CPU, plant next test program, set PC, resume.
--                 Goes directly to RUN.
--   RUN         : every frame, check if PC is at our stop address; if so,
--                 pause, capture, advance.
--   DONE        : write JSON, exit MAME.
-- ----------------------------------------------------------------------
local RAM_PROBE_VALUE = 0xDEADBEEF
local MAX_WAIT_FRAMES = 1800
local MAX_RUN_FRAMES  = 120     -- per test; ~2 sec headroom

local phase    = "WAIT_RAM"
local frames   = 0
local test_i   = 1
local stop_pc  = 0
local out_file = nil    -- opened once RAM is up, written to incrementally
local n_written = 0

local function start_test(t)
    -- Pre-fill dump areas with a sentinel so we can tell at JSON-read
    -- time which bytes were actually written by the dump code.
    for i = 0, 0xAB do
        prog:write_u8(INIT_DUMP  + i, 0xCD)
        prog:write_u8(FINAL_DUMP + i, 0xCD)
    end

    -- Build the instruction stream.
    local out = {}
    local function append(bs)
        for _, b in ipairs(bs) do out[#out + 1] = b end
    end
    -- No explicit FPU "wake" — MAME's software FPU accepts instructions
    -- regardless of 68881 NULL/IDLE/BUSY state, so FRESTORE adds nothing
    -- but complications (FRESTORE of a NULL frame in fact puts the FPU
    -- *into* NULL state, breaking subsequent FP instructions).
    append(t.preload)
    append(emit_state_dump(INIT_DUMP))
    -- Record the offset of the start of the test instruction and the
    -- start of the final dump so exception vectors can land at the
    -- final dump (capturing whatever state we got to before the trap).
    local final_dump_off = nil
    append(t.test)
    final_dump_off = #out
    append(emit_state_dump(FINAL_DUMP))
    local jmp_pc = PROG_BASE + #out
    append({
        0x4E, 0xF9,
        (jmp_pc >> 24) & 0xFF, (jmp_pc >> 16) & 0xFF,
        (jmp_pc >>  8) & 0xFF,  jmp_pc        & 0xFF,
    })
    stop_pc = jmp_pc
    local final_dump_pc = PROG_BASE + final_dump_off

    write_bytes(PROG_BASE, out)

    -- Vectors point at the start of the final dump: any trap during
    -- preload/test still produces a final-state dump rather than stale
    -- data from a previous test.
    for v = 0, VEC_COUNT - 1 do
        prog:write_u32(VEC_BASE + v * 4, final_dump_pc)
    end

    -- Reset core registers. SR = $2700 (supervisor, interrupts masked
    -- level 7) — critical because the running maciihmu machine keeps
    -- firing VBL/timer interrupts; without masking, PC bounces back to
    -- the ROM interrupt handler every frame.
    for r = 0, 7 do rset("D" .. r, 0); rset("A" .. r, 0) end
    rset("SR", 0x2700)
    rset("A7", 0x00200000)
    rset("PC", PROG_BASE)
    -- Point VBR at our vector table so traps don't bounce into ROM.
    rset("VBR", VEC_BASE)
    -- Also clear SFC/DFC and CACR so no surprise side effects.
    if cpu.state["SFC"]  then rset("SFC", 0) end
    if cpu.state["DFC"]  then rset("DFC", 0) end
    if cpu.state["CACR"] then rset("CACR", 0) end
    frames  = 0
end

local function tick()
    init_handles()

    if phase == "WAIT_RAM" then
        prog:write_u32(PROG_BASE, RAM_PROBE_VALUE)
        local rb = prog:read_u32(PROG_BASE)
        frames = frames + 1
        if rb == RAM_PROBE_VALUE then
            print(string.format("RAM mapped at $%08X after %d frames.",
                PROG_BASE, frames))
            out_file = io.open(FPU_OUT_PATH, "w")
            if out_file == nil then
                print("ERROR: cannot open " .. FPU_OUT_PATH)
                phase = "ABORT"
                return
            end
            phase  = "SETUP_NEXT"
            frames = 0
        elseif frames >= MAX_WAIT_FRAMES then
            print(string.format("ERROR: RAM never mapped at $%08X.", PROG_BASE))
            phase = "ABORT"
        end

    elseif phase == "SETUP_NEXT" then
        if test_i > #tests then
            phase = "DONE"
            return
        end
        local t = tests[test_i]
        print(string.format("[%d/%d] %s", test_i, #tests, t.name))
        emu.pause()
        start_test(t)
        emu.unpause()
        phase = "RUN"

    elseif phase == "RUN" then
        frames = frames + 1
        local pc = rget("PC")
        -- The test ends with a JMP-to-self at stop_pc; PC sticking
        -- there means the test instruction stream has completed.
        if pc == stop_pc then
            emu.pause()
            local t = tests[test_i]
            emit_entry(out_file, t.name,
                read_snap(INIT_DUMP),
                read_snap(FINAL_DUMP))
            n_written = n_written + 1
            test_i = test_i + 1
            phase  = "SETUP_NEXT"
        elseif frames >= MAX_RUN_FRAMES then
            print(string.format("  timeout: PC=$%08X, expected $%08X SR=$%04X",
                pc, stop_pc, rget("SR")))
            emu.pause()
            test_i = test_i + 1
            phase  = "SETUP_NEXT"
        end

    elseif phase == "DONE" then
        if out_file then out_file:close() end
        print(string.format("Wrote %d tests to %s", n_written, FPU_OUT_PATH))
        phase = "EXITED"
        manager.machine:exit()

    elseif phase == "ABORT" then
        if out_file then out_file:close() end
        manager.machine:exit()
    end
end

emu.register_frame_done(tick, "fpu_capture")
print("mame_fpu_capture.lua loaded — waiting for RAM, will run "
      .. #tests .. " tests then exit.")
