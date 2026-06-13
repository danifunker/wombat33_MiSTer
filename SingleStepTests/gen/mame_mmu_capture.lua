-- MAME Lua script: capture 68040 MMU instruction state for the
-- Macintosh Quadra 800 (Wombat) core testbench.
--
-- Sibling of mame_cpu_capture.lua, specialized for the 68040's on-chip
-- MMU. The 68040 MMU is NOT the 68030 PMMU: registers move via MOVEC
-- (not PMOVE), the table walk is a FIXED 3-level tree (root/pointer/page,
-- no early termination and no programmable geometry), the page size is
-- 4K or 8K (TC.P), transparent translation is split into instruction
-- (ITT0/ITT1) and data (DTT0/DTT1) pairs, faults push a format-$7
-- access-error frame, and PTEST/PFLUSH have single-word encodings.
--
-- Run it against the Quadra 800 MAME driver (MC68040 @ 33 MHz):
--   cd ~/repos/mame
--   ./mame macqd800 -skip_gameinfo -nothrottle -video none -sound none \
--       -seconds_to_run 120 -autoboot_delay 1 \
--       -autoboot_script <repo>/SingleStepTests/gen/mame_mmu_capture.lua
--
-- WHAT MAME's 68040 MMU FAITHFULLY MODELS (these rows are authoritative):
--   * Live page-table translation: identity + remap stores/loads, U-bit
--     and M-bit descriptor writeback down the walk (visible in the table
--     RAM windows), ATC staleness vs PFLUSH.
--   * Faults: write-protected page, invalid page, supervisor-only page ->
--     bus error (vector 2), format-$7 frame on the supervisor stack.
--   * Transparent translation (ITT/DTT) match + write-protect.
--   * PFLUSH family (MAME collapses every variant to "flush whole ATC").
--   * MOVEC round-trips of TC / ITT0 / ITT1 / DTT0 / DTT1 / URP / SRP /
--     MMUSR -- characterizes each register's writable-bit mask.
--
-- WHAT MAME does NOT model faithfully (rows flagged hw_unsafe / note):
--   * The single-word 68040 PTEST ($F548/$F568) is not decoded by MAME's
--     m68kmmu.h (it hits the "unknown PMMU instruction group" default).
--   * Even via the 030-style two-word PTEST path, MAME's 040 MMUSR
--     composition is impoverished (m68kmmu.h ~line 858 uses a logical-OR,
--     so only the R/W bits are meaningful -- no physical address, no
--     M/S/G/U fields). PTEST-result goldens must come from real Quadra
--     800 silicon; PTEST rows here are placeholders carrying the test
--     bytes + a best-effort MAME capture, marked hw_unsafe=0 so the
--     hardware runner adjudicates them.
--
-- EXECUTION MODEL (same bubble as the CPU/PMMU captures):
--   Instruction fetches are made transparent via ITT0 (so the planted
--   program and the catcher always fetch regardless of page-table state),
--   while DATA accesses go through the page tables -- those are the
--   translations under test. The low region 0..$3FFFF is identity-mapped
--   by a single page table so the supervisor stack (fault frames) and the
--   scratch/operand windows resolve without double-faulting. Per-test
--   page overrides install remaps / write-protect / invalid entries.
--
-- Every test program is:   [test bytes][JMP self catcher]
-- All 256 vectors point at the catcher, so faulting tests converge there.
-- After the program reaches the catcher (or times out) the tick loop
-- snapshots state and forces TC=0 (translation off) before the next test.
--
-- Outputs:
--   /tmp/mmu_corpus.json  -- JSON Lines, one test per line (SCHEMA.md)
--   /tmp/mmu_tests.h      -- C header for the preboot supervisor bench

local OUT_JSON  = "/tmp/mmu_corpus.json"
local OUT_H     = "/tmp/mmu_tests.h"

local PROG_BASE = 0x00001000
local DATA_BASE = 0x00001800   -- scratch: operands + MOVEC readback results
local ROOT_TBL  = 0x00003000   -- root (level A) table, 512B aligned; entry 0 used
local PTR_TBL   = 0x00003200   -- pointer (level B) table, 512B aligned
local PAGE_TBL  = 0x00003400   -- page (level C) table, 256B aligned, 64 entries
                               -- identity-maps va $00000..$3FFFF (4K pages)
