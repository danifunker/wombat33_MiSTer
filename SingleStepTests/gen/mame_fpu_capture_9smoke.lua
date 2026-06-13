-- One-shot variant of mame_fpu_capture.lua that runs ONLY the 9
-- hand-coded smoke tests that fpu_test_macii.c uses. Output goes to
-- /tmp/fpu_smoke9.json — diff against the hardware results to confirm
-- the new MAME build still matches real 68881 on those tests.

local FPU_OUT_PATH = "/tmp/fpu_smoke9.json"
local PROG_BASE   = 0x00001000
local INIT_DUMP   = 0x00002000
local FINAL_DUMP  = 0x00002200
local VEC_BASE    = 0x00000000
local VEC_COUNT   = 256

-- The 9 tests from SingleStepTests/gen/fpu_test_macii.c verbatim.
local tests = {
    { name = "DBG: MOVEQ #5,D0 (no FPU)",
      preload = {}, test = { 0x70, 0x05 } },
    { name = "FMOVE.L #1,FP0",
      preload = {},
      test    = { 0x70, 0x01, 0xF2, 0x00, 0x40, 0x00 } },
    { name = "FADD.X FP0,FP0 (1+1=2)",
      preload = { 0x70, 0x01, 0xF2, 0x00, 0x40, 0x00 },
      test    = { 0xF2, 0x00, 0x00, 0x22 } },
    { name = "FMUL.X FP0,FP0 (2*2=4)",
      preload = { 0x70, 0x02, 0xF2, 0x00, 0x40, 0x00 },
      test    = { 0xF2, 0x00, 0x00, 0x23 } },
    { name = "FSQRT.X FP0,FP0 (sqrt(4)=2)",
      preload = { 0x70, 0x04, 0xF2, 0x00, 0x40, 0x00 },
      test    = { 0xF2, 0x00, 0x00, 0x04 } },
    { name = "FNEG.X FP0,FP0 (1 -> -1)",
      preload = { 0x70, 0x01, 0xF2, 0x00, 0x40, 0x00 },
      test    = { 0xF2, 0x00, 0x00, 0x1A } },
    { name = "FABS.X FP0,FP0 (-1 -> 1)",
      preload = { 0x70, 0xFF, 0xF2, 0x00, 0x40, 0x00 },
      test    = { 0xF2, 0x00, 0x00, 0x18 } },
    { name = "FTST.X FP0",
      preload = { 0x70, 0x00, 0xF2, 0x00, 0x40, 0x00 },
      test    = { 0xF2, 0x00, 0x00, 0x3A } },
    { name = "FMOVE.X FP0,FP1",
      preload = { 0x70, 0x05, 0xF2, 0x00, 0x40, 0x00 },
      test    = { 0xF2, 0x00, 0x00, 0x80 } },
}

-- The rest mirrors mame_fpu_capture.lua exactly --------------------

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
    for i = 1, #bytes do out[i] = string.format("%02x", bytes[i]) end
    return table.concat(out)
end

local function emit_fmove_x_to_an_postinc(fpn, an)
    return { (0xF218 | (an & 7)) >> 8 & 0xFF, (0xF218 | (an & 7)) & 0xFF,
             (0x6800 | (fpn << 7)) >> 8 & 0xFF, (0x6800 | (fpn << 7)) & 0xFF }
end
local function emit_movea_l_imm_to_an(an, imm)
    local op = 0x207C | ((an & 7) << 9)
    return { (op >> 8) & 0xFF, op & 0xFF,
             (imm >> 24) & 0xFF, (imm >> 16) & 0xFF,
             (imm >>  8) & 0xFF,  imm        & 0xFF }
end
local function emit_move_l_dn_to_abs(dn, addr)
    local op = 0x23C0 | (dn & 7)
    return { (op >> 8) & 0xFF, op & 0xFF,
             (addr >> 24) & 0xFF, (addr >> 16) & 0xFF,
             (addr >>  8) & 0xFF,  addr        & 0xFF }
end
local function emit_move_l_an_to_abs(an, addr)
    local op = 0x23C8 | (an & 7)
    return { (op >> 8) & 0xFF, op & 0xFF,
             (addr >> 24) & 0xFF, (addr >> 16) & 0xFF,
             (addr >>  8) & 0xFF,  addr        & 0xFF }
end
local function emit_fmove_l_fpcr_to_abs(mask, addr)
    return { 0xF2, 0x39, (0xA000 | mask) >> 8 & 0xFF, (0xA000 | mask) & 0xFF,
             (addr >> 24) & 0xFF, (addr >> 16) & 0xFF,
             (addr >>  8) & 0xFF,  addr        & 0xFF }
