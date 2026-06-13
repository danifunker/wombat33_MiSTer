# Macintosh Quadra 800 — 68040 CPU / FPU / MMU Testbench Plan

*2026-06-12. Master plan for the SingleStepTests port and the
68040 verification campaign for the Macintosh Quadra 800 (Wombat) core.
Everything marked **verified** below was checked against MAME source
(`~/repos/mame`, driver `macquadra800.cpp`) or produced by an actual MAME
`macqd800` run on 2026-06-12. Lineage: this tree descends from the
68020 Mac II bench (`../lbmactwo_MiSTer`) via the 68030 Macintosh IIvi
bench (`../MacIIvi_MiSTer`); the FPU material was re-imported from the
Mac II project (the IIvi has no FPU; the Quadra 800 does).*

---

## 1. Target machine (verified against MAME `macquadra800.cpp`)

| Component | Fact | Source |
|---|---|---|
| CPU | **MC68040 @ 33 MHz** | macquadra800.cpp:179 |
| Clocks | C32M = 31.3344 MHz, C15M = C32M/2, C7M = C32M/4 | :44-46 |
| Memory ctlr | **djMEMC** @ 33 MHz (RAM + integrated DAFB II video) | :183 |
| I/O | **IOSB** (VIA1/VIA2, audio, SWIM2, Turbo SCSI), DFAC audio, SCC 85C30 @ C7M, NCR53C96 SCSI, SONIC Ethernet | :188-240 |
| Machine ID | IOSB PA bits = **0x12** (Quadra 800) | :193-197 |
| RAM | 8 MB base, expandable | driver |
| ROM | 1 MB `f1acad13.rom` CRC32 `4e70e3c0` ("23F2"); alt `f1a6f343.rom` ("23F1") | :338-349 |
| Video | **DAFB II (DAFB_MEMC)**, VRAM at CPU `$F9000000` (2 MB), DAFB regs at `$F9800000` | djmemc.cpp:29-31, dafb.cpp |
| Flags | `MACHINE_SUPPORTS_SAVE` (no `MACHINE_NOT_WORKING`) | :353 |

The Wombat/Speedbump family shares the driver: `macqd800` (this core),
`macct610`, `macct650`, `macqd610`, `macqd650`. The MC68040 device is
identical across them, so the CPU/FPU/MMU corpora are oracle-agnostic.

## 2. What this port delivered (done, validated 2026-06-12)

```
SingleStepTests/
├── gen/
│   ├── gen.c                     Musashi generator -> M68K_CPU_TYPE_68040
│   ├── gen_fpu.c                 SELF-CONTAINED FPU oracle (host IEEE math);
│   │                             tags ops EXECUTE (040 HW) vs TRAP (vec 11)
│   ├── mame_cpu_capture.lua      -> macqd800; +MOVE16, +040 CACR/CAAR/RTM rows
│   ├── mame_mmu_capture.lua      NEW: 68040 MMU (MOVEC regs, fixed 3-level walk,
│   │                             live translation, format-$7 faults) [VERIFIED]
│   ├── mame_mmu_smoke.lua        state-interface sanity (8 MMU regs) [VERIFIED]
│   ├── cpu_tests.h               722-row 68040 corpus (captured)
│   ├── mmu_tests.h               24-row 68040 MMU corpus (captured)
│   ├── fpu_tests.h               270-row FPU corpus w/ traps[] classification
│   ├── mmu_diff_corpus.py        040 MMU hardware-vs-MAME diff
│   └── cpu_diff_corpus.py        CPU hardware-vs-MAME diff (carried)
├── preboot/
│   ├── common/                   boot blocks, recovery.s (MMU_RECOVERY=MOVEC),
│   │                             display_1bpp.c (DAFB/auto), jsonl writer
│   └── supervisor_bench/
│       ├── bench_main.c          CPU runner (cpusha cache flush)        [BUILDS]
│       ├── fpu_bench_main.c      FPU runner — records taken vector       [BUILDS]
│       ├── mmu_bench_main.c      68040 MMU runner (MOVEC save/restore)   [BUILDS]
│       ├── mmu_bench_main.c.68030-reference   the 030 runner, for porting
│       │                                       the live/fault relocation path
│       └── Makefile              make cpu | fpu | mmu  (all build, -m68040)
├── macos_bench/                  CpuBench + FpuBench Mac apps; gen_fpu_header.py
│                                 (040-lite execute/trap classification)
├── results/{cpu,mmu,fpu}/        MAME baselines, dated 2026-06-12
└── video/, mmu/                  bench contracts (README.md each)
```