local REMAP_PA  = 0x0001F000   -- physical page a remapped va points at
local REMAP2_PA = 0x0001E000   -- second remap target (ATC staleness tests)
local STACK_TOP = 0x00040000   -- top of the identity region; frames push below
local VEC_BASE  = 0x00000000

-- Memory windows snapshotted (zeroed, planted, diffed) every test.
local WINDOWS = {
    { DATA_BASE,        0x40 },
    { ROOT_TBL,         0x20 },
    { PTR_TBL,          0x20 },
    { PAGE_TBL,         0x100 },   -- 64 page entries; U/M writeback shows here
    { REMAP_PA,         0x40 },
    { REMAP2_PA,        0x40 },
    { STACK_TOP - 0x60, 0x60 },    -- format-$7 fault frame lands here
}

-- TC: bit15=E (enable), bit14=P (page size: 0=4K, 1=8K). Nothing else.
local TC_4K_ON  = 0x00008000   -- enable, 4K pages
local TC_OFF    = 0x00000000

-- ITT0 transparent-map for ALL instruction fetches:
--   E=1 ($8000), S-field=2 (bits14-13 -> matches both user+supervisor),
--   logical-mask=$FF (bits23-16 -> effective mask 0 -> matches every addr).
local ITT_ALL   = 0x00FFC000

-- ---------------------------------------------------------------------
-- Handles + helpers
-- ---------------------------------------------------------------------
local cpu, prog
local function init_handles()
    cpu  = manager.machine.devices[":maincpu"]
    prog = cpu.spaces["program"]
end
local function rget(name) return cpu.state[name].value end
local function rset(name, v) cpu.state[name].value = v end

local function bw(w) return { (w >> 8) & 0xFF, w & 0xFF } end
local function bl(l)
    return { (l >> 24) & 0xFF, (l >> 16) & 0xFF,
             (l >>  8) & 0xFF,  l        & 0xFF }
