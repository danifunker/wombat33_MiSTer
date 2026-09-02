# Resume prompt — A/UX 3.1 on Wombat33: BOTH SCSI bugs fixed; deploy + verify the write-path fix on hardware

Paste this as the opening message of a new session.

**Status 2026-09-02: the "BAD SUPER BLOCK: MAGIC NUMBER WRONG" mystery is
SOLVED and the fix is in the tree, sim-proven, committed.** fsck was telling
the truth: the disk really was corrupted — by our own SCSI **write path**. The
earlier version of this file sent the investigation after "why does a valid
superblock read as bad"; that premise was wrong (see §2 for how it fooled us).
What remains is hardware verification: build, **ask the user, then deploy**,
restore the pristine disk, boot A/UX, watch fsck pass.

**Binding rules (unchanged):** never load a core while a guest with a mounted
HFS volume is running, and **ask before any deploy**. The guest was left at an
A/UX Startup `startup#` shell prompt (safe idle).

---

## 1. The bug that was actually there (gap-analysis item 19)

Under A/UX Startup, the ROM SCSI Manager (saio/fsck/autorecovery) splits one
WRITE into many `$90` TRANSFER INFOs of **TC=256** — the QEMU master esp trace
of this exact ROM+disk shows fsck's 2KB superblock write-back at LBA 104 as
8 × TC=256, and its 8KB cylinder-group writes as 32 × TC=256. Mac OS writes a
whole transfer in a single TI (TC=512/4096/8192), which is why weeks of
Mac-side booting never tripped it.

`rtl/ncr53c96.sv`'s old data-out completion treated every TC expiry with a
part-filled sector buffer as a "trailing partial sector": it flushed 256 real
bytes + a stale (zero) upper half to the current LBA, advanced the LBA, and
burned one block of the CDB count per chunk. A 4-block write therefore hit
`blocks_left == 0` after 4 chunks and flipped to STATUS with half the data
unsent — which the ROM's phase-polling write loop accepted as success, GOOD
status and all. On disk, the superblock landed smeared at 256 bytes/sector:

- failed-disk sectors 104..107 == `intended[k*256:(k+1)*256] + 256 zeros`,
  k = 0..3, byte-exact (intended = pristine + fsck's field updates at offsets
  32/140/198/207, all in chunk 0);
- `fs_magic` (bytes 1372-1375 of the image = sector 106 offset 348) fell in
  the zero void → the next fsck read found no magic.

**The fix** (committed): a chunk completion (TC=0, FIFO drained) just raises
BS and leaves `sbuf_pos` accumulating across TIs; only `sbuf_pos == 512`
flushes, and the final block's flush flips the phase. A block write's
initiator sends exactly blocks × 512 bytes, so a genuine trailing partial
sector cannot exist. Note: the completion may raise BS the same cycle the
last flush *arms*; the platform drains it after STATUS, like a real target
completing from cache.

**Proof:** `verilator/tb_ncr53c96.sv` **T15** transcribes the 8 × TC=256
dialect and byte-checks the resulting disk — 1029 failures against the old
arm (DREQ dies at chunk 4, mirroring hardware), 0 after the fix. Full suite
T1-T15: **6556 checks, 0 failures**, lint clean. Write-ups:
[`docs/scsi/rtl-gap-analysis.md`](docs/scsi/rtl-gap-analysis.md) item 19,
[`docs/scsi/aux-startup-boot-path.md`](docs/scsi/aux-startup-boot-path.md) §9.

## 2. Corrections to the previous investigation (do not re-inherit these)

- **The superblock fsck judges is at slice+8 = LBA 104**, not slice+16 = 112.
  Wire sequence (QEMU `scsi_disk_*` trace): `READ(6) 97,1` → `READ(6) 104,8`
  → `WRITE(6) 104,8`. LBA 112 never appears.
- **"The on-disk superblock is valid" was stale forensics.** The disk md5
  kept drifting (b44b7623 → 837ffd6e → 03f98fdf); the check that exonerated
  the disk ran on an older state. At 03f98fdf the magic at 104+1372 is
  ZEROED. Re-verify forensics against the *current* md5, always.