**Build proof (2026-06-12):** `make cpu`, `make fpu`, `make mmu` all
produce bootable payloads with the Retro68 `m68k-apple-macos-gcc -m68040`
toolchain against the captured corpora (125K / 32K / 27K respectively).

## 3. CPU bench — captured from MAME `macqd800` (verified)

`mame_cpu_capture.lua` → 722 rows in `results/cpu/mame_baseline_2026-06-12.json`
and `gen/cpu_tests.h`. The full 68020/68030 integer ISA executes unchanged
on the 68040, so the bulk corpus carried over byte-identical; the 68040
deltas are discriminator rows:

| Row | 68040 behaviour | MAME capture | Real-silicon note |
|---|---|---|---|
| **MOVE16 (A0)+,(A1)+** | executes (16-byte burst copy) | executes ✓ | 040-only; illegal on 020/030 |
| **MOVEC CACR all-ones** | writable mask = DE+IE = `$80008000` | `$FFFFFFF3` (over-wide) | **adjudicate on HW** |
| **CALLM / RTM** | illegal → vec 4 | CALLM traps ✓; **RTM no-ops** (MAME bug) | RTM golden known-bad |
| CAAR ($802) | removed on 040 (undefined) | MAME still round-trips it | adjudicate on HW |

Diff hardware JSONL against the baseline with `gen/cpu_diff_corpus.py`.
The CPU corpus is also independently regenerable via the Musashi
generator (`gen/gen.c`, `M68K_CPU_TYPE_68040`) — needs `~/repos/Musashi`
checked out (kstenerud/Musashi has the 68040 type) — but the MAME capture
is the canonical oracle.

## 4. FPU bench — 040-lite execute-vs-trap model (the key design choice)

The MC68040 on-chip FPU implements only the **arithmetic subset** in
silicon. Transcendentals (FSIN/FCOS/FTAN/FETOX/FLOGx/FATAN/…), FMOD,
FREM, FSCALE, FSGLMUL, FSGLDIV, FGETEXP, FGETMAN take the
**Unimplemented-Floating-Point-Instruction exception (vector 11**, the
Line-F emulator vector) so Apple's FPSP040 software emulates them. On a
Quadra 800 FPGA core in **MC68040-lite mode** (the 68881-fpga sibling's
`fpu_lite_g` build — no trig/sglops/modrem engines) **without FPSP
loaded**, the observable is the trap, not a result.

So the corpus is split (`gen_fpu.c` + `macos_bench/gen_fpu_header.py`):

| Class | Ops | Expected | Oracle |
|---|---|---|---|
| **EXECUTE** | FADD FSUB FMUL FDIV FSQRT FNEG FABS FINT FINTRZ FCMP FTST FMOVE(M) | computed IEEE result | `gen_fpu.c` host math |
| **TRAP** | FSIN FCOS FTAN FATAN FASIN FACOS FETOX(M1) FLOG{N,NP1,10,2} F{SIN,COS,TAN}H FATANH FT{WO,EN}TOX FMOD FREM FSCALE FSGLMUL FSGLDIV FGETEXP FGETMAN | **vector 11 trap**, FPn unchanged | MC68040 UM |

`fpu_tests.h` carries `traps`/`exc_vec` per row (142 trap / 128 execute of
270). The runner (`fpu_bench_main.c`) records the **taken vector** for
each test: an EXECUTE row that traps, or a TRAP row that returns a result
(full-68882 behaviour), is the failure signal.

