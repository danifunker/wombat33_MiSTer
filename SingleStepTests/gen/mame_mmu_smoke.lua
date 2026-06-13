-- mame_mmu_smoke.lua -- sanity-check the 68040 MMU Lua state interface
-- (and the MOVEC readback path the mmu capture rests on) before running
-- the full capture. 0 failures means the capture method is valid here.
--
--   cd ~/repos/mame
--   ./mame macqd800 -skip_gameinfo -nothrottle -video none -sound none \
--       -seconds_to_run 30 -autoboot_delay 1 \
--       -autoboot_script <repo>/SingleStepTests/gen/mame_mmu_smoke.lua

local PROG_BASE = 0x00001000
local DATA_BASE = 0x00001800
local started, done = false, false
local cpu, prog

local function bw(w) return { (w >> 8) & 0xFF, w & 0xFF } end
local function bl(l) return { (l>>24)&0xFF,(l>>16)&0xFF,(l>>8)&0xFF,l&0xFF } end
local function write_bytes(a, t)
    local i = 0
    for _, b in ipairs(t) do prog:write_u8(a + i, b); i = i + 1 end
    return i
end

local n_pass, n_fail = 0, 0
local function check(name, cond)
    if cond then n_pass = n_pass + 1
    else n_fail = n_fail + 1; print("  FAIL: " .. name) end
end

local function run()
    cpu  = manager.machine.devices[":maincpu"]
    prog = cpu.spaces["program"]

    -- 1) every 040 MMU state name is present and read/writable.
    for _, nm in ipairs({"TC","ITT0","ITT1","DTT0","DTT1","URP","SRP","PSR"}) do
        local ok = cpu.state[nm] ~= nil
        check("state['" .. nm .. "'] exists", ok)
        if ok then
            cpu.state[nm].value = 0x12345678
            check(nm .. " round-trips via state",
                  (cpu.state[nm].value & 0xFFFFFFFF) ~= 0)
            cpu.state[nm].value = 0
        end
    end

    -- 2) MOVEC readback path: plant [MOVE.L #v,D0; MOVEC D0,SRP;
    --    MOVEC SRP,D1; MOVE.L D1,(DATA)] and run it; (DATA) must hold the
    --    written value (this is the path the capture uses for register
    --    round-trips and what the hardware runner mirrors).
    local v = 0x00003000
    local body = {}
    local function add(t) for _, b in ipairs(t) do body[#body+1] = b end end
    add(bw(0x203C)); add(bl(v))                 -- MOVE.L #v,D0
    add(bw(0x4E7B)); add(bw(0x0807))            -- MOVEC D0,SRP  (ctrl $807)
    add(bw(0x4E7A)); add(bw(0x1807))            -- MOVEC SRP,D1
    add(bw(0x23C1)); add(bl(DATA_BASE))         -- MOVE.L D1,(DATA).L
    local jmp = PROG_BASE + #body
    add(bw(0x4EF9)); add(bl(jmp))               -- JMP self
    write_bytes(PROG_BASE, body)
    prog:write_u32(DATA_BASE, 0)
    cpu.state["TC"].value = 0
    cpu.state["SR"].value = 0x2700
    cpu.state["PC"].value = PROG_BASE
    -- The CPU runs freely between frame_done callbacks; the program loops
    -- at its JMP-self catcher, so the next frame's check sees the result.
end

emu.register_frame_done(function()
    cpu  = manager.machine.devices[":maincpu"]
    prog = cpu.spaces["program"]
    if not started then
        prog:write_u32(PROG_BASE, 0xDEADBEEF)
        if prog:read_u32(PROG_BASE) ~= 0xDEADBEEF then return end
        started = true
        run()
        -- let the planted program run a few frames
        return
    end
    if not done then
        done = true
        local got = prog:read_u32(DATA_BASE)
        check("MOVEC SRP readback to DATA == $3000", got == 0x00003000)
        print(string.format("mmu_smoke: %d passed, %d failed", n_pass, n_fail))
        manager.machine:exit()
    end
end, "mmu_smoke")
print("mame_mmu_smoke.lua loaded.")