- **The read path and the IOSB PDMA glue are exonerated**: a byte-exact local
  reconstruction of the failed disk (pristine + changed-sector overlay,
  md5-matched) **refuses to boot under QEMU too** — it aborts before any
  UFS-slice I/O. Same data, no Wombat33 hardware involved.
- The full changed-sector map of the failed disk (699 sectors) showed the
  partition map (0-5) and sector 97 untouched — no stray-LBA writes.

## 3. State of the machine, exactly as left

| | |
|---|---|
| Flashed on the MiSTer | `c823bebe` — has fix #1 (phase flip) but **NOT fix #2: its write path still destroys chunked writes**. Do not let A/UX write with it. |
| `output_files/wombat33.rbf` | Being rebuilt with both fixes at session end (SCSI_TRACE on, seed 13) — check `bash scripts/build_only.sh` output / `output_files/build_*.log` for the result and timing. |
| Guest | A/UX Startup at `startup#` (idle) unless the user moved it. |
| Disk on MiSTer | `games/Wombat33/HD60_512-AUX3.1-Installed.hda`, **corrupted** (md5 03f98fdf). MUST restore pristine before the verification boot: `ssh root@$MISTER_HOST 'cd /media/fat/games/Wombat33 && unzip -o backup/HD60_512-AUX3.1-Installed.zip'` → b44b7623 (~6 min; guest idle first). |
| Local copies | `scratch/aux/HD60_512-AUX3.1-Installed.hda` = pristine; `HD60-modified-reconstructed.hda` = the failed disk, byte-exact; `HD60-qemu-writes.hda` = pristine after a QEMU boot's writes (intended-bytes oracle). `scratch/overlay_modified.sh` rebuilds the reconstruction from a changed-sector list. |
| `wombat33.qsf` | `SCSI_TRACE=1` still ON (line ~125), seed 13 — debug build config, fine for the verification boot. |

## 4. Next moves, in order

1. **Check the build** finished and met timing (`build_only.sh` refuses to
   pass off a timing-fail; seed 13 met +0.246 ns with the tracer last time).
2. **Ask the user, then deploy** (`bash scripts/scsi_trace.sh [secs]` does
   deploy+capture, or `scripts/deploy_screenshot.sh` alone). Guest must be
   idle; deploy yanks the volume.
3. **Restore pristine disk** (§3 command), verify md5 b44b7623.
4. **Boot A/UX** (⌘B in A/UX Startup: `python scripts/mister_ws.py --host
   $MISTER_HOST --delay 0.15 down:56 raw:48 up:56`), watch via
   `bash scripts/grab.sh scratch/state.png`. Expect: fsck pass 1 "dirty" →
   autorecovery → fsck pass 2 **clean read** → kernel launch toward
   multiuser. Any new failure: capture screen + SCSI trace, diff against
   QEMU (`~/qemu-src/build/qemu-system-m68k` in WSL, see §5 of the old doc /
   [[qemu-golden-reference]]; `scsi_disk_*` and `esp_*` tracing both work).
5. **Then the release build**: re-comment `SCSI_TRACE` in `wombat33.qsf`,
   find a seed that meets timing (seed 13 missed at −0.390 ns without the
   tracer; walk seeds via `scratch/seeds/restore_seed.sh`, history in the
   qsf comments). Don't hunt timing in your own diff — placement lottery.

## 5. Env crib (unchanged)

`scripts/local.env` has `MISTER_HOST`/`MISTER_SSH_KEY`. Git Bash + Windows
python: `export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
PYTHONIOENCODING=utf-8:replace`. Verilator + QEMU live in WSL
(`wsl -e bash -lc '…'`; the `Failed to mount I:\` on stderr is harmless).
`ssh` without `-n` eats a piped bash script. Keycodes for the guest:
KEY_LEFTALT=56 is Guest-Command, KEY_B=48, KEY_ENTER=28; Return activates the
default dialog button. Memory files: [[aux-scsi-status]],
[[qemu-golden-reference]], [[never-reset-mister-mid-boot]].
