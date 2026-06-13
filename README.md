# wombat33_MiSTer — Macintosh Quadra 800 (MC68040)

A MiSTer FPGA core for the Apple **Macintosh Quadra 800** (codename
*Wombat*): MC68040 @ 33 MHz, djMEMC memory controller with integrated
DAFB II built-in video, IOSB I/O. This repository currently holds the
**verification testbench suite** that drives the core's bring-up; the RTL
core lands on top of it.

## Testbench (`SingleStepTests/`)

Per-instruction CPU / FPU / MMU benches captured against MAME's
`macquadra800` driver as the oracle, designed to also run on real Quadra
800 hardware (boot the payload, collect `/Results.jsonl`, diff offline).
Lineage: ported from the 68020 Mac II bench (`../lbmactwo_MiSTer`) via the
68030 Macintosh IIvi bench (`../MacIIvi_MiSTer`), with the FPU material
re-imported (the 040 has an on-chip FPU).

**Read [`QUADRA800_TESTBENCH.md`](QUADRA800_TESTBENCH.md) first** — the
master plan, with the verified machine facts, the 040-lite FPU
execute-vs-trap model, the 68040 MMU corpus design, and the hardware
campaign. Status & quirks: [`SingleStepTests/test-blockers.md`](SingleStepTests/test-blockers.md).

### Quick start

```sh
# Build the bootable bench payloads (Retro68 toolchain, -m68040):
cd SingleStepTests/preboot/supervisor_bench
make cpu        # 68040 integer corpus  (722 rows)
make fpu        # 68040 FPU corpus       (execute-vs-trap, vector 11)
make mmu        # 68040 MMU corpus       (MOVEC regs, live walk, format-$7)

# Re-capture the MAME baselines (needs ~/repos/mame built with the driver):
cd ~/repos/mame
./mame macqd800 -skip_gameinfo -nothrottle -video none -sound none \
   -seconds_to_run 200 -autoboot_delay 1 \
   -autoboot_script <repo>/SingleStepTests/gen/mame_cpu_capture.lua

# Diff a hardware run against the baseline:
SingleStepTests/gen/cpu_diff_corpus.py \
   SingleStepTests/results/cpu/mame_baseline_2026-06-12.json /path/to/Results.jsonl
```

### What's verified (2026-06-12)

- CPU + MMU corpora captured from MAME `macqd800`; all three payloads build.
- MMU bench exercises live 68040 translation (U/M writeback), remap, ATC
  flush, and format-$7 access faults (vector 2).
- FPU bench distinguishes the 040 hardware subset (executes) from the
  unimplemented ops (vector-11 trap) — the FPGA-lite-FPU discriminator.

Display uses the built-in DAFB at `$F9000000`, 1 bpp, with the row stride
read from the ROM's `ScrnRow`/`ScrnBase` globals at runtime (the correct
Quadra 800 built-in mechanism — the stride is software-programmed).
