# Prebuilt Quadra 800 bench disks (committed fixtures)

Compressed, ready-to-run bootable disk images of the three 68040 benches.
Each `.tgz` holds the SCSI hard-disk image (`.hda`) and the 800 K HFS
floppy (`.dsk`) for one bench. Boot a Quadra 800 (or any 68040 Mac) from
the disk and it runs the bench straight from the HFS boot block — no
System needed — painting progress on the built-in DAFB display and
writing `/Results.jsonl` back to the same disk.

| Bundle (`2026-06-13`) | Bench | Corpus |
|---|---|---|
| `quadra800-cpu-2026-06-13.tgz` | 68040 integer CPU | 722 rows (full ISA + 040 discriminators: MOVE16, CACR/CAAR mask, RTM) |
| `quadra800-fpu-2026-06-13.tgz` | 68040 FPU | 270 rows; hardware subset executes, unimplemented ops trap (vector 11) |
| `quadra800-mmu-2026-06-13.tgz` | 68040 MMU | 24 rows; register-mask + PFLUSH run, live/fault rows skipped (see note) |

## Use

```sh
tar xzf quadra800-cpu-2026-06-13.tgz       # -> quadra800-cpu.hda + .dsk
sha256sum -c SHA256SUMS                     # verify the bundles first
```
- **`.hda`** — write to a BlueSCSI / SCSI2SD / real SCSI disk, or attach
  in an emulator. APM + Apple_HFS, boots directly into the bench.
- **`.dsk`** — 800 K HFS floppy; write with Disk Copy / Greaseweazle /
  `dd`, or mount in an emulator.

Run it to **"ALL TESTS DONE"**, power off, pull `/Results.jsonl`, and diff:
```sh
../gen/cpu_diff_corpus.py ../results/cpu/mame_baseline_2026-06-12.json Results.jsonl
../gen/mmu_diff_corpus.py ../results/mmu/mame_baseline_2026-06-12.json Results.jsonl
# fpu: per row, vec 11 = an unimplemented op correctly trapped; vec 0 = executed
```

## Provenance / validation (2026-06-13)

Built by `preboot/supervisor_bench/build_<bench>_<hda|dsk>.sh` from the
captured corpora (`gen/{cpu,mmu,fpu}_tests.h`) with the Retro68
`m68k-apple-macos-gcc -m68040` toolchain. **Boot-tested in MAME
`macqd800`** with the real Quadra 800 ROM: all three boot on the 68040,
the payload runs, and the **built-in DAFB 1 bpp display paints**
(`ScrnBase=$F9001000`). The bench reads the row stride from the ROM's
`ScrnRow`/`ScrnBase` globals at runtime, so it adapts to the Quadra's
current resolution.

> **MAME caveat:** MAME's 68040 SCSI write-back doesn't persist
> `/Results.jsonl` (a known emulator limitation — the disk boots and the
> bench runs, but results read back empty *under MAME only*). On **real
> hardware** the raw-sector `_Write` path persists results, as it did for
> the predecessor Mac II / IIvi benches. The on-screen `run=/ok=/trap=`
> tally is your live confirmation either way.

## Notes

- **MMU bench:** the register-characterization + PFLUSH rows run; the
  live-translation and fault rows are emitted `skipped:"live-reloc-todo"`
  pending the private-identity-page-table relocation (port from
  `../preboot/supervisor_bench/mmu_bench_main.c.68030-reference`).
- **FPU bench:** assumes MC68040-lite + no FPSP — transcendentals are
  expected to trap (vector 11). If the core embeds a full 68882 FPU,
  those rows execute instead; that *is* the discriminator.
- Rebuild from source: `cd ../preboot/supervisor_bench && make {cpu,fpu,mmu}`
  then `./build_<bench>_<hda|dsk>.sh`. The raw images land in `dist/`
  (gitignored); these `.tgz` are the committed copies.

See [`../../QUADRA800_TESTBENCH.md`](../../QUADRA800_TESTBENCH.md) for the
full plan and [`../test-blockers.md`](../test-blockers.md) for status.