end
local function emit_state_dump(base)
    local out = {}
    local function append(t) for _, b in ipairs(t) do out[#out + 1] = b end end
    for an = 0, 7 do append(emit_move_l_an_to_abs(an, base + 0x80 + an * 4)) end
    append(emit_movea_l_imm_to_an(0, base))
    for fpn = 0, 7 do append(emit_fmove_x_to_an_postinc(fpn, 0)) end
    for dn = 0, 7 do append(emit_move_l_dn_to_abs(dn, base + 0x60 + dn * 4)) end
    append(emit_fmove_l_fpcr_to_abs(0x1000, base + 0xA0))
    append(emit_fmove_l_fpcr_to_abs(0x0800, base + 0xA4))
    append(emit_fmove_l_fpcr_to_abs(0x0400, base + 0xA8))
    return out
end
local function read_snap(base)
    local snap = { fp = {}, d = {}, a = {} }
    for fpn = 0, 7 do snap.fp[fpn] = hexstr(read_bytes(base + fpn * 12, 12)) end
    for dn = 0, 7 do
        local b = read_bytes(base + 0x60 + dn * 4, 4)
        snap.d[dn] = (b[1] << 24) | (b[2] << 16) | (b[3] << 8) | b[4]
    end
    for an = 0, 7 do
        local b = read_bytes(base + 0x80 + an * 4, 4)
        snap.a[an] = (b[1] << 24) | (b[2] << 16) | (b[3] << 8) | b[4]
    end
    local function rd32(off)
        local b = read_bytes(base + off, 4)
        return (b[1] << 24) | (b[2] << 16) | (b[3] << 8) | b[4]
    end
    snap.fpcr  = rd32(0xA0); snap.fpsr = rd32(0xA4); snap.fpiar = rd32(0xA8)
    return snap
end

local function snap_to_string(s)
    local buf = { "{\"d\":[" }
    for i = 0, 7 do buf[#buf + 1] = (i == 0 and "" or ",") .. tostring(s.d[i]) end
    buf[#buf + 1] = "],\"a\":["
    for i = 0, 7 do buf[#buf + 1] = (i == 0 and "" or ",") .. tostring(s.a[i]) end
    buf[#buf + 1] = "],\"fp\":["
    for i = 0, 7 do buf[#buf + 1] = (i == 0 and "" or ",") .. '"' .. s.fp[i] .. '"' end
    buf[#buf + 1] = string.format(
        "],\"fpcr\":%d,\"fpsr\":%d,\"fpiar\":%d}",
        s.fpcr, s.fpsr, s.fpiar)
    return table.concat(buf)
end

local phase, frames, test_i, stop_pc = "WAIT_RAM", 0, 1, 0
local out_file, n_written = nil, 0

local function start_test(t)
    for i = 0, 0xAB do
        prog:write_u8(INIT_DUMP  + i, 0xCD)
        prog:write_u8(FINAL_DUMP + i, 0xCD)
    end
    local out = {}
    local function append(bs) for _, b in ipairs(bs) do out[#out + 1] = b end end
    append(t.preload)
    append(emit_state_dump(INIT_DUMP))
    local final_off = #out
    append(t.test)
    final_off = #out
    append(emit_state_dump(FINAL_DUMP))
    local jmp_pc = PROG_BASE + #out
    append({ 0x4E, 0xF9,
             (jmp_pc >> 24) & 0xFF, (jmp_pc >> 16) & 0xFF,
             (jmp_pc >>  8) & 0xFF,  jmp_pc        & 0xFF })
    stop_pc = jmp_pc
    write_bytes(PROG_BASE, out)
    local final_dump_pc = PROG_BASE + final_off
    for v = 0, VEC_COUNT - 1 do prog:write_u32(VEC_BASE + v * 4, final_dump_pc) end
    for r = 0, 7 do rset("D" .. r, 0); rset("A" .. r, 0) end
    rset("SR", 0x2700); rset("A7", 0x00200000); rset("PC", PROG_BASE)
    rset("VBR", VEC_BASE)
    if cpu.state["SFC"]  then rset("SFC", 0)  end
    if cpu.state["DFC"]  then rset("DFC", 0)  end
    if cpu.state["CACR"] then rset("CACR", 0) end
    frames = 0
end

local function tick()
    init_handles()
    if phase == "WAIT_RAM" then
        prog:write_u32(PROG_BASE, 0xDEADBEEF)
        frames = frames + 1
        if prog:read_u32(PROG_BASE) == 0xDEADBEEF then
            out_file = io.open(FPU_OUT_PATH, "w")
            phase, frames = "SETUP_NEXT", 0
        elseif frames >= 1800 then phase = "ABORT" end
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
            out_file:write(string.format("{\"name\":%q,\"initial\":%s,\"final\":%s}\n",
                t.name, snap_to_string(read_snap(INIT_DUMP)),
                        snap_to_string(read_snap(FINAL_DUMP))))
            out_file:flush()
            n_written = n_written + 1
            test_i = test_i + 1
            phase  = "SETUP_NEXT"
        elseif frames >= 120 then
            print(string.format("  timeout: PC=$%08X", pc))
            emu.pause(); test_i = test_i + 1; phase = "SETUP_NEXT"
        end
    elseif phase == "DONE" then
        if out_file then out_file:close() end
        print(string.format("Wrote %d tests to %s", n_written, FPU_OUT_PATH))
        manager.machine:exit()
    elseif phase == "ABORT" then
        if out_file then out_file:close() end
        manager.machine:exit()
    end
end

emu.register_frame_done(tick, "fpu_smoke9")
print("9-test smoke variant loaded.")
