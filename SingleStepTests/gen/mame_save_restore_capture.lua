-- MAME Lua script: capture FSAVE / FRESTORE (cpSAVE / cpRESTORE) goldens
-- from maciihmu, used as the oracle for the CIR save/restore test corpus.
--
-- WHY THIS EXISTS
-- ---------------
-- The integration corpus (SingleStepTests/cpu_fpu/fpu_corpus_baseline.json)
-- and the F-line trap regression set exercise only cpGEN math and the
-- F-line-trap fall-through. Neither touches the FSAVE/FRESTORE state-frame
-- protocol (the CIR SAVE_FORMAT/SAVE_FRAME/RESTORE_FORMAT/RESTORE_FRAME
-- dialog). These vectors fill that gap.
--
-- MAME's maciihmu implements the MC68881 state frames correctly, so it is
-- the golden reference. This script runs each test program on maciihmu,
-- reads back the result D-register (the corpus "expected" value, captured
-- never invented) and, for frame-shape tests, the raw bytes FSAVE wrote to
-- memory (FORMAT word + frame body).
--
-- OUTPUTS
--   /tmp/save_restore_corpus.jsonl  one JSON object per round-trip test,
--                                   integration-corpus shape:
--                                   {name, op_a, program[], result_reg, expected}
--   /tmp/save_restore_frames.txt    human-readable FSAVE frame dumps
--
-- USAGE (mirrors mame_fpu_capture.lua)
--   cd ~/repos/mame
--   SDL_VIDEODRIVER=offscreen ./mame maciihmu -skip_gameinfo -ramsize 8M \
--     -nothrottle -seconds_to_run 60 -window \
--     -autoboot_delay 1 \
--     -autoboot_script <repo>/SingleStepTests/gen/mame_save_restore_capture.lua
--
-- MAME exits automatically once the corpus is written.

local CORPUS_PATH = "/tmp/save_restore_corpus.jsonl"
local FRAMES_PATH = "/tmp/save_restore_frames.txt"

local PROG_BASE  = 0x00001000   -- planted program
-- FSAVE (A0) target. Deliberately high (512 KB) so the same programs are
-- safe on real hardware too: on a booted Mac II, low memory (<0x1000
-- vectors, 0x100..0xBFF system globals) must not be clobbered, but
-- 0x80000 is free RAM in both the Verilator sim and the supervisor bench.
local FRAME_BUF  = 0x00080000
local TRAP_PC    = 0x00000800   -- any exception lands here (JMP-self)
local STACK_TOP  = 0x00200000   -- A7 for -(A7) FSAVE round-trips
local VEC_BASE   = 0x00000000
local VEC_COUNT  = 256

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
    for i, b in ipairs(bytes) do prog:write_u8(addr + i - 1, b) end
