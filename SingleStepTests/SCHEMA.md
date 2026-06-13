# Test JSON schema (state-only)

Each `.json` file in a corpus is an array of test entries. One entry per
single instruction.

## CPU entry (TG68K bench)

```json
{
  "name": "ADD.l 00001",
  "initial": {
    "d0": 305419896, "d1": 0, "d2": 0, "d3": 0,
    "d4": 0, "d5": 0, "d6": 0, "d7": 0,
    "a0": 1024, "a1": 0, "a2": 0, "a3": 0,
    "a4": 0, "a5": 0, "a6": 0, "a7": 16776192,
    "pc": 4096,
    "sr": 8192,
    "usp": 0,
    "ssp": 16776192,
    "vbr": 0,
    "ram": [[4096, 208], [4097, 129]]
  },
  "final": {
    "d0": 305419896, "d1": 305419896,
    ... all regs ...,
    "pc": 4098,
    "sr": 8192,
    "ram": []
  }
}
```

Rules:
- All integer fields are unsigned decimal (json doesn't allow hex literals).
- `ram` is a list of `[address, byte]` pairs. `initial.ram` is the
  pre-state; `final.ram` lists only bytes that DIFFER from `initial`
  (so empty array = unchanged).
- Reg names match Musashi: `d0..d7`, `a0..a7`, `pc`, `sr`, `usp`, `ssp`,
  `vbr`. `a7` and `ssp`/`usp` are redundant per supervisor state; bench
  uses `a7` and ignores the other two for now (kept for future
  privileged-mode tests).
- `pc` is the address of the next instruction (post-fetch).
- No cycle counts. The bench runs until the CPU returns to idle
  (busstate=01) after consuming the instruction.

## MMU entry (68040 MMU bench)

One JSON object per line (JSON Lines), produced by
`gen/mame_mmu_capture.lua`. Baseline corpus:
`results/mmu/mame_baseline_2026-06-12.json` (24 tests, captured from
MAME `macqd800` — the MC68040 oracle is driver-independent).

```json
{
  "name": "LIVE remap store: va $9010 -> pa $1F010 (page[9] override)",
  "flags": {
    "privileged": true,          // all MMU tests (supervisor-only)
    "mmu_live": false,           // translation enabled (TC.E=1) during test
    "raises_exception": false,   // expected access fault (berr, vector 2)
    "hw_unsafe": false           // run only after the safe rows pass
  },
  "timed_out": false,
  "initial": {
    "d": [8],  "a": [8],         // D0..D7 / A0..A7 (a[7] = SSP, starts $40000)
    "pc": 4096, "sr": 9984,
    "mmu": {                     // 68040 registers (MOVEC-accessible)
      "tc": 0, "itt0": 16760832, // ITT0 = $00FFC000 (transparent instr fetch)
      "itt1": 0, "dtt0": 0, "dtt1": 0,
      "urp": 12288, "srp": 12288,// both = root table $3000
      "mmusr": 0                 // MAME exposes 040 MMUSR as state "PSR"
    },
    "ram": [[12288, 514], ...]   // planted bytes (root/ptr/page tables, data)
  },
  "final": { ... same shape ..., "ram": [] }   // only DIFFERING bytes
}
```

Rules (in addition to the CPU rules above):

- Each test program is `[MMU-enable prologue][test bytes][JMP self]` at
  `$1000`. The prologue does `MOVE.L #tc,D7 ; MOVEC D7,TC` — the ONLY way
  to set MAME's `m_pmmu_enabled` (writing TC via the Lua state interface
  does NOT enable translation). Live rows enable 4K translation
  (`TC=$8000`); all others force `TC=0`. **D7 is the reserved MMU-control
  temp; the diff tool ignores it.** The corpus records only the test
  bytes (not the prologue) — the hardware runner installs its own
  MOVEC-based MMU setup. The capture forces `TC=0` after each test, so
  `final.mmu.tc` is always 0; a test's TC effect shows in `final.ram`.
- Instruction fetch is transparent via ITT0, so the program always
  fetches regardless of page-table state; DATA accesses go through the
  page tables (the translations under test). The low region `$0..$3FFFF`
  is identity-mapped by one page table so the stack and scratch resolve.
- Snapshot windows (zeroed before plant, diffed after): data `$1800`,
  root `$3000`, pointer `$3200`, page table `$3400` (64 entries), remap
  pages `$1F000`/`$1E000`, stack `$3FFA0`. Descriptor **U-bit** (used,
  `+$08`) and **M-bit** (modified, `+$10`, writes only) updates by the
  walk land in these diffs — expected behavior, not noise.
- A fault shows `final.a[7] < initial.a[7]` (the 68040 pushes a
  **format-$7** 60-byte access-error frame); the frame's format/vector
  word `$7008` (format 7, vector offset 8 → **vector 2**) is captured in
  the stack window.
- Known MAME 68040 quirks (tracked in test-blockers.md): single-word
  PTEST `$F548`/`$F568` is unimplemented; the MMUSR composition is
  impoverished; TC/CACR accept over-wide masks. PTEST/MMUSR rows are
  flagged `hw_unsafe` and adjudicated on real Quadra 800 silicon.

## FPU entry (68040 FPU bench)

The FPU corpus (`gen/fpu_tests.h`, `macos_bench/gen_fpu_header.py`) adds a
per-test classification for the 040-lite execute-vs-trap model:

- `"traps": 0` — a 68040 **hardware-subset** op (FADD/FSUB/FMUL/FDIV/
  FSQRT/FNEG/FABS/FINT/FINTRZ/FCMP/FTST/FMOVE). Expected: computed IEEE
  result (oracle = `gen_fpu.c` host math).
- `"traps": 1, "exc_vec": 11` — an op the 68040 does NOT implement in
  silicon (transcendentals, FMOD/FREM/FSCALE, FSGLMUL/FSGLDIV, FGETEXP/
  FGETMAN). Expected: the **unimplemented-FP exception, vector 11**, with
  FPn unchanged. MAME wrongly executes these, so MAME is not the oracle.

The runner (`fpu_bench_main.c`) records the **taken vector** per test:
`vec=0` with a `final` snapshot for executed ops, or `vec=11` with a
`trap_state` snapshot for trapping ops. A mismatch (an execute row that
trapped, or a trap row that returned a result) is the failure signal.