end
local function concat(...)
    local out = {}
    for _, t in ipairs({...}) do
        for _, b in ipairs(t) do out[#out + 1] = b end
    end
    return out
end
local function write_bytes(addr, bytes)
    for i, b in ipairs(bytes) do prog:write_u8(addr + i - 1, b) end
end

-- Instruction emitters ------------------------------------------------
-- MOVEC ext word: A/D<<15 | reg<<12 | ctrl_num.
-- Control numbers (68040): TC=$003 ITT0=$004 ITT1=$005 DTT0=$006
--   DTT1=$007 MMUSR=$805 URP=$806 SRP=$807 CACR=$002.
local CTRL = { TC=0x003, ITT0=0x004, ITT1=0x005, DTT0=0x006, DTT1=0x007,
               MMUSR=0x805, URP=0x806, SRP=0x807 }
local function movec_to(ctrl, dn)    -- MOVEC Dn,ctrl  ($4E7B)
    return concat(bw(0x4E7B), bw((0 << 15) | ((dn & 7) << 12) | ctrl))
end
local function movec_from(ctrl, dn)  -- MOVEC ctrl,Dn  ($4E7A)
    return concat(bw(0x4E7A), bw((0 << 15) | ((dn & 7) << 12) | ctrl))
end
local function move_l_imm_dn(dn, imm) -- MOVE.L #imm,Dn ($203C | dn<<9)
    return concat(bw(0x203C | ((dn & 7) << 9)), bl(imm))
end
local function moveq_dn(dn, imm)      -- MOVEQ #imm,Dn
    return concat(bw(0x7000 | ((dn & 7) << 9) | (imm & 0xFF)))
end
local function move_l_dn_abs(dn, addr) -- MOVE.L Dn,(addr).L
    return concat(bw(0x23C0 | (dn & 7)), bl(addr))
end
local function move_l_abs_dn(addr, dn) -- MOVE.L (addr).L,Dn
    return concat(bw(0x2039 | ((dn & 7) << 9)), bl(addr))
end
local function move_l_imm_abs(imm, addr) -- MOVE.L #imm,(addr).L
    return concat(bw(0x23FC), bl(imm), bl(addr))
end
local function lea_abs_a0(addr)        -- LEA (addr).L,A0
    return concat(bw(0x41F9), bl(addr))
end
-- 68040 PFLUSH/PTEST single-word forms.
local function pflusha()   return bw(0xF518) end           -- PFLUSHA
local function pflushan()  return bw(0xF510) end           -- PFLUSHAN
local function pflush_a0() return bw(0xF508 | 0) end        -- PFLUSH (A0)
local function pflushn_a0()return bw(0xF500 | 0) end        -- PFLUSHN (A0)
local function ptestr_a0() return bw(0xF568 | 0) end        -- PTESTR (A0)
local function ptestw_a0() return bw(0xF548 | 0) end        -- PTESTW (A0)

-- 68040 descriptors --------------------------------------------------
-- Root/pointer (upper) descriptor: addr | W(bit2) | UDT-valid(bit1).
local function table_desc(addr, wp) return (addr & 0xFFFFFE00) | (wp and 0x04 or 0) | 0x02 end
-- Page (leaf) descriptor: pa | S(bit7) | W(bit2) | PDT(=1 resident).
local PG_W = 0x04   -- write protect
local PG_S = 0x80   -- supervisor only
local function page_desc(pa, flags) return (pa & 0xFFFFF000) | (flags or 0) | 0x01 end

-- ---------------------------------------------------------------------
-- Identity page tables (va $00000..$3FFFF, 4K pages), with overrides.
-- root[0] -> PTR_TBL ; ptr[0] -> PAGE_TBL ; page[i] = identity.
-- page_overrides: { [index]=descriptor } replaces a leaf entry.
-- ptr_wp / root_wp: set the W bit on the upper descriptors (tree WP).
-- ---------------------------------------------------------------------
local function id_tables(opts)
    opts = opts or {}
    local p = {
        { ROOT_TBL, table_desc(PTR_TBL,  opts.root_wp) },
        { PTR_TBL,  table_desc(PAGE_TBL, opts.ptr_wp)  },
    }
    for i = 0, 63 do
        local desc = page_desc(i * 0x1000, 0)
        if opts.page and opts.page[i] ~= nil then desc = opts.page[i] end
        p[#p + 1] = { PAGE_TBL + i * 4, desc }
    end
    return p
end

local tests = {}
local function T(t) tests[#tests + 1] = t end

-- ---- MOVEC register round-trips (translation OFF; safe everywhere) ---
-- Program: load #val -> D0, MOVEC D0,reg, MOVEC reg,D1, force TC=0 and
-- clear the reg under test (so ITT/DTT can't write-protect scratch),
-- then store D1 to DATA_BASE. Captures the register's writable-bit mask
-- (final.ram at DATA_BASE = value read back).
local function movec_rt(name, reg, val)
    local ctrl = CTRL[reg]
    local body = concat(
        move_l_imm_dn(0, val),
        movec_to(ctrl, 0),
        movec_from(ctrl, 1),
        moveq_dn(2, 0),
        movec_to(CTRL.TC, 2),      -- translation off -> data identity
        movec_to(ctrl, 2),         -- clear reg under test
        move_l_dn_abs(1, DATA_BASE))
    T{ name = name, test = body, reg_rt = true }
end
movec_rt("MOVEC TC   w/r (#$0000C000)",        "TC",   0x0000C000)
movec_rt("MOVEC TC   w/r (#$FFFFFFFF mask)",   "TC",   0xFFFFFFFF)
movec_rt("MOVEC ITT0 w/r (#$00FFE000 enable)", "ITT0", 0x00FFE000)
movec_rt("MOVEC ITT0 w/r (#$FFFFFFFF mask)",   "ITT0", 0xFFFFFFFF)
movec_rt("MOVEC ITT1 w/r (#$00FFE000 enable)", "ITT1", 0x00FFE000)
movec_rt("MOVEC DTT0 w/r (#$00FFE000 enable)", "DTT0", 0x00FFE000)
movec_rt("MOVEC DTT1 w/r (#$FFFFFFFF mask)",   "DTT1", 0xFFFFFFFF)
movec_rt("MOVEC URP  w/r (#$0003FE00 512-al)", "URP",  0x0003FE00)
movec_rt("MOVEC SRP  w/r (#$00003000)",        "SRP",  0x00003000)
movec_rt("MOVEC MMUSR w/r (#$FFFFFFFF mask)",  "MMUSR",0xFFFFFFFF)

-- ---- PFLUSH family (executes; no fault) -----------------------------
T{ name = "PFLUSHA",      test = pflusha() }
T{ name = "PFLUSHAN",     test = pflushan() }
T{ name = "PFLUSH (A0)",  test = pflush_a0(),  regs = { a0 = DATA_BASE } }
T{ name = "PFLUSHN (A0)", test = pflushn_a0(), regs = { a0 = DATA_BASE } }

-- ---- Live translation (TC.E=1, page tables active) ------------------
-- mmu_setup is applied via the Lua state interface before the run:
--   ITT0 = transparent (instructions), DTT*=0, SRP=URP=ROOT_TBL, TC=4K on.
local function live(name, body, opts)
    opts = opts or {}
    T{ name   = name,
       test   = body,
       plants = id_tables(opts.tables),
       regs   = opts.regs,
       live   = true,
       raises_exception = opts.raises_exception }
end
live("LIVE identity store: va $1F010 <- D1 (M/U writeback in page[$1F])",
     move_l_dn_abs(1, 0x0001F010),
     { regs = { d1 = 0xCAFED00D } })
live("LIVE remap store: va $9010 -> pa $1F010 (page[9] override)",
     move_l_dn_abs(1, 0x00009010),
     { tables = { page = { [9] = page_desc(REMAP_PA, 0) } },
       regs = { d1 = 0xFEEDC0DE } })
live("LIVE remap load: va $9020 reads pa $1F020 (U-bit set, M clear)",
     move_l_abs_dn(0x00009020, 2),
     { tables = { page = { [9] = page_desc(REMAP_PA, 0) } },
       regs = { d2 = 0 },
       -- plant the source longword at the physical target
       extra_plants = { { REMAP_PA + 0x20, 0xCAFEBABE } } })
live("LIVE ATC stale: edit page[9] without PFLUSH, store again",
     concat(move_l_dn_abs(1, 0x00009010),                        -- loads ATC
            move_l_imm_abs(page_desc(REMAP2_PA, 0), PAGE_TBL + 9 * 4),
            move_l_dn_abs(2, 0x00009014)),                       -- stale or not?
     { tables = { page = { [9] = page_desc(REMAP_PA, 0) } },
       regs = { d1 = 0x11111111, d2 = 0x22222222 } })
live("LIVE ATC flush: edit page[9] + PFLUSHA, store goes to new pa",
     concat(move_l_dn_abs(1, 0x00009010),
            move_l_imm_abs(page_desc(REMAP2_PA, 0), PAGE_TBL + 9 * 4),
            pflusha(),
            move_l_dn_abs(2, 0x00009014)),
     { tables = { page = { [9] = page_desc(REMAP_PA, 0) } },
       regs = { d1 = 0x33333333, d2 = 0x44444444 } })

-- ---- Faults (format-$7 frame; hw_unsafe until the runner proves safe) -
live("FAULT store to write-protected page (berr, vec 2)",
     move_l_dn_abs(1, 0x00009010),
     { tables = { page = { [9] = page_desc(REMAP_PA, PG_W) } },
       regs = { d1 = 0x55555555 }, raises_exception = true })
live("FAULT store to invalid page (PDT=0, berr)",
     move_l_dn_abs(1, 0x00009010),
     { tables = { page = { [9] = 0 } },
       regs = { d1 = 0x66666666 }, raises_exception = true })
live("FAULT supervisor-only page from user fc (berr)",
     -- access made via MOVES with SFC=user-data would be cleaner; here we
     -- mark the page S and rely on the supervisor test still faulting only
     -- if fc&4==0. Captured as a discriminator row for the hardware runner.
     move_l_dn_abs(1, 0x00009010),
     { tables = { page = { [9] = page_desc(REMAP_PA, PG_S) } },
       regs = { d1 = 0x77777777 } })

-- ---- PTEST (HARDWARE-ADJUDICATED: MAME 040 PTEST/MMUSR incomplete) ---
-- These carry the single-word 68040 encodings so the hardware runner can
-- exercise them; the MAME golden is best-effort only (see header note).
T{ name = "PTESTR (A0) va $9000 (hw-adjudicated; MAME MMUSR incomplete)",
   test = ptestr_a0(), plants = id_tables({ page = { [9] = page_desc(REMAP_PA, 0) } }),
   regs = { a0 = 0x00009000 }, live = true, hw_note = true }
T{ name = "PTESTW (A0) va $9000 write-protected (hw-adjudicated)",
   test = ptestw_a0(), plants = id_tables({ page = { [9] = page_desc(REMAP_PA, PG_W) } }),
   regs = { a0 = 0x00009000 }, live = true, hw_note = true }

-- ---------------------------------------------------------------------
-- Snapshot machinery
-- ---------------------------------------------------------------------
local function read_windows()
    local snap = {}
    for _, w in ipairs(WINDOWS) do
        local base, len = w[1], w[2]
        local bytes = {}
        for i = 0, len - 1 do bytes[i] = prog:read_u8(base + i) end
        snap[#snap + 1] = { base = base, len = len, bytes = bytes }
    end
    return snap
end

local function snap_state()
    local s = { d = {}, a = {} }
    for r = 0, 7 do
        s.d[r] = rget("D" .. r)
        s.a[r] = rget("A" .. r)
    end
    s.pc  = rget("PC")
    s.sr  = rget("SR")
    s.mmu = {
        tc    = rget("TC"),
        itt0  = rget("ITT0"), itt1 = rget("ITT1"),
        dtt0  = rget("DTT0"), dtt1 = rget("DTT1"),
        urp   = rget("URP"),  srp  = rget("SRP"),
        mmusr = rget("PSR") & 0xFFFFFFFF,   -- MAME exposes 040 MMUSR as "PSR"
    }
    return s
end

local function json_state(s, ram_pairs)
    local d, a = {}, {}
    for r = 0, 7 do
        d[#d + 1] = string.format("%u", s.d[r])
        a[#a + 1] = string.format("%u", s.a[r])
    end
    local ram = {}
    for _, p in ipairs(ram_pairs) do
        ram[#ram + 1] = string.format("[%u,%u]", p[1], p[2])
    end
    return string.format(
        '{"d":[%s],"a":[%s],"pc":%u,"sr":%u,' ..
        '"mmu":{"tc":%u,"itt0":%u,"itt1":%u,"dtt0":%u,"dtt1":%u,' ..
        '"urp":%u,"srp":%u,"mmusr":%u},"ram":[%s]}',
        table.concat(d, ","), table.concat(a, ","), s.pc, s.sr,
        s.mmu.tc, s.mmu.itt0, s.mmu.itt1, s.mmu.dtt0, s.mmu.dtt1,
        s.mmu.urp, s.mmu.srp, s.mmu.mmusr, table.concat(ram, ","))
end

-- ---------------------------------------------------------------------
-- C header emission (preboot supervisor bench input)
-- ---------------------------------------------------------------------
local hdr_rows = {}
local function hdr_add(t, test_bytes, plant_list, regs, mmu_init)
    local tb = {}
    for _, b in ipairs(test_bytes) do tb[#tb + 1] = string.format("0x%02X", b) end
    local plants = {}
    for _, p in ipairs(plant_list) do
        plants[#plants + 1] = string.format("{0x%08XU,0x%08XU}", p[1], p[2])
    end
    local dl, al = {}, {}
    for r = 0, 7 do dl[#dl + 1] = string.format("0x%08XU", regs.d[r]) end
    for r = 0, 7 do al[#al + 1] = string.format("0x%08XU", regs.a[r]) end
    hdr_rows[#hdr_rows + 1] = string.format(
        '    {"%s",\n      {%s}, %d,\n      {%s}, %d,\n' ..
        '      {%s},\n      {%s},\n' ..
        '      0x%08XU,0x%08XU,0x%08XU,0x%08XU,0x%08XU,0x%08XU,0x%08XU,\n' ..
        '      %d, %d, %d, %d},',
        t.name:gsub('"', '\\"'),
        table.concat(tb, ","), #test_bytes,
        table.concat(plants, ","), #plants,
        table.concat(dl, ","), table.concat(al, ","),
        mmu_init.tc, mmu_init.itt0, mmu_init.itt1, mmu_init.dtt0, mmu_init.dtt1,
        mmu_init.urp, mmu_init.srp,
        1,                                         -- privileged (always)
        t.live and 1 or 0,
        t.raises_exception and 1 or 0,
        (t.raises_exception or t.hw_note) and 1 or 0)   -- hw_unsafe
end

local function write_header()
    local fh = io.open(OUT_H, "w")
    fh:write([[
/* Auto-generated by SingleStepTests/gen/mame_mmu_capture.lua.
 * Do not edit by hand -- regenerate by re-running the script.
 * 68040 MMU corpus for the Macintosh Quadra 800 preboot bench. */
#ifndef MMU_TESTS_H
#define MMU_TESTS_H

#define MMU_TEST_MAX_BYTES  64
#define MMU_TEST_MAX_PLANTS 80

typedef struct {
    unsigned long addr;
    unsigned long value;          /* 32-bit big-endian longword */
} MmuPlant;

typedef struct {
    const char *name;
    unsigned char test[MMU_TEST_MAX_BYTES];
    unsigned short test_len;
    MmuPlant plants[MMU_TEST_MAX_PLANTS];
    unsigned short n_plants;
    /* initial GP registers (a[7] = corpus SSP; the hardware runner
     * substitutes its relocated test stack) */
    unsigned long d[8];
    unsigned long a[8];
    /* initial 68040 MMU register state (set via MOVEC prologue on hw) */
    unsigned long tc, itt0, itt1, dtt0, dtt1, urp, srp;
    unsigned char privileged;     /* always 1 */
    unsigned char mmu_live;       /* translation enabled during the test */
    unsigned char raises_exception;
    unsigned char hw_unsafe;      /* run only after the safe rows pass */
} MmuTestSpec;

static MmuTestSpec g_mmu_tests[] = {
]])
    fh:write(table.concat(hdr_rows, "\n"))
    fh:write(string.format([[

};
#define MMU_N_TESTS %d
#endif /* MMU_TESTS_H */
]], #hdr_rows))
    fh:close()
end

-- ---------------------------------------------------------------------
-- Frame-driven state machine
-- ---------------------------------------------------------------------
local RAM_PROBE_VALUE = 0xDEADBEEF
local MAX_WAIT_FRAMES = 1800
local MAX_RUN_FRAMES  = 120

local phase     = "WAIT_RAM"
local frames    = 0
local test_i    = 1
local stop_pc   = 0
local out_file  = nil
local n_written = 0
local n_timeout = 0
local cur_init  = nil
local cur_plant = nil
local cur_mmu   = nil

local function start_test(t)
    for _, w in ipairs(WINDOWS) do
        for i = 0, w[2] - 1 do prog:write_u8(w[1] + i, 0) end
    end

    -- plants (table structures, operands)
    local plant_pairs = {}
    local plants = t.plants or {}
    if t.extra_plants then
        local merged = {}
        for _, p in ipairs(plants) do merged[#merged + 1] = p end
        for _, p in ipairs(t.extra_plants) do merged[#merged + 1] = p end
        plants = merged
    end
    for _, p in ipairs(plants) do
        prog:write_u32(p[1], p[2])
        for i = 0, 3 do
            plant_pairs[#plant_pairs + 1] =
                { p[1] + i, (p[2] >> ((3 - i) * 8)) & 0xFF }
        end
    end

    -- Program = [MMU-enable prologue][test bytes][JMP self catcher].
    -- The prologue programs TC via MOVEC (D7) -- the ONLY way to set
    -- MAME's m_pmmu_enabled (writing TC through the Lua state interface
    -- does NOT enable translation). Live rows enable 4K translation;
    -- every other row forces TC=0 so it can't inherit a prior live row's
    -- enabled state. D7 is the reserved MMU-control temp (the diff tool
    -- ignores it). Instruction fetch stays transparent via ITT0, so the
    -- prologue and body always fetch regardless of page-table state.
    -- The corpus HEADER records only the test bytes (t.test); the
    -- hardware runner installs its own MOVEC-based MMU setup.
    local tcval = t.live and TC_4K_ON or TC_OFF
    local prologue = concat(move_l_imm_dn(7, tcval), movec_to(CTRL.TC, 7))
    local body = t.test
    local body_at = PROG_BASE + #prologue
    local jmp_pc = body_at + #body
    local prog_bytes = concat(prologue, body, bw(0x4EF9), bl(jmp_pc))
    write_bytes(PROG_BASE, prog_bytes)
    stop_pc = jmp_pc

    local catcher = jmp_pc
    for v = 0, 255 do prog:write_u32(VEC_BASE + v * 4, catcher) end

    -- GP registers
    for r = 0, 7 do
        rset("D" .. r, 0xD0000000 + r * 0x01010101)
        if r < 7 then rset("A" .. r, 0xA0000000 + r * 0x01010101) end
    end
    rset("A0", DATA_BASE)
    rset("A7", STACK_TOP)
    if t.regs then
        for k, v in pairs(t.regs) do rset(k:upper(), v) end
    end
    rset("SR", 0x2700)
    rset("PC", PROG_BASE)
    rset("VBR", VEC_BASE)
    if cpu.state["SFC"] then rset("SFC", 5) end
    if cpu.state["DFC"] then rset("DFC", 5) end

    -- MMU registers. Instructions always transparent (ITT0); data goes
    -- through the page tables only when this is a live row.
    local mmu = {
        tc   = t.live and TC_4K_ON or TC_OFF,
        itt0 = ITT_ALL, itt1 = 0, dtt0 = 0, dtt1 = 0,
        urp  = ROOT_TBL, srp = ROOT_TBL,
    }
    rset("TC", mmu.tc)
    rset("ITT0", mmu.itt0); rset("ITT1", mmu.itt1)
    rset("DTT0", mmu.dtt0); rset("DTT1", mmu.dtt1)
    rset("URP", mmu.urp);   rset("SRP", mmu.srp)

    cur_init  = snap_state()
    cur_plant = plant_pairs
    cur_mmu   = mmu
    hdr_add(t, body, plants, cur_init, mmu)
    frames = 0
end

local function finish_test(t, timed_out)
    local final = snap_state()
    local init_byte = {}
    for _, p in ipairs(cur_plant) do init_byte[p[1]] = p[2] end
    local diffs = {}
    for _, w in ipairs(WINDOWS) do
        for i = 0, w[2] - 1 do
            local addr = w[1] + i
            local now  = prog:read_u8(addr)
            local was  = init_byte[addr] or 0
            if now ~= was then diffs[#diffs + 1] = { addr, now } end
        end
    end
    local f = {
        privileged = true,
        mmu_live = t.live and true or false,
        raises_exception = t.raises_exception and true or false,
        hw_unsafe = (t.raises_exception or t.hw_note) and true or false,
    }
    local flagstr = string.format(
        '{"privileged":true,"mmu_live":%s,"raises_exception":%s,"hw_unsafe":%s}',
        tostring(f.mmu_live), tostring(f.raises_exception), tostring(f.hw_unsafe))
    out_file:write(string.format(
        '{"name":%q,"flags":%s,"timed_out":%s,"initial":%s,"final":%s}\n',
        t.name, flagstr, timed_out and "true" or "false",
        json_state(cur_init, cur_plant),
        json_state(final, diffs)))
    out_file:flush()
    n_written = n_written + 1
    if timed_out then n_timeout = n_timeout + 1 end
end

local function tick()
    init_handles()
    if phase == "WAIT_RAM" then
        prog:write_u32(PROG_BASE, RAM_PROBE_VALUE)
        frames = frames + 1
        if prog:read_u32(PROG_BASE) == RAM_PROBE_VALUE then
            print(string.format("RAM mapped at $%08X after %d frames.",
                PROG_BASE, frames))
            out_file = io.open(OUT_JSON, "w")
            if out_file == nil then
                print("ERROR: cannot open " .. OUT_JSON)
                phase = "EXITED"; manager.machine:exit(); return
            end
            phase = "SETUP_NEXT"; frames = 0
        elseif frames >= MAX_WAIT_FRAMES then
            print("ERROR: RAM never mapped; aborting.")
            phase = "EXITED"; manager.machine:exit()
        end
    elseif phase == "SETUP_NEXT" then
        if test_i > #tests then phase = "DONE"; return end
        local t = tests[test_i]
        print(string.format("[%d/%d] %s", test_i, #tests, t.name))
        emu.pause(); start_test(t); emu.unpause()
        phase = "RUN"
    elseif phase == "RUN" then
        frames = frames + 1
        if rget("PC") == stop_pc then
            emu.pause(); finish_test(tests[test_i], false)
            rset("TC", 0)                 -- translation off before next test
            emu.unpause()
            test_i = test_i + 1; phase = "SETUP_NEXT"
        elseif frames >= MAX_RUN_FRAMES then
            print(string.format("  TIMEOUT: PC=$%08X expected $%08X SR=$%04X",
                rget("PC"), stop_pc, rget("SR")))
            emu.pause(); finish_test(tests[test_i], true)
            rset("TC", 0)
            emu.unpause()
            test_i = test_i + 1; phase = "SETUP_NEXT"
        end
    elseif phase == "DONE" then
        out_file:close()
        write_header()
        print(string.format("Wrote %d tests (%d timeouts) to %s and %s",
            n_written, n_timeout, OUT_JSON, OUT_H))
        phase = "EXITED"; manager.machine:exit()
    end
end

emu.register_frame_done(tick, "mmu_capture")
print(string.format(
    "mame_mmu_capture.lua loaded -- %d tests queued.", #tests))
