# Resume prompt — A/UX 3.1 on Wombat33: the SCSI Manager bug is FIXED; now `fsck` reads a valid superblock as bad

Paste this as the opening message of a new session.

**This supersedes `RESUME-aux-scsi-manager.md`.** That file's core thesis was
half right: the failing path *is* the ROM SCSI Manager's non-DMA `$10` transfer,
but the mechanism was NOT the "INT-before-drain deadlock" it described — that was
a mis-read of the lossy epoch-deduped tracer. The real bug was a missing phase
flip on the `$10` last byte, and **it is now fixed and proven on hardware.**
Keep the old resume docs only for history.

Repo on `main`, working tree uncommitted (nothing committed for several
sessions — same as before). Goal unchanged: **get A/UX 3.1 to boot on Wombat33.**

**Binding rule (unchanged):** never load a core while a guest with a mounted
HFS volume is running — it yanks the volume. And **ask before any deploy**
(user preference). The current guest is A/UX Startup at a `startup#` shell
prompt, which is a safe idle state.

---

## 0. State of the machine and the tree, exactly as left

| | |
|---|---|
| Flashed on the MiSTer | **`c823bebe7a3d6e296bc9b531c62d9ebe`** — the SCSI-fixed **DEBUG** build (`SCSI_TRACE` on), timing met +0.246 ns, seed 13. This is the build that boots A/UX to `fsck`. Preserved at `scratch/wombat33_scsi_fixed_c823bebe.rbf`. |
| `output_files/wombat33.rbf` | **STALE** — `dbe3c8b1…`, the timing-FAILED release build (`SCSI_TRACE` off, −0.390 ns). Do NOT flash it; `deploy_screenshot.sh` refuses it anyway. Rebuild the good one with `SCSI_TRACE` on + seed 13, or re-copy `scratch/wombat33_scsi_fixed_c823bebe.rbf`. |
| Guest | A/UX Startup at a `startup#` prompt (idle). |
| Disk on the MiSTer | `games/Wombat33/HD60_512-AUX3.1-Installed.hda`, **modified by A/UX autorecovery** (md5 drifted `b44b7623` → `837ffd6e` → `03f98fdf`). Pristine backup: `games/Wombat33/backup/HD60_512-AUX3.1-Installed.zip` (61 MB, ~13 s copy + ~8 s unzip), restores to `b44b762375d90879973baaf7f817c020`. |
| Local pristine copy | `scratch/aux/HD60_512-AUX3.1-Installed.hda` (gitignored, 2 GB, md5 `b44b7623`) — used for QEMU and offline forensics. |
| Mount | slot 0 → the A/UX image (`/media/fat/config/Wombat33.s0`). |
| `wombat33.qsf` line 125 | **`SCSI_TRACE=1` is UNCOMMENTED** (matches the flashed build). Re-comment for a release build. |

**The immediate next action is a diagnostic, not a fix** — see §4. The chip is
fixed; the open question is why A/UX's `fsck` rejects a superblock that is
demonstrably valid on disk.

---

## 1. The headline

**The control-path SCSI bug is FIXED and proven on hardware.** A/UX 3.1 now
boots through the Mac ROM's SCSI Manager, loads and runs `fsck`, and reaches
*"Welcome to The Apple Workgroup Server 95 — Checking root file system…"*. The
old *"Protocol Error Processing SCSI request"* is gone.

**It does not reach multiuser yet.** `fsck` then reports **"BAD SUPER BLOCK:
MAGIC NUMBER WRONG"** on `/dev/dsk/c0d0s0`, so the root FS never mounts and the
kernel is never launched (*"Open on 'newunix' failed"*). This is a **separate,
downstream issue** and it is the subject of the continued investigation.

---

## 2. The fix that is now in the tree (proven — do not touch)

**`rtl/ncr53c96.sv`: non-DMA `$10` TRANSFER INFO flips phase to STATUS on the
target's last byte.** A/UX Startup's `saio` drives the disk through the ROM's
`_SCSIDispatch` using the ROM's `$C1` DMA-select dialect (confirmed both ways:
hardware traces and QEMU's Startup window show only `$C1`, zero `$42`; the
`$42` is the A/UX *kernel* c94 driver after handoff). Bulk reads are `$90` DMA
chunks (already correct), but unaligned tails go one byte at a time via non-DMA
`$10`. On the byte that empties the request, real silicon and QEMU
(`esp_command_complete`) flip the phase to STATUS and leave the byte in the FIFO;
our `arm_pio_in` left it at DATA IN, so `SCSIComplete` spun `TimeSCSIDB` ~7 s and
returned the catch-all `ret = 8`. The fix: on the `$10` handshake that pushes the
last byte (`sbuf_pos == sbuf_len-1 && blocks_left == 0`), set phase STATUS as BS
is raised. Plus a `synth_on` in-flight gate the tb's tight timing exposed.

