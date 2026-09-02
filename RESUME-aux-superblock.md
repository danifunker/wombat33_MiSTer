# Resume prompt — A/UX 3.1 BOOTS TO MULTIUSER on Wombat33; only the release build remains

Paste this as the opening message of a new session.

**Status 2026-09-02, VERIFIED ON HARDWARE: A/UX 3.1 boots to the multiuser
Finder desktop** (root `/` mounted; screenshots `scratch/boot_4..10.png`:
"Checking root file system" → "Initializing device drivers" → "Starting
background processes" → desktop). The "BAD SUPER BLOCK: MAGIC NUMBER WRONG"
mystery is SOLVED: fsck was telling the truth — the disk really was corrupted,
by our own SCSI **write path** (§1). Fix committed, sim-proven (tb T15), and
proven on hardware by the boot above, on a fresh pristine disk restore, with
the rebuilt debug bitstream (SCSI_TRACE on, seed 13, timing met +0.243 ns).

**All that remains is the RELEASE build** (§4 step 5): re-comment
`SCSI_TRACE` in `wombat33.qsf` and walk fitter seeds until timing is met.
The A/UX guest may still be RUNNING at the desktop — shut it down cleanly
(Finder: Special → Shut Down, or `scripts/guest/shutdown_finder.sh` is for
the Mac OS side) before any core load.

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
| Flashed on the MiSTer | The 2026-09-02 debug build of `output_files/wombat33.rbf` — **both fixes**, SCSI_TRACE on, seed 13, timing met +0.243 ns. This is the build that boots A/UX to multiuser. |
| Guest | **A/UX 3.1 running at the multiuser Finder desktop** (unless the user moved it). Shut down cleanly before any core load. |
| Disk on MiSTer | `games/Wombat33/HD60_512-AUX3.1-Installed.hda` — was restored to pristine (b44b7623) just before the verification boot; now carries that boot's legitimate writes. That is normal operation; restore from `backup/HD60_512-AUX3.1-Installed.zip` only if a fresh-disk experiment needs it. |
| Local copies | `scratch/aux/HD60_512-AUX3.1-Installed.hda` = pristine; `HD60-modified-reconstructed.hda` = the failed disk, byte-exact (md5 03f98fdf); `HD60-qemu-writes.hda` = pristine after a QEMU boot's writes (intended-bytes oracle). `scratch/overlay_modified.sh` rebuilds the reconstruction from a changed-sector list (`scratch/changed_sectors.txt`). |
| `wombat33.qsf` | `SCSI_TRACE=1` still ON (line ~125), seed 13 — matches the flashed debug build. The release build flips this off. |

## 4. Next moves

Steps 1-4 (build, deploy, restore, verification boot) are **DONE — A/UX
reached the multiuser desktop 2026-09-02**. What remains:

5. **The release build**: re-comment `SCSI_TRACE` in `wombat33.qsf`,
   find a seed that meets timing (seed 13 missed at −0.390 ns without the
   tracer; walk seeds via `scratch/seeds/restore_seed.sh`, history in the
   qsf comments). Don't hunt timing in your own diff — placement lottery.
   Deploy needs the guest shut down first (Finder Special → Shut Down) and
   the user's OK.
6. Optional polish: exercise A/UX under load (shell, installs) to shake out
   anything the boot path didn't touch; the debug tracer build is fine for
   that. If a new failure appears, diff against QEMU
   ([[qemu-golden-reference]]; `scsi_disk_*` and `esp_*` tracing both work).

## 5. Env crib (unchanged)

`scripts/local.env` has `MISTER_HOST`/`MISTER_SSH_KEY`. Git Bash + Windows
python: `export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
PYTHONIOENCODING=utf-8:replace`. Verilator + QEMU live in WSL
(`wsl -e bash -lc '…'`; the `Failed to mount I:\` on stderr is harmless).
`ssh` without `-n` eats a piped bash script. Keycodes for the guest:
KEY_LEFTALT=56 is Guest-Command, KEY_B=48, KEY_ENTER=28; Return activates the
default dialog button. Memory files: [[aux-scsi-status]],
[[qemu-golden-reference]], [[never-reset-mister-mid-boot]].
