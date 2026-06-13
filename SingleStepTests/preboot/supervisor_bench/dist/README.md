# Prebuilt Quadra 800 supervisor-mode bench disks

Bootable disk images of the three 68040 benches, ready to run on a real
Macintosh Quadra 800 (or any 68040 Mac). Each disk boots straight into
the bench (no System needed) via the HFS boot block; the bench takes over
in supervisor mode, runs its corpus, paints progress on the built-in DAFB
display, and writes results to **`/Results.jsonl`** on the same disk.

| Disk | Bench | Corpus |
|---|---|---|
| `quadra800-cpu.{hda,dsk}` | 68040 integer CPU | 722 rows (full ISA + 040 discriminators) |
| `quadra800-fpu.{hda,dsk}` | 68040 FPU | 270 rows; hardware subset executes, unimplemented ops trap (vector 11) |
| `quadra800-mmu.{hda,dsk}` | 68040 MMU | 24 rows; register-mask + PFLUSH run, live/fault rows skipped (see note) |

- **`.hda`** — SCSI hard-disk image (APM + Apple_HFS). Write to a
  BlueSCSI / SCSI2SD / real SCSI disk, or attach in an emulator.
- **`.dsk`** — 800 K HFS floppy image. Write with Disk Copy / a Greaseweazle
  / `dd` to a real 800K floppy, or mount in an emulator.

## Running on hardware

1. Boot the Quadra 800 from the disk (hold the SCSI ID's boot order, or
   insert the floppy). It boots directly into the bench — you'll see a
   black screen with white text: a header, the current test index/name,
   and a running `run= / ok= / trap=` tally.
2. Let it run to **"ALL TESTS DONE - writing results..."** /
   **"Power off and extract /Results.jsonl"**.
3. Power off, move the disk to a modern machine, and pull
   `/Results.jsonl`.
4. Diff against the MAME baseline:
   ```sh
   SingleStepTests/gen/cpu_diff_corpus.py \
     SingleStepTests/results/cpu/mame_baseline_2026-06-12.json /path/to/Results.jsonl
   # fpu: compare the taken vector per row (vec 11 = unimplemented op trapped)
   # mmu: SingleStepTests/gen/mmu_diff_corpus.py results/mmu/mame_baseline_*.json Results.jsonl
   ```

## Validation status (2026-06-13)

Boot-tested in MAME `macqd800` (real Quadra 800 ROM): all three disks
boot on the 68040, the payload runs, and the **built-in DAFB 1 bpp
display paints** (`ScrnBase=$F9001000`, the DAFB VRAM window). The bench
reads the row stride from the ROM's `ScrnRow`/`ScrnBase` globals at
runtime, so it adapts to whatever resolution the Quadra is set to.

> **MAME caveat:** MAME's 68040 SCSI write-back doesn't persist
> `/Results.jsonl` (a known emulator limitation — the disk boots and the
> bench runs, but results read back empty under MAME). On **real
> hardware** the raw-sector `_Write` path persists results — that's how
> the predecessor Mac II / IIvi benches collected their JSONL. The screen
> tally is your live confirmation either way.

## Notes

- **MMU bench:** the register-characterization + PFLUSH rows run; the
  live-translation and fault rows are emitted `skipped:"live-reloc-todo"`
  pending the private-identity-page-table relocation (port from
  `../mmu_bench_main.c.68030-reference`). See `../../../test-blockers.md`.
- **FPU bench:** assumes MC68040-lite + no FPSP — transcendentals are
  expected to trap (vector 11). If your core embeds a full 68882 FPU,
  those rows will execute instead; that's the discriminator.
- Rebuild any image with `./build_<bench>_<hda|dsk>.sh` from the parent
  directory (needs `rb-cli`, `jq`, and `~/testdisk.hda` for the .hda
  template).
- These images are ~21 MB each (mostly-empty SCSI template); they gzip to
  ~1 MB if you want to archive them.