> **MAME is NOT the FPU oracle.** MAME's 68040 wrongly *executes* the
> transcendentals (no trap), so `mame_fpu_capture.lua` would mis-predict
> every TRAP row. The expectation comes from the 68040 manual, computed
> by `gen_fpu.c`. There is a larger integer-operand corpus in
> `gen/gen_fpu.c` (1728 rows, `results/fpu/generator_baseline_2026-06-12.json`)
> and a richer extended-precision corpus in `gen_fpu_header.py` (inf/nan/
> pi operands) — both tag execute vs trap identically.

The FSAVE/FRESTORE (cpSAVE/cpRESTORE) material carried from the Mac II
project uses **68881/68882 frame formats**; the 68040 FSAVE frames differ
($00 null / $30 idle / $60 busy with 040 sub-unit layout). Those rows
need 040 frame regeneration before use — see test-blockers.md.

## 5. MMU bench — 68040 MMU, captured from MAME (verified)

`mame_mmu_capture.lua` → 24 rows in `results/mmu/mame_baseline_2026-06-12.json`
and `gen/mmu_tests.h`. The 68040 MMU differs fundamentally from the 030
PMMU: registers move via **MOVEC** (URP/SRP/TC/ITT0/ITT1/DTT0/DTT1/MMUSR);
the walk is a **fixed 3-level tree** (root[128]/pointer[128]/page[64] for
4K pages, no early termination, no programmable geometry); page size is
4K or 8K (TC.P); transparent translation splits into instruction
(ITT0/1) and data (DTT0/1) pairs; faults push a **format-$7** frame.

**Verified working in MAME `macqd800` (2026-06-12):**
- Live page-table translation: an identity store wrote the translated PA;
  a remap (page[9] override) store landed at the remapped PA `$1F010`;
  **U-bit writeback** appeared in root/pointer/page descriptors and the
  **M-bit** on write (not on read) — the full walk is exercised.
- ATC staleness vs `PFLUSHA`.
- Faults: write-protected and invalid pages bus-error with **a[7] −= 60**
  (format-$7 frame) and frame word **`$7008`** → format 7, **vector 2**.
- MOVEC round-trips characterize each register's writable mask (e.g. TC
  reads back `$C000` for the E+P bits on real silicon).

**MAME 68040 MMU limitations (rows flagged hw_unsafe; adjudicate on HW):**
- The single-word 68040 **PTEST ($F548/$F568) is not decoded** by MAME's
  `m68kmmu.h` (hits the "unknown PMMU instruction group" default).
- MAME's 68040 **MMUSR composition is impoverished** (`m68kmmu.h` ~858
  uses a logical-OR — only R/W bits, no physical address / M/S/G fields).
- MAME's TC and CACR accept **all 32 bits** (real 040: TC=`$C000`,
  CACR=`$80008000`).

`gen/mmu_diff_corpus.py` normalizes the hardware runner's relocated
addresses and treats PTEST/MMUSR rows as informational.

### MMU hardware runner status

`mmu_bench_main.c` (68040, builds) saves/restores the OS's live MMU state
via MOVEC and runs the **register-round-trip + PFLUSH** rows (the most
portable, oracle-clean signal) with result-address relocation. The
**live-translation + fault rows are emitted as skipped** (`live-reloc-todo`)
pending the private-identity-page-table install — port that from
`mmu_bench_main.c.68030-reference` (it solved the equivalent 030 problem).

## 6. Display — built-in DAFB, 8 bpp / 640×480 / 256 colors

The Quadra 800's built-in video is DAFB II at VRAM `$F9000000`
(`ScrnBase` = `$F9001000`). **The ROM boots it at 640×480 @ 8 bpp (256
colors, the Apple 67 Hz mode)** — *not* 1 bpp. That is the required
display mode for the bench (set Monitors to 640×480 / 256 Colors).

The paint kernel (`common/display/display_1bpp.c`, built with
`-DDISPLAY_BPP8` for `VIDEO_VARIANT=dafb`, the default) therefore writes
**one byte per pixel**: background `0xFF` (black via the default CLUT
index 255), glyph strokes `0x00` (white). The byte **stride is
software-programmed** by the ROM (1024 for 640×480) and read at runtime
from `ScrnRow` (`$0106`); `ScrnBase` (`$0824`) gives the base. So the
payload adapts to other 256-color resolutions without recompiling — only
the *depth* is fixed at 8 bpp.

