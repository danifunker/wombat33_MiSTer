# A/UX Startup — what actually fails, and why the chip looked idle

Established 2026-09-01 by pulling the disk apart offline. **This supersedes the
central claim of `RESUME-aux-machine-id.md`** ("A/UX never issues a SCSI select,
therefore its autoconfiguration is picking the wrong machine"). That claim rests
on a misreading of the hardware trace. The truth is simpler and puts the bug
back where the earlier sessions had it — in the ROM's SCSI path — but on a
branch of it that a normal Mac OS boot never takes.

---

## 1. The one-paragraph version

`A/UX Startup` is a **Macintosh application**, and it does not drive the 53C96.
Every disk access it makes goes through `_SCSIDispatch` — the Mac ROM's SCSI
Manager — using the **original (pre-4.3) API**: `SCSIGet`, `SCSISelect`,
`SCSICmd`, `SCSIRead`/`SCSIWrite` with a TIB, `SCSIComplete`. So the commands
that reach our chip during an A/UX boot attempt are *the ROM's own commands*,
byte-for-byte the same vocabulary the ROM used while booting Mac OS minutes
earlier. The tracer records **first sightings only**, and its tables are cleared
only on core load — so by the time A/UX Startup runs, every value it can
produce has already been marked seen. The silence in the capture is the tracer
working exactly as designed. It is not evidence that A/UX touched nothing.

## 2. How this was established

The disk image is now readable offline. Four small tools in `scripts/` were
written for it and are the reproducible path to everything below:

| tool | what it does |
|---|---|
| `aux_ufs.py` | walks the `Apple_UNIX_SVR2` root slice (4.3BSD FFS) — `ls`, `find`, `cat`, `stat` |
| `aux_whichfile.py` | maps a raw image byte offset back to the file that owns it |
| `aux_coff.py` | m68k COFF reader: sections + the kernel's full symbol table |
| `aux_dis.py` | capstone disassembly of a COFF range, annotated with those symbols |
| `mac_hfs.py` | the `Apple_HFS` partition: catalog, both forks, and offset→file |
| `mac_rsrc.py` | resource fork: list/extract, e.g. the `CODE` segments |
| `mac_dis.py` | 68k disassembly that resyncs over A-line traps and names them |

Start by unpacking the pristine image locally (it is on the MiSTer as
`games/Wombat33/backup/HD60_512-AUX3.1-Installed.zip`, 61 MB, ~13 s to copy):

```sh
scp root@$MISTER_HOST:/media/fat/games/Wombat33/backup/HD60_512-AUX3.1-Installed.zip scratch/aux/
cd scratch/aux && unzip -o HD60_512-AUX3.1-Installed.zip     # md5 b44b762375d90879973baaf7f817c020
```

The partition map:

| slice | offset | contents |
|---|---|---|
| `Apple_partition_map` | `0x000000200` | |
| `Apple_Driver` | `0x000008000` | |
| `UNIX Root&Usr slice 0` | `0x00000C000` | the A/UX root filesystem, FFS `bsize 8192 / fsize 1024` |
| `Swap` | `0x07E200200` | |
| `MacOS` | `0x07FC00200` | **4 MB HFS, volume `MacPartition`** — the boot volume |

**Step 1 — find the program that prints the errors.** Scan the raw image for the
message strings and map the hits:

```sh
python3 scripts/mac_hfs.py IMG at 0x7fde3ad5 0x7fe601b2 0x7fe1002e
0x7fde3ad5 -> :A/UX Startup [rsrc fork] + 0x34d5      # "Autorecovery failed"
0x7fe601b2 -> :bin:fsck     [data fork] + 0x33b2      # "Can't determine file system type"
0x7fe1002e -> :A/UX Startup [rsrc fork] + 0x2fa2e     # "Protocol Error Processing SCSI request"
```

So the failure is inside the Mac application, not inside anything the kernel
runs. `MacPartition` also carries `:bin/*` — `fsck`, `ufs/fsck`, `newfs`,
`tunefs`, … — all typed `COFF/SASH`. `SASH` is the standalone shell: these are
the standalone programs A/UX Startup executes.

**Step 2 — read its code.** `A/UX Startup` has an empty data fork; all of it is
in 14 named `CODE` resources:

```
CODE 0        5048   (jump table)      CODE 7  Password    6688
CODE 1  Main  23622                    CODE 8  specfs      7512
CODE 2  VBLtask 800                    CODE 9  common     17498
CODE 3  Init   3486                    CODE 10 svfs       20588
CODE 4  Misc  20386                    CODE 11 ufs        26392
CODE 5  salib   6580                   CODE 12 %A5Init    14054   <- the strings live here
CODE 6  saio   19198   <- the I/O layer CODE 13 STDCLIB    1198
```

Scanning every executable on `MacPartition` for 53C96 register bases
(`$50F10000`, `$50F0F000`, `$50010000`, `$50F08000`, `$50F1A000`) finds **none**
in any code. Scanning for `_SCSIDispatch` ($A815) finds **13 in `CODE 6 saio`
and nowhere else** in the application.

## 3. The exact call sequence

`saio`'s request routine at `0x1218` in `CODE 6`, with `a4` = the request
(`$27(a4)` is `req->ret`, the same field and the same code table as the kernel's
`scsireq.c` — see [`aux-c94-driver.md`](aux-c94-driver.md) §7):

```
  if (req->callback == NULL)                       -> ret = 8
  SCSIGet()                                        -> fail: ret = 8
  SCSISelect(target)                               -> fail: ret = 5
  SCSICmd(req->cdb, req->cdblen)                   -> fail: ret = 8
  if (req->datalen > 0) {
      TIB = { scInc, req->dataptr, req->datalen }, { scStop }
      (req->flags & 1) ? SCSIRead(TIB) : SCSIWrite(TIB)
  }
  SCSIComplete(60 * req->timeout, &stat, &msg)     -> fail: SCSIComplete(0); ret = 8
  if (stat == 2)  -> REQUEST SENSE via SCSIGet/SCSISelect/...   fail: ret = 4
```

That is the **original** SCSI Manager API — selectors 1, 2, 3, 5/6, 4 — not
SCSI Manager 4.3's `SCSIAction`. Note also `SCSIRead`, not `SCSIRBlind`: the
non-blind, phase-checked form.

**The error code is the whole diagnosis available from the screen.** The log
says "Protocol Error Processing SCSI request" = `ret = 8`, and it never says
"Cannot select SCSI device" = `ret = 5`. So:

- **a selection timeout is ruled out.** If `SCSISelect` had been reached and
  failed, the message would have been the specific one.
- the failure is `SCSIGet`, `SCSICmd`, or `SCSIComplete`. (`SCSIGet` failing
  also means `SCSISelect` is never reached, which is equally consistent.)

## 4. Re-reading the hardware trace

`scratch/scsi_trace.decoded.txt`, read with the above in mind, is not silent at
all. Its last quarter is:

```
   ... second NuBus super-slot probe, $FF..$F1 in 16 MB steps ...   <- A/UX Startup's
   ... 2 heartbeat(s)                                                  Slot Manager calls
C 10  cmd write (first sighting)  TRANSFER INFO                    <- NON-DMA TI, first time all session
   ... 7 heartbeat(s)
t 83  STATUS read (first sighting)  phase=STATUS  INT
t 03  STATUS read (first sighting)  phase=STATUS
t 87  STATUS read (first sighting)  phase=MSG IN  INT
   ... 124 heartbeat(s)
```

Two things stand out:

1. **`$10` non-DMA TRANSFER INFO is sighted for the first time here**, after the
   whole Mac OS boot. The ROM's boot path uses `$C1` DMA-select and `$90` DMA
   TI throughout; the non-blind original-API path is the plausible reason a
   *non*-DMA TI appears at all. It arrives immediately after the second slot
   probe, which is A/UX Startup launching (`CODE 4 Misc` holds 6 `_SlotManager`
   traps and 5 `_PrimaryInit`).
2. **The STATUS values that follow have TC0 clear** (`$83`, `$03`, `$87` — bit 4
   = 0) where the ROM's own earlier ones have it set (`$93`, `$13`, `$97`).
   Same phases — STATUS then MSG IN — different transfer-counter state.

The 124 heartbeats afterwards are A/UX Startup retrying three times and printing;
every value it uses has been sighted, so nothing more is emitted. That is the
dedup, not the machine.

## 5. What this says about the machine-identity theory

It is not merely unproven — **it is downstream of a failure that happens first.**
A/UX Startup never gets as far as launching a kernel, so none of `boardinit`,
`machineID` or `c94info` runs. For the record, that code was read anyway and it
is fine:

- `machineID` is **not** probed from hardware. `_start` (`/unix` `pstart`
  `0x54000`) takes it from the boot block the booter hands over: with
  `d0 == $536D7201` and `a0` = the kernel-info block, `machineID = *(a0 + 0xB0)`.
- `boardinit` (`0x583DE`) switches on it through a table of 16-bit offsets at
  `0x5882A`, indexed by `machineID - 4`, range 4..`$39`; 35 of the 54 slots
  are `panic`.
- machineIDs `$1C $21 $22 $32 $33 $39` (cpuspeed 25/33/33/20/25/40) take the
  branch at `0x5868A`, which patches `c94info[2]` to
  **`{ base $50F10000, dreq $50F03A00, flag 1 }`** and sets `c94index[0] = 2`.
  `$50F03A00` is VIA2 + `$1A00` = register 13 = **IFR**, i.e. exactly the
  "Q800 reads DREQ from VIA2 IFR bit 0" arrangement in
  [`netbsd-ncr53c9x-expectations.md`](netbsd-ncr53c9x-expectations.md) §1.1.
  **This is the right path for Wombat33 and it is already correct.**
- machineIDs `$12 $14 $18` (Q900/Q950) take `0x58530`, leaving `c94info[2]` at
  its static `{ $50F0F000, $F9800024 }` — the DAFB DREQ. Not our machine.

`c94info` is 4 entries of 24 bytes at `0x5B60E`; `c94index` is 4 longs at
`0x5B66E` selecting among them. The five `$50F10000` hits at disk `0x8C9E4`… that
the earlier session read as "a machine-dependent device table" are in **`/core`,
a kernel crash dump** (`aux_whichfile.py` names it), and the `$F9800024` hits at
`0x7573A` are in **`/newunix`**. Neither is a table being consulted.

## 5b. What the ROM does with `$10`, and what a stall would look like

From `releases/quadra800.rom`. The ROM writes the command register with
`$01`×38, `$02`×6, `$03`×6, `$10`×**12**, `$11`×2, `$12`×5, `$90`×13,
`$C1`, `$C2`. So the non-DMA `$10` is a real, well-used path — twelve call
sites, all in `$40898xxx–$40899xxx`, while the DMA selects sit off in
`$408D1xxx`.

The first `$10` site, `$40898F14`, is the **MESSAGE IN fetch**:

```
40898F08   moveq #$7,d3 ; and.b $40(a3),d3 ; cmpi.b #$7,d3   ; phase == MSG IN?
40898F12   bne  -> d0 = 5                                    ; no: bail
40898F14   move.b #$10,$30(a3)      ; non-DMA TRANSFER INFO
40898F1A   bsr  $4089972A           ; wait for the interrupt
40898F1E   beq  -> d0 = 2           ; TIMED OUT
40898F20   move.b $20(a3),d2        ; the message byte, out of the FIFO
40898F24   move.b #$12,$30(a3)      ; MSG ACCEPT
40898F2A   bsr  $4089972A           ; wait again
40898F30   moveq #$0,d0             ; success
```

and the wait helper `$4089972A` is a **busy-poll on STATUS bit 7**:

```
    d3:d0 = TimeSCSIDB (lowmem $0B24) << 8        ; calibrated DBRA timeout
loop: move.b $40(a3),d5 ; btst #$7,d5 ; dbne d3,loop ; dbne d0,loop
    beq -> timeout
    move.b $70(a3),d5        ; FIFO flags
    move.b $50(a3),d5        ; INTR read LAST -- it clears
    btst #$7,d5 ; rts        ; Z tells the caller whether an INT arrived
timeout:
    move.b $70(a3),d5 ; clr.b d5     ; FIFO flags, INTR forced to 0
```

Two things follow. **A missing interrupt is invisible except as a long gap** —
the ROM spins for a calibrated wall-clock period and then reports a timeout, and
the old capture has exactly that: `C 10`, then a seven-heartbeat gap, then
STATUS reads. And **the ROM reads FIFO flags (`r7`) on every wait, taken or
timed out**, which is why the tracer now traces that channel: it gives the FIFO
count at each completion for free, with no new ports into `ncr53c96.sv`.

So the shape to look for in the next capture is a `$10` (or `$90`) with no
interrupt behind it, and a FIFO-flags value that says the byte never arrived.

## 6. What to do next

The failure is in the ROM's **original-API** SCSI path, which a Mac OS boot does
not exercise, so it can be broken while every existing gate test passes.

1. **Fix the tracer's blind spot first.** `seen_cmd` / `seen_stat` / `seen_intr`
   in `rtl/iosb.sv` are cleared only on `!nreset`, so one core load = one dedup
   epoch and the ROM's boot poisons the tables before A/UX runs. Re-arm them
   periodically (a free-running epoch counter clearing all `seen_*` every few
   seconds) so each epoch re-reports what is actually in use. Records stay
   bounded; the A/UX attempt becomes visible.
2. **Widen what is recorded on a command write** to include the transfer counter
   and FIFO count, since §4 makes TC0 the prime suspect.
3. Then re-capture with `scripts/scsi_trace.sh`, boot A/UX with ⌘B, and read off
   which of `SCSIGet` / `SCSICmd` / `SCSIComplete` stalls.
4. Once the sequence is known, pin it in `verilator/tb_ncr53c96.sv` as a third
   dialect alongside the ROM's DMA path and A/UX's `c94` path.

`aux-c94-driver.md` stays valid and stays needed — but it describes what the
A/UX **kernel** will do *after* A/UX Startup manages to load it, not what fails
today.

## 7. RESOLVED 2026-09-01 — QEMU as the golden reference, and the real fix

The right referee turned out to be **qemu-system-m68k master** (v11.1.0-779,
`../qemu`, built for `-M q800`): it boots **this exact `releases/quadra800.rom`
plus the A/UX 3.1 disk image** to multiuser — filesystem reads to 8 KB and
writes advance far past block 0. So the disk and ROM are good; the failure is
purely our RTL, and QEMU gives a complete, non-lossy register trace to diff
against (`--trace 'esp_*'`; drive it with `-audio none -display none
-drive ...,snapshot=on`).

Two things the QEMU trace settled that the epoch-deduped hardware capture had
led the previous cut astray on:

1. **A/UX Startup selects with the ROM's `$C1`, never `$42`.** In QEMU's
   A/UX-Startup window (between the ROM boot scan and the kernel's bus reset)
   the driver issues **580 `$C1` selects and zero `$42`**; the `$42` traffic is
   the A/UX *kernel*'s `c94` driver, which only runs after Startup has already
   loaded it. Our hardware traces agree: only `$C1`, never `$42`. So the failing
   program drives the disk through the ROM SCSI Manager (`_SCSIDispatch`), as §1
   said.

2. **The stall is a non-DMA `$10`, not a `$90`.** The ROM SCSI Manager reads
   bulk data as `$90` DMA chunks that it drains fully on DRQ *before* the
   interrupt — QEMU confirms our existing `$90` completion (`tc_zero &&
   fifo<2`) already matches, chunk for chunk (T10/T12). But it handles the
   **unaligned tail** of a transfer (INQUIRY 36 = 16+16+4, disklabels,
   partition entries) one byte at a time with non-DMA `$10` TI. QEMU flips the
   phase to STATUS on the byte that empties the request and leaves it in the
   FIFO; our `arm_pio_in` left the phase at DATA IN. `SCSIComplete` ends its
   `$10` loop by count and then polls STATUS for the phase to leave DATA IN —
   which never happened, so it spun `TimeSCSIDB` (~7 s) and returned `ret = 8`
   *Protocol Error*. The `C 10` + 7-heartbeat gap in the hardware capture was
   this, not a full FIFO.

**Fix:** `arm_pio_in` flips the phase to STATUS on the `$10` handshake that
pushes the request's last byte (`sbuf_pos == sbuf_len-1 && blocks_left == 0`),
byte still in the FIFO; mid-tail `$10`s keep phase DATA IN (QEMU
`reg[4]=0x91`). Plus the `synth_on` in-flight gate the tb's tight timing
exposed. Pinned by `verilator/tb_ncr53c96.sv` T11 (per-byte `$10`, flip on the
last), with T10/T12 transcribing QEMU's `$90` byte stream verbatim to prove the
bulk path was already right. Full details in
[`rtl-gap-analysis.md`](rtl-gap-analysis.md) item 18 — which also records the
reverted dead-end (a speculative "INT-before-drain" completion arm + a
`drain_tail` DREQ hold that produced the flashing-`?` regression, from
mis-reading the lossy trace).

## 8. Hardware result 2026-09-01, and the NEW open issue

Deployed the fixed build (`SCSI_TRACE` on, timing met +0.246 ns) with the disk
pristine. **The "Protocol Error Processing SCSI request" is GONE.** A/UX Startup
now runs its pre-boot `fsck` — the screen shows *"Welcome to The Apple Workgroup
Server 95 — Checking root file system…"* — and the trace shows transactions
completing (`$10 … C11 ICCS → MSG IN → C12 MSG ACCEPT → DISC`) with **one** bus
reset instead of the retry storm. The control-path bug is fixed on hardware.

**New blocker for a full boot:** A/UX Startup's `fsck` then reports **"BAD SUPER
BLOCK: MAGIC NUMBER WRONG"** on `/dev/dsk/c0d0s0`, so the root FS will not mount
and the kernel is never launched ("Open on 'newunix' failed"). This is a
**different, downstream issue** and the ncr53c96 is EXONERATED for it:

- The image is known-good: `qemu-system-m68k` master boots it to multiuser, and
  `scripts/aux_ufs.py ls /` reads the FFS root directory cleanly (valid primary
  superblock).
- The ncr53c96 read AND write paths are proven correct against QEMU's exact byte
  streams — `tb_ncr53c96.sv` T10-T14 (single- and multi-sector READ, and a
  multi-sector WRITE + read-back round-trip), 4488 checks, 0 failures. (T14 also
  flushed out a *testbench* latency bug: the inline disk model must sample
  `sd_buff_din` TWO cycles after driving `sd_buff_addr` — the tb's registered
  address plus sbuf's registered `q_s` read — or it reads every write-flush word
  one slot stale, which looked exactly like a 1-word write corruption.)

So the surviving suspects, in order: **(a)** the disk was corrupted by an
EARLIER broken build's writes and is now genuinely damaged — the on-MiSTer image
md5 has changed from pristine (`b44b7623…` → `837ffd6e…`) because A/UX
autorecovery wrote to it; test by restoring pristine and booting ONCE, checking
whether the FIRST `fsck` (before any writes) sees a valid superblock. **(b)** the
IOSB PDMA/DREQ glue (`iosb.sv`) — the ncr53c96 is unit-tested in isolation, so a
byte drop/dup or packing error in the CPU↔chip PDMA path would corrupt the
superblock while every ncr53c96 test passes; exercise it in the full Verilator
sim or on hardware. **(c)** A/UX's on-Wombat33 device/geometry mapping computing
the wrong superblock LBA.

## 9. RESOLVED 2026-09-02 — the disk really was bad: the chunked-write smear

Suspect (a) was right, with a mechanism nobody had on the list — and two of
§8's premises were wrong:

- **The superblock fsck judges is at slice+8 = LBA 104, not slice+16 = 112.**
  QEMU's `scsi_disk_*` trace of the boot shows the check sequence on the wire:
  `READ(6) 97,1` (label area) → `READ(6) 104,8` (4KB superblock) →
  `WRITE(6) 104,8` — sector 112 never appears. `fs_magic` = bytes 1372-1375
  of that image = sector 106, offset 348.
- **The on-disk superblock was NOT valid by the time it mattered.** The
  earlier forensics ran at an older md5 of the drifting disk. A full-disk
  changed-sector map (699 sectors; partition map and sector 97 untouched)
  plus a byte-exact reconstruction showed the final state has `fs_magic`
  zeroed — and QEMU **refuses to boot the reconstructed image**, aborting
  before any UFS-slice I/O. fsck's verdict was correct all along; the read
  path was never the problem.

The corruption signature identified the writer: sectors 104-107 each hold
exactly the next 256 bytes of the intended superblock image in their first
half and stale zeros in their second — `intended[k*256:(k+1)*256] + 256
zeros` for k = 0..3, magic in the void. That is the gap-analysis **item 19**
bug: A/UX Startup's saio issues one WRITE as many `$90` TIs of TC=256
(esp-master trace: the 2KB superblock write-back is 8 × TC=256), and the old
completion arm flushed a part-filled sector buffer at every chunk boundary,
burning one block per chunk and flipping to STATUS at half the data. Mac OS
writes a whole transfer in a single TI, which is why weeks of Mac-side booting
never tripped it. Fixed by deleting the partial flush (chunk end = interrupt
only; only `sbuf_pos == 512` flushes); tb T15 transcribes the 8 × TC=256
dialect and fails 1029 checks against the old arm.