end
local function read_bytes(addr, n)
    local out = {}
    for i = 0, n - 1 do out[#out + 1] = prog:read_u8(addr + i) end
    return out
end
local function hexstr(bytes)
    local out = {}
    for i = 1, #bytes do out[i] = string.format("%02X", bytes[i]) end
    return table.concat(out, " ")
end

-- ----------------------------------------------------------------------
-- Instruction byte fragments (verified against fpu_corpus_baseline.json:
-- FMOVE.L D0,FP6 = F2 00 43 00 fixes the ext-word dst field at bits 9-7).
-- ----------------------------------------------------------------------
local STOP_2700 = {0x4E, 0x72, 0x27, 0x00}   -- (corpus terminator)

local function MOVEQ(n, dn)            -- MOVEQ #n,Dn
    local op = 0x7000 | ((dn & 7) << 9) | (n & 0xFF)
    return { (op >> 8) & 0xFF, op & 0xFF }
end
local function FMOVE_L_D0_to_FP(fpn)   -- FMOVE.L D0,FPn   F2 00 / ext
    local ext = 0x4000 | ((fpn & 7) << 7)            -- to-FP, size L, dst fpn
    return { 0xF2, 0x00, (ext >> 8) & 0xFF, ext & 0xFF }
end
local function FMOVE_L_FP_to_D1(fpn)   -- FMOVE.L FPn,D1   F2 01 / ext
    local ext = 0x6000 | ((fpn & 7) << 7)            -- FP-to-EA, size L, src fpn
    return { 0xF2, 0x01, (ext >> 8) & 0xFF, ext & 0xFF }
end
local function MOVEA_L_imm_A0(imm)     -- MOVEA.L #imm,A0
    return { 0x20, 0x7C, (imm >> 24) & 0xFF, (imm >> 16) & 0xFF,
                         (imm >>  8) & 0xFF,  imm        & 0xFF }
end
local FSAVE_PREDEC  = { 0xF3, 0x27 }   -- FSAVE   -(A7)
local FRESTORE_POST = { 0xF3, 0x5F }   -- FRESTORE (A7)+
local FSAVE_A0      = { 0xF3, 0x10 }   -- FSAVE   (A0)
local FRESTORE_A0   = { 0xF3, 0x50 }   -- FRESTORE (A0)
local CLR_L_A0      = { 0x42, 0x90 }   -- CLR.L   (A0)  -> 0x00000000 NULL frame

local function cat(...)
    local out = {}
    for _, frag in ipairs({...}) do
        for _, b in ipairs(frag) do out[#out + 1] = b end
    end
    return out
end

-- ======================================================================
-- TEST DEFINITIONS
--
-- body         : program bytes through the result FMOVE.L FPn,D1 (no
--                terminator). The corpus stores body .. STOP; the runner
--                here appends a JMP-self so PC settles at a known address.
-- result_reg   : D-register read after the program (the "expected" golden).
-- op_a         : the integer fed in (metadata; supervisor bench loads it).
-- frame_addr   : if set, this is a frame-shape probe (FSAVE to FRAME_BUF);
--                read N bytes back instead of producing a corpus row.
-- ======================================================================
-- NOTE ON 68881 SEMANTICS: FSAVE/FRESTORE move the coprocessor's INTERNAL
-- (microcode) state via the IDLE/BUSY/NULL frame — NOT the programmer-
-- visible FP data registers FP0..FP7 / FPCR / FPSR (those move with
-- FMOVEM). So a save/clobber/restore does NOT bring a clobbered FP data
-- register back; the right assertion is "the dialog completed and the FPU
-- is still usable afterward." The CIR SAVE_FRAME wedge breaks exactly
-- that: a buggy core never finishes the FSAVE, so the program never
-- reaches its result move and these vectors fail (timeout / stale D-reg).
local FRAME_BUF2 = 0x00080100

local tests = {
    -- Survival: the FPU still answers an FP move after a full FSAVE/FRESTORE
    -- cycle. On a core that wedges in SAVE_FRAME the FSAVE never retires,
    -- so D1 never gets 5. (-(A7) form.)
    { name = "FSAVE -(A7); FRESTORE (A7)+; FPU still usable, FP3=5 -> D1",
      op_a = 5, result_reg = 1,
      body = cat(MOVEQ(5,0), FMOVE_L_D0_to_FP(3), FSAVE_PREDEC,
                 FRESTORE_POST, FMOVE_L_FP_to_D1(3)) },

    -- Survival, different register/value.
    { name = "FSAVE/FRESTORE -(A7); FPU still usable, FP0=42 -> D1",
      op_a = 42, result_reg = 1,
      body = cat(MOVEQ(42,0), FMOVE_L_D0_to_FP(0), FSAVE_PREDEC,
                 FRESTORE_POST, FMOVE_L_FP_to_D1(0)) },

    -- Survival, negative value / top register (sign-extend path).
    { name = "FSAVE/FRESTORE -(A7); FPU still usable, FP7=-1 -> D1",
      op_a = -1, result_reg = 1,
      body = cat(MOVEQ(-1,0), FMOVE_L_D0_to_FP(7), FSAVE_PREDEC,
                 FRESTORE_POST, FMOVE_L_FP_to_D1(7)) },

    -- Survival, mid-range value.
    { name = "FSAVE/FRESTORE -(A7); FPU still usable, FP3=63 -> D1",
      op_a = 63, result_reg = 1,
      body = cat(MOVEQ(63,0), FMOVE_L_D0_to_FP(3), FSAVE_PREDEC,
                 FRESTORE_POST, FMOVE_L_FP_to_D1(3)) },

    -- Re-enter the SAVE dialog twice in one program (stresses return to
    -- IDLE and a second SAVE_FORMAT/SAVE_FRAME pass).
    { name = "FSAVE;FRESTORE;FSAVE;FRESTORE -(A7) twice; FP3=11 -> D1",
      op_a = 11, result_reg = 1,
      body = cat(MOVEQ(11,0), FMOVE_L_D0_to_FP(3), FSAVE_PREDEC,
                 FRESTORE_POST, FSAVE_PREDEC, FRESTORE_POST,
                 FMOVE_L_FP_to_D1(3)) },

    -- Semantics: an IDLE-frame FRESTORE must NOT reload FP data registers.
    -- FP3 is set to 5, saved, clobbered to 99, then FRESTORE'd — correct
    -- 68881 behavior leaves FP3 = 99 (the clobber survives). Catches an
    -- implementation that wrongly stuffs FP data into the IDLE frame.
    { name = "IDLE FRESTORE does NOT reload FP data: clobber FP3 5->99 -> D1=99",
      op_a = 5, result_reg = 1,
      body = cat(MOVEQ(5,0), FMOVE_L_D0_to_FP(3), FSAVE_PREDEC,
                 MOVEQ(99,0), FMOVE_L_D0_to_FP(3), FRESTORE_POST,
                 FMOVE_L_FP_to_D1(3)) },

    -- Same semantics via a memory buffer (FSAVE (A0) / FRESTORE (A0)).
    { name = "FSAVE/FRESTORE (A0) does NOT reload FP data: clobber FP3 7->99 -> D1=99",
      op_a = 7, result_reg = 1,
      body = cat(MOVEQ(7,0), FMOVE_L_D0_to_FP(3), MOVEA_L_imm_A0(FRAME_BUF),
                 FSAVE_A0, MOVEQ(99,0), FMOVE_L_D0_to_FP(3),
                 MOVEA_L_imm_A0(FRAME_BUF), FRESTORE_A0,
                 FMOVE_L_FP_to_D1(3)) },

    -- NULL-frame FRESTORE (format word 0x0000) resets the FPU; it must
    -- still execute FP instructions afterward. Exercises RESTORE_FORMAT's
    -- NULL path (no RESTORE_FRAME data words).
    { name = "FRESTORE NULL frame (A0); FPU re-init, FMOVE.L #5,FP3 -> D1=5",
      op_a = 5, result_reg = 1,
      body = cat(MOVEA_L_imm_A0(FRAME_BUF), CLR_L_A0, FRESTORE_A0,
                 MOVEQ(5,0), FMOVE_L_D0_to_FP(3), FMOVE_L_FP_to_D1(3)) },

    -- ---- frame-shape probes (dump bytes to memory, not corpus rows) ----
    -- IDLE frame after an FP op: format word should be 0x1F18 (ver 0x1F,
    -- 24 data bytes).
    { name = "FRAME: FSAVE (A0) after FMOVE.L #5,FP3 (expect IDLE 0x1F18)",
      frame_addr = FRAME_BUF, frame_len = 32,
      body = cat(MOVEQ(5,0), FMOVE_L_D0_to_FP(3), MOVEA_L_imm_A0(FRAME_BUF),
                 FSAVE_A0) },

    -- NULL frame: restore a NULL frame, then save — format word 0x0000.
    { name = "FRAME: FRESTORE NULL then FSAVE (A0) (expect NULL 0x0000)",
      frame_addr = FRAME_BUF2, frame_len = 16,
      body = cat(MOVEA_L_imm_A0(FRAME_BUF), CLR_L_A0, FRESTORE_A0,
                 MOVEA_L_imm_A0(FRAME_BUF2), FSAVE_A0) },
}

-- ----------------------------------------------------------------------
-- Runner: frame-driven state machine (same shape as mame_fpu_capture.lua).
-- ----------------------------------------------------------------------
local RAM_PROBE_VALUE = 0xDEADBEEF
local MAX_WAIT_FRAMES = 1800
local MAX_RUN_FRAMES  = 120

local phase     = "WAIT_RAM"
local frames    = 0
local test_i    = 1
local stop_pc   = 0
local corpus_f  = nil
local frames_f  = nil
local n_corpus  = 0

local JMP = function(addr)
    return { 0x4E, 0xF9, (addr >> 24) & 0xFF, (addr >> 16) & 0xFF,
                         (addr >>  8) & 0xFF,  addr        & 0xFF }
end

local function start_test(t)
    -- Clear the working buffer so a stale frame can't masquerade as fresh.
    for i = 0, 255 do prog:write_u8(FRAME_BUF + i, 0) end

    local body_len = #t.body
    stop_pc = PROG_BASE + body_len
    local out = {}
    for _, b in ipairs(t.body)        do out[#out + 1] = b end
    for _, b in ipairs(JMP(stop_pc))  do out[#out + 1] = b end
    write_bytes(PROG_BASE, out)

    -- A JMP-self sentinel at TRAP_PC so any exception parks at a known PC.
    write_bytes(TRAP_PC, JMP(TRAP_PC))
    for v = 0, VEC_COUNT - 1 do prog:write_u32(VEC_BASE + v * 4, TRAP_PC) end

    for r = 0, 7 do rset("D" .. r, 0); rset("A" .. r, 0) end
    rset("SR", 0x2700)          -- supervisor, IRQs masked (ROM keeps firing VBL)
    rset("A7", STACK_TOP)
    rset("PC", PROG_BASE)
    rset("VBR", VEC_BASE)
    if cpu.state["SFC"]  then rset("SFC", 0) end
    if cpu.state["DFC"]  then rset("DFC", 0) end
    if cpu.state["CACR"] then rset("CACR", 0) end
    frames = 0
end

local function emit_corpus(t, expected)
    -- Corpus row: program = body .. STOP (the form sim_main.cpp / the
    -- supervisor bench consume).
    local prog_bytes = {}
    for _, b in ipairs(t.body)    do prog_bytes[#prog_bytes + 1] = b end
    for _, b in ipairs(STOP_2700) do prog_bytes[#prog_bytes + 1] = b end
    local parts = {}
    for i = 1, #prog_bytes do parts[i] = tostring(prog_bytes[i]) end
    corpus_f:write(string.format(
        "{\"name\":%q,\"op_a\":%d,\"program\":[%s],\"result_reg\":%d,\"expected\":%d}\n",
        t.name, t.op_a, table.concat(parts, ","), t.result_reg, expected))
    corpus_f:flush()
    n_corpus = n_corpus + 1
end

local function tick()
    init_handles()

    if phase == "WAIT_RAM" then
        prog:write_u32(PROG_BASE, RAM_PROBE_VALUE)
        frames = frames + 1
        if prog:read_u32(PROG_BASE) == RAM_PROBE_VALUE then
            print(string.format("RAM mapped at $%08X after %d frames.", PROG_BASE, frames))
            corpus_f = io.open(CORPUS_PATH, "w")
            frames_f = io.open(FRAMES_PATH, "w")
            if not corpus_f or not frames_f then
                print("ERROR: cannot open output files"); phase = "ABORT"; return
            end
            phase = "SETUP_NEXT"; frames = 0
        elseif frames >= MAX_WAIT_FRAMES then
            print("ERROR: RAM never mapped low."); phase = "ABORT"
        end

    elseif phase == "SETUP_NEXT" then
        if test_i > #tests then phase = "DONE"; return end
        local t = tests[test_i]
        print(string.format("[%d/%d] %s", test_i, #tests, t.name))
        emu.pause(); start_test(t); emu.unpause()
        phase = "RUN"

    elseif phase == "RUN" then
        frames = frames + 1
        local pc = rget("PC")
        if pc == stop_pc then
            emu.pause()
            local t = tests[test_i]
            if t.frame_addr then
                local b = read_bytes(t.frame_addr, t.frame_len or 32)
                local fmt = (b[1] << 8) | b[2]
                frames_f:write(string.format("%s\n  @0x%08X format=0x%04X bytes: %s\n\n",
                    t.name, t.frame_addr, fmt, hexstr(b)))
                frames_f:flush()
                print(string.format("  frame format word = 0x%04X", fmt))
            else
                local got = rget("D" .. t.result_reg) & 0xFFFFFFFF
                local s = got
                if s >= 0x80000000 then s = s - 0x100000000 end
                emit_corpus(t, s)
                print(string.format("  D%d = %d (0x%08X)", t.result_reg, s, got))
            end
            test_i = test_i + 1; phase = "SETUP_NEXT"
        elseif pc == TRAP_PC then
            print(string.format("  *** TRAP: program faulted (SR=0x%04X) — skipped",
                rget("SR")))
            emu.pause(); test_i = test_i + 1; phase = "SETUP_NEXT"
        elseif frames >= MAX_RUN_FRAMES then
            print(string.format("  timeout: PC=0x%08X expected 0x%08X SR=0x%04X",
                pc, stop_pc, rget("SR")))
            emu.pause(); test_i = test_i + 1; phase = "SETUP_NEXT"
        end

    elseif phase == "DONE" then
        if corpus_f then corpus_f:close() end
        if frames_f then frames_f:close() end
        print(string.format("Wrote %d corpus rows to %s", n_corpus, CORPUS_PATH))
        print("Frame dumps in " .. FRAMES_PATH)
        phase = "EXITED"; manager.machine:exit()

    elseif phase == "ABORT" then
        if corpus_f then corpus_f:close() end
        if frames_f then frames_f:close() end
        manager.machine:exit()
    end
end

emu.register_frame_done(tick, "save_restore_capture")