> **Lesson (2026-06-13):** the first cut assumed the NuBus-era 1 bpp
> power-on default and painted 1 bit per pixel into the 8 bpp DAFB
> framebuffer — every font byte became a single 8 bpp pixel, so text came
> out as garbled speckle (reproduced from a MAME VRAM dump, fixed, and
> re-verified by host-rendering the paint kernel to a legible image). A
> `dafb1` variant keeps the 1 bpp path for B&W screens.

## 7. MAME oracle setup (verified)

```
cd ~/repos/mame
# rebuilt 2026-06-12 to add the Quadra driver (keeps the IIvi oracles):
make -j4 REGENIE=1 SOURCES=src/mame/apple/macii.cpp,\
src/mame/apple/maciici.cpp,src/mame/apple/maciivx.cpp,\
src/mame/apple/maclc.cpp,src/mame/apple/macquadra800.cpp
./mame -verifyroms macqd800        # romset macqd800 is good
```
ROM `macqd800.zip` is present in `~/repos/mame/roms/`. Capture invocation:
```
./mame macqd800 -skip_gameinfo -nothrottle -video none -sound none \
   -seconds_to_run 200 -autoboot_delay 1 \
   -autoboot_script SingleStepTests/gen/mame_<cpu|mmu>_capture.lua
```
Keep MAME usage minimal/targeted (per Dani) — the real Quadra 800 silicon
is the final adjudicator.

## 8. Hardware campaign (the imminent physical test)

1. **User-mode / supervisor CPU run:** boot `make cpu` HDA on the Quadra
   800, pull `/Results.jsonl`, diff with `gen/cpu_diff_corpus.py` against
   `results/cpu/`. Adjudicate the CACR-mask, CAAR, and RTM divergence rows.
2. **FPU run:** boot `make fpu`; confirm the EXECUTE subset matches the
   IEEE goldens and **every TRAP row takes vector 11** (proves the
   040-lite FPU has no transcendental engine / no FPSP). If a TRAP row
   returns a result, the core has a full-68882 FPU — re-scope to §4 "Full".
3. **MMU run:** boot `make mmu`; confirm the register-mask rows. Then port
   the live/fault relocation (from the 030 reference) and run those — they
   adjudicate the MAME PTEST/MMUSR gaps and the format-$7 frame on silicon.
4. **Archive:** date-stamped runs in `results/`; divergences → test-blockers.md.

## 9. Milestones & acceptance

| # | Milestone | Acceptance |
|---|---|---|
| M0 | Port complete (this commit) | `make cpu/fpu/mmu` build; CPU+MMU corpora captured from `macqd800`; FPU corpus tagged execute/trap |
| M1 | HW CPU run | diff committed; CACR/CAAR/RTM rows adjudicated |
| M2 | HW FPU run | EXECUTE rows match IEEE; TRAP rows take vec 11 (or core re-scoped to full-FPU) |
| M3 | MMU live runner | live/fault relocation ported; rows run on HW; PTEST/MMUSR silicon goldens captured |
| M4 | RTL bring-up | corpora drive the Quadra 800 core's CPU/FPU/MMU as it comes up |

## 10. Risks / open questions

- **FPU mode of the FPGA core:** the bench assumes MC68040-lite + no FPSP
  (TRAP rows expect vec 11). If the shipped core embeds a full
  68881/68882 FPU, the TRAP rows must flip to EXECUTE (one flag in
  `gen_fpu.c`/`gen_fpu_header.py`: move the opmodes into `HW_OPMODES`).
- **MAME 68040 fidelity:** PTEST unimplemented, MMUSR impoverished, TC/
  CACR masks over-wide, RTM no-op — all documented; silicon outranks MAME.
- **Musashi not checked out** at `~/repos/Musashi` (needed only for the
  alternate CPU generator). `verilator` not installed (verilator FPU
  harness under `fpu/`, `cpu_fpu/` awaits it + a 68040/68881-fpga DUT).
- **No 68040 verilator DUT yet:** the Quadra 800 core doesn't exist; the
  primary path is hardware + the MAME oracle + the self-contained
  generators, not a verilator CPU bench (TG68K is not a 68040).