Full derivation: [`docs/scsi/aux-startup-boot-path.md`](docs/scsi/aux-startup-boot-path.md)
§7-8 and [`docs/scsi/rtl-gap-analysis.md`](docs/scsi/rtl-gap-analysis.md) item 18.
A reverted dead-end (a speculative `fifo_cnt>=2` "INT-before-drain" completion
arm + a `drain_tail` DREQ hold) produced the flashing-`?` regression; item 18
records it so it is not retried.

**Test suite:** `verilator/tb_ncr53c96.sv`, **15 tests T1-T14, 4488 checks, 0
failures**, lint clean. T10 (ROM 16-byte `$90` chunks), T11 (per-byte `$10`,
flip on last), T12 (saio's 256-byte chunks), T13 (multi-sector READ), T14
(multi-sector WRITE + read-back) all transcribe QEMU's exact byte streams. T14
also flushed out a *testbench* bug: the inline disk model must sample
`sd_buff_din` **two** cycles after driving `sd_buff_addr` (the tb's registered
address + sbuf's registered `q_s` read), or every write-flush word reads one
slot stale — which looked exactly like a 1-word write corruption but was not.

---

## 3. The open issue, characterised — and what is RULED OUT

`fsck` reports a bad superblock, but **the on-disk superblock is valid**:

- **Sectors 104 (slice+8) and 112 (slice+16) are byte-identical to pristine**,
  with correct FFS fields (`fs_bsize=0x2000`, `fs_fsize=0x400`, `fs_frag=8`).
  Verified by `dd`-ing the region off the modified disk and diffing pristine.
- **A/UX's writes landed correctly.** Autorecovery touched sectors 104-107,
  128-131, 144-155; the only change to the superblock copy at 104 was the
  `fs_time` timestamp (`6a97 2ffd` vs pristine `87e8 1514`), every other field
  byte-identical and correctly ordered — **not byte-swapped, not garbage.**
- The image is known-good: `qemu-system-m68k` master boots it to multiuser, and
  `scripts/aux_ufs.py ls /` reads the FFS root directory cleanly.
- The **first** `fsck` (on pristine, before any writes) read the superblock fine
  and reported the FS merely *dirty* ("needs to be checked"). The bad-magic
  verdict appears on the **second** pass, after autorecovery wrote.

Ruled out this session:

- **A/UX's own c94 driver / machine identity** — never runs; A/UX Startup uses
  the ROM `$C1` path (RESUME-aux-scsi-manager.md §2-3, still valid).
- **The `$10` deadlock framing** — wrong mechanism; the real bug was the phase
  flip (§2).
- **A timing / seed effect** — the deployed build *meets* timing (+0.246 ns) and
  still shows the bad superblock. Removing the tracer for a release build only
  reshuffles placement (it missed timing at −0.390 ns, seed lottery).
- **The tracer perturbing anything** — the `SCSI_TRACE` block in `iosb.sv` is
  purely observational: it taps SCSI accesses and steals the modem-port pin, and
  drives NO functional signal (`sdma_valid`, `sdma_wr`, `ack`, the shift/count
  regs). The two builds have identical SCSI logic.
- **ncr53c96 read/write correctness** — single- and multi-sector READ and a
  multi-sector WRITE round-trip are proven against QEMU's byte streams (T10-T14).
- **The hardware write byte-swap / HPS packing** — A/UX's real superblock-copy
  write landed correctly on disk (§3 bullet 2).

**So the surviving hypothesis:** A/UX reads a *valid* on-disk superblock as
bad-magic on the second pass — i.e. it reads the **wrong location** (a disklabel
/ geometry computation that autorecovery's writes changed), or a specific read
returns wrong data in a way the isolated ncr53c96 tests and Mac OS's read-only
boot don't exercise. Everything verifiable in isolation is correct.

---

## 4. Next moves, in order

1. **Capture the SCSI trace DURING the failing `fsck`.** The tracer build is
   already flashed. Restore pristine, reboot, let A/UX Startup autorecover, and
   capture — then read off exactly which LBAs `fsck` reads for the superblock and
   whether those reads complete. This is the missing data point: does A/UX read
   sector 112 (valid) or somewhere else?
   ```sh
   ssh root@$MISTER_HOST 'cd /media/fat/games/Wombat33 && unzip -o backup/HD60_512-AUX3.1-Installed.zip'   # ~6 min, restore pristine
   bash scripts/scsi_trace.sh --capture-only 300     # the tracer build is already deployed
   ```
   Boot A/UX with ⌘B if it does not autolaunch (§6).
2. **Diff that against QEMU.** Boot the same image under `qemu-system-m68k`
   master with `--trace 'esp_*'` (§5) and find the superblock-read transaction in
   the A/UX-Startup window. Compare the LBAs and the returned data. QEMU boots
   this image, so its read is the oracle.
3. **If A/UX reads the wrong LBA:** trace back to the disklabel / geometry.
   A/UX issues INQUIRY, TEST UNIT READY, READ CAPACITY(10), and **MODE SELECT(6)
   = 0x15** (which `rtl/ncr53c96.sv` does NOT implement — it CHECK-CONDITIONs;
   A/UX's are all zero-length so it does not hang, but it diverges from QEMU's
   scsi-hd which returns GOOD). Compare our READ CAPACITY / geometry responses
   against scsi-hd's; a wrong geometry would move where A/UX computes the
   superblock.
4. **If a specific read returns wrong data:** the suspect is the IOSB PDMA glue
   (`iosb.sv`), which the isolated ncr53c96 tb cannot exercise. Build the full
   Verilator sim with `sim_blkdevice.cpp` and replay the failing read, or add
   hardware read-byte instrumentation.

Cheap fallback if that stalls: try `fsck -b 32 /dev/dsk/c0d0s0` (the alternate
superblock) from the `startup#` prompt — A/UX itself suggested "-b". If the
alternate boots it, the primary-read path is the culprit.

**Finalisation (independent of the bug):** a shippable build needs `SCSI_TRACE`
re-commented in `wombat33.qsf` line 125 AND a fitter seed that meets timing.
Seed 13 misses without the tracer (−0.390 ns); walk seeds
(`scratch/seeds/restore_seed.sh`, and the seed history in `wombat33.qsf` lines
59-97). Don't hunt timing in your own diff — it's the placement lottery.

---

## 5. QEMU is the golden reference — it boots this exact ROM+disk

`qemu-system-m68k` master (`../qemu`, v11.1.0-779) boots **our exact
`releases/quadra800.rom` + the A/UX disk image** to multiuser. It is the
authoritative, non-lossy reference for the 53C96/ESP behaviour, unlike the
epoch-deduped hardware tracer. Built once in WSL (no pixman/audio needed):
```sh
git clone --depth 1 file:///mnt/c/Temp/mistercore/qemu ~/qemu-src
cd ~/qemu-src && ./configure --target-list=m68k-softmmu --disable-pixman --disable-docs --disable-werror
ninja -C build qemu-system-m68k
```
Run headless with full ESP trace (image untouched via snapshot):
```sh
~/qemu-src/build/qemu-system-m68k -M q800 -audio none -display none \
  -bios /mnt/c/Temp/mistercore/wombat33_MiSTer/releases/quadra800.rom \
  -drive if=none,id=hd,format=raw,file=/mnt/c/Temp/mistercore/wombat33_MiSTer/scratch/aux/HD60_512-AUX3.1-Installed.hda,snapshot=on \
  -device scsi-hd,scsi-id=0,drive=hd --trace 'esp_*' > ~/esp-master.log 2>&1
```
`-audio none` is mandatory (WSL has no sound device; qemu aborts otherwise).
`--trace 'scsi_req_parsed'` instead gives the SCSI opcode alphabet (A/UX issues
READ(6)/(10), WRITE(6)/(10), INQUIRY, TUR, READ CAPACITY, REQUEST SENSE, and
MODE SELECT(6)). Established with this: A/UX Startup uses `$C1` (580×, zero
`$42`); the ROM reads a 512-byte block as 16-byte `$90` chunks, draining each
fully before the interrupt; the `$10` tail flips phase on the last byte.

---

## 6. Working with the guest

**Boot A/UX on demand:** A/UX Startup's **Execute** menu — `Boot ⌘B`,
`AutoRecovery`, `AutoLaunch ⌘L`, `Kill ⌘K`, `Restart`, `Shut Down`. Keys are raw
Linux keycodes via `mister_ws.py` (KEY_LEFTALT=56=Guest-Command, KEY_B=48,
KEY_Q=16, KEY_ENTER=28). Typing works at the `startup#` shell too:
```sh
python scripts/mister_ws.py --host $MISTER_HOST --delay 0.15 down:56 raw:48 up:56   # Cmd-B (boot)
# type a shell command: fsck -y /dev/dsk/c0d0s0  (verified this session)
python scripts/mister_ws.py --host $MISTER_HOST --delay 0.12 raw:33 raw:31 raw:46 raw:37 raw:57 ... raw:28
bash scripts/grab.sh scratch/state.png            # screenshot
```
The default dialog button (heavy border, e.g. "Restart") is activated by Return.
`scripts/guest/shutdown_finder.sh` does the Mac OS Finder shutdown reliably (tune
its probes offline against saved screenshots, not on hardware).

**Restore pristine between attempts** (A/UX writes during autorecovery):
```sh
ssh root@$MISTER_HOST 'cd /media/fat/games/Wombat33 && unzip -o backup/HD60_512-AUX3.1-Installed.zip'   # ~6 min, guest idle
```

---

## 7. Offline forensics — the disk is fully readable on the host

The pristine image is local at `scratch/aux/HD60_512-AUX3.1-Installed.hda`. Tools
(see RESUME-aux-scsi-manager.md §6 for the full table and env gotchas):
`aux_ufs.py` (FFS root slice), `aux_whichfile.py` (offset→file), `aux_coff.py` /
`aux_dis.py` (kernel COFF + m68k disasm), `mac_hfs.py` / `mac_rsrc.py` /
`mac_dis.py` (the HFS MacPartition, resource forks, 68k disasm).

**To compare the modified disk against pristine** (how the superblock forensics
was done):
```sh
ssh root@$MISTER_HOST 'dd if=/media/fat/games/Wombat33/HD60_512-AUX3.1-Installed.hda bs=512 skip=96 count=64 2>/dev/null' > scratch/mod_region.bin
dd if=scratch/aux/HD60_512-AUX3.1-Installed.hda bs=512 skip=96 count=64 2>/dev/null > scratch/pri_region.bin
cmp -l scratch/mod_region.bin scratch/pri_region.bin   # which sectors A/UX changed
```
Disk layout: Apple partition map; `UNIX Root&Usr slice 0` (Apple_UNIX_SVR2) at
disk offset `0xC000` = **sector 96**; FFS superblock at slice+16 = **sector 112**
(and a copy at slice+8 = sector 104). Swap at `0x7E200200`; 4 MB HFS MacPartition
(the Mac OS boot volume) at `0x7FC00200`.

Env gotchas (Git Bash + Windows python): `export MSYS_NO_PATHCONV=1
MSYS2_ARG_CONV_EXCL='*' PYTHONIOENCODING=utf-8:replace`; give python `C:/…`
paths; `mac_hfs.py` uses `:` as the HFS path separator; Verilator/qemu live in
WSL (`wsl -e bash -lc '…'`, harmless `Failed to mount I:\` on stderr); `ssh`
without `-n` eats a piped bash script.

---

## 8. Build / deploy / capture

```sh
bash scripts/build_only.sh            # local Quartus compile -> .rbf + status
bash scripts/build_only.sh --check    # fast Analysis & Synthesis only
bash scripts/scsi_trace.sh [secs]     # deploy + capture + decode (tracer build)
bash scripts/scsi_trace.sh --capture-only [secs]   # capture only, build already deployed
```
`build_only.sh` prints a `*** DEBUG BUILD -- SCSI_TRACE on ***` banner and
refuses to let a timing-failed build be mistaken for a good one. It waits for any
in-progress Quartus — if a build dies (exit 127 seen twice this session from a
killed/contended fitter), kill stray `quartus_*.exe` (`taskkill //F //IM
quartus_fit.exe …`) before restarting, and verify `count = 0` first.

Memory files worth reading: `[[aux-scsi-status]]`, `[[qemu-golden-reference]]`,
`[[never-reset-mister-mid-boot]]`.

go find where that superblock read really goes.
