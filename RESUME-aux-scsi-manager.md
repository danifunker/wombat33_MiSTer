# Resume prompt — A/UX 3.1 on Wombat33: it is the ROM's SCSI Manager, not A/UX

> **SUPERSEDED 2026-09-02 by [`RESUME-aux-superblock.md`](RESUME-aux-superblock.md).**
> The identification of the ROM SCSI Manager `$C1`/`$10` path here is correct and
> still useful, but the "final-DMA-chunk INT-before-drain deadlock" mechanism in
> this file is WRONG — it was a mis-read of the lossy epoch-deduped tracer. The
> real bug was a missing phase flip on the non-DMA `$10` last byte, and it is now
> FIXED and proven on hardware. Read the new file first.

Paste this as the opening message of a new session.

**This supersedes `RESUME-aux-machine-id.md`**, whose §1 and §3 are wrong (that
file now carries a banner saying so), which in turn superseded
`RESUME-aux-scsi.md`. Keep both only for the history of what was tried.

Repo on `main`, working tree uncommitted (nothing has been committed for two
sessions). Goal unchanged: **get A/UX 3.1 to boot on Wombat33.**

**Binding rule:** never load a core while the guest is running — it yanks the
mounted HFS volume. `bash scripts/guest/shutdown_finder.sh` does the Mac OS
shutdown reliably; verify the "It is now safe to switch off your Macintosh"
screen before flashing.

---

## 0. State of the machine and the tree, exactly as left

| | |
|---|---|
| Guest | **shut down**, verified by screenshot at 15:22 ("safe to switch off") |
| Core running on the MiSTer | the **OLD** debug bitstream, md5 `eb427f3fb5fe64b7b7dbbba2482caefe`. **The new build was never deployed.** |
| `output_files/wombat33.rbf` | **NEW, built 2026-09-01 15:44**, md5 `080732b77550e567f521f005fc8963a8`, 4,318,968 bytes. **DEBUG build — `SCSI_TRACE` is on, it hijacks the guest serial port.** Not on the MiSTer. |
| New build's numbers | Fitter OK, **89 % ALMs** (37,143 / 41,910 — up from 82 %; the tracer is expensive), 424/553 RAM blocks, **timing met, worst slack +0.248 ns**, seed 13, 24m18s |
| `wombat33.qsf` line 125 | **`SCSI_TRACE=1` is UNCOMMENTED.** Re-comment it before building anything you intend to keep. |
| A/UX disk on the MiSTer | `/media/fat/games/Wombat33/HD60_512-AUX3.1-Installed.hda`, **restored pristine**, md5 `b44b762375d90879973baaf7f817c020` (the restore takes ~6 min over ssh) |
| Mount | slot 0 → the A/UX image (`/media/fat/config/Wombat33.s0`) |
| Mac OS control disk | `games/Wombat33/QuadSquad8.hda` — not re-verified on hardware since the RTL changes of the previous session |
| Local copy of the disk | `scratch/aux/HD60_512-AUX3.1-Installed.hda` (gitignored), same pristine md5, plus `scratch/aux/x/` with extracted kernels and CODE resources |

**The immediate next action is: deploy the new build and capture a trace.**
Everything is staged for it. `bash scripts/scsi_trace.sh 300` does deploy +
capture + decode in one go; the guest is already shut down and the disk is
already pristine, so it can be run as-is.

---

## 1. The headline, and the correction that produced it

**`A/UX Startup` is a Macintosh application and it never touches the 53C96.**
Every disk access it makes goes through `_SCSIDispatch` — the Mac ROM's SCSI
Manager — using the **original (pre-4.3) API**.

The previous session concluded the opposite ("A/UX never issues a SCSI select at
all, therefore this is not a SCSI bug, therefore its autoconfiguration is
picking the wrong machine") from a hardware trace that showed no A/UX-dialect
commands. That inference does not hold: A/UX Startup *cannot* issue a select,
because the ROM does it on its behalf, in the ROM's own dialect — and the
tracer deduped first sightings **per core load**, so every value A/UX Startup
could produce had already been marked seen during the Mac OS boot. The silence
was the tracer, not the machine.

Full derivation, with the commands to redo every step:
**[`docs/scsi/aux-startup-boot-path.md`](docs/scsi/aux-startup-boot-path.md)**.
Read it before trusting any A/UX trace.

---

## 2. What is now established (proven, not inferred)

### 2.1 The failing program is `A/UX Startup`, on the Mac partition

The disk is an Apple partition map:

| slice | offset | contents |
|---|---|---|
| `Apple_partition_map` | `0x000000200` | |
| `Apple_Driver` | `0x000008000` | |
| `UNIX Root&Usr slice 0` | `0x00000C000` | A/UX root, **4.3BSD FFS**, `bsize 8192 / fsize 1024 / frag 8 / ncg 505 / ipg 1920` |
| `Swap` | `0x07E200200` | |
| `MacOS` | `0x07FC00200` | **4 MB HFS, volume `MacPartition`** — the boot volume |

Raw string hits, mapped back to files:

```
0x7fde3ad5 -> :A/UX Startup [rsrc fork] + 0x34d5      "Autorecovery failed"
0x7fe601b2 -> :bin:fsck     [data fork] + 0x33b2      "Can't determine file system type"
0x7fe1002e -> :A/UX Startup [rsrc fork] + 0x2fa2e     "Protocol Error Processing SCSI request"
```

`MacPartition` also holds `:bin/*` — `fsck`, `ufs/fsck`, `svfs/fsck`, `newfs`,
`tunefs`, `mkfs`, `fsdb`, `kconfig` — all typed **`COFF/SASH`**. `SASH` is the
standalone shell; those are the programs A/UX Startup runs.

### 2.2 Its code, and the only SCSI path in it

`A/UX Startup` (type `APPL/SASH`) has an **empty data fork**; all of it is in 14
named `CODE` resources:

```
CODE 0        5048   (jump table)     CODE 7  Password    6688
CODE 1  Main  23622  (has _Gestalt)   CODE 8  specfs      7512
CODE 2  VBLtask 800                   CODE 9  common     17498
CODE 3  Init   3486                   CODE 10 svfs       20588
CODE 4  Misc  20386  (6x _SlotManager, 5x _PrimaryInit)
CODE 5  salib   6580                  CODE 11 ufs        26392
CODE 6  saio   19198  <-- ALL SCSI     CODE 12 %A5Init   14054  <- strings live here
CODE 13 STDCLIB 1198
```

- Scanning **every executable on `MacPartition`** for 53C96 register bases
  (`$50F10000`, `$50F0F000`, `$50010000`, `$50F08000`, `$50F1A000`) finds
  **none in any code**.
- `_SCSIDispatch` ($A815) appears **13 times, all in `CODE 6 saio`**, nowhere
  else in the application.

### 2.3 The exact call sequence

`saio`'s request routine at **`CODE 6` offset `0x1218`**. `a4` = the request;
`$27(a4)` is `req->ret`, the same field and the same code table as the kernel's
`scsireq.c`:

```
  if (req->callback == NULL)                       -> ret = 8, return
  SCSIGet()                                        -> fail: ret = 8   [0x1274]
  SCSISelect(target)                               -> fail: ret = 5   [0x129c]
  SCSICmd(req->cdb, req->cdblen)                   -> fail: ret = 8   [0x12cc]
  if (req->datalen > 0) {
      TIB = { scInc, req->dataptr, req->datalen }, { scStop }
      (req->flags & 1) ? SCSIRead(TIB) : SCSIWrite(TIB)   [0x131a / 0x132c]
  }
  SCSIComplete(60 * req->timeout, &stat, &msg)     [0x134a]
                     -> fail: SCSIComplete(0) [0x1366]; ret = 8
  if (stat == 2) -> REQUEST SENSE: SCSIGet [0x13c2] / SCSISelect [0x13ea] / ...
                     -> fail: ret = 4
```

Selectors 1, 2, 3, 5/6, 4 — the **original** API, not SCSI Manager 4.3's
`SCSIAction`. And `SCSIRead` (5), not `SCSIRBlind` (8): the non-blind,
phase-checked form.

### 2.4 What the error code rules out

`ret` codes (from `scsireq.c`'s table, `.data` VMA `0x1100C826`, 15 pointers
ending in `$FFFFFFFF`, strings from `0x1100C87A`):

| ret | message |
|---|---|
| 4 | Error during SCSI sense command |
| **5** | **Cannot select SCSI device** |
| **8** | **Protocol Error Processing SCSI request** — the DEFAULT |

The screen shows **`ret = 8` only, never `ret = 5`**. Therefore:

- **A selection timeout is ruled out.** Had `SCSISelect` been reached and
  failed, the message would have been the specific one.
- The failure is **`SCSIGet`, `SCSICmd`, or `SCSIComplete`**. (`SCSIGet` failing
  also means `SCSISelect` is never reached, so it is equally consistent.)

### 2.5 The old trace, re-read

`scratch/scsi_trace.decoded.txt`, last quarter:

```
   ... second NuBus super-slot probe, $FF..$F1 in 16 MB steps ...  <- A/UX Startup's
   ... 2 heartbeat(s)                                                 Slot Manager calls
C 10  cmd write (first sighting)  TRANSFER INFO                   <- NON-DMA TI, first time all session
   ... 7 heartbeat(s)                                             <- ~7 s of nothing
t 83  STATUS read (first sighting)  phase=STATUS  INT
t 03  STATUS read (first sighting)  phase=STATUS
t 87  STATUS read (first sighting)  phase=MSG IN  INT
   ... 124 heartbeat(s)                                           <- retries, all deduped away
```

- `$10` **non-DMA** TRANSFER INFO is sighted for the first time *here*, after
  the whole Mac OS boot. The ROM's boot path is `$C1` DMA-select + `$90` DMA TI.
- The STATUS values that follow have **TC0 clear** (`$83 $03 $87`, bit 4 = 0)
  where the ROM's own earlier ones have it set (`$93 $13 $97`). Same phases,
  different transfer-counter state.
- The 7-heartbeat gap is the signature of a **timeout**, see §2.6.

### 2.6 What the ROM does with `$10`, from `releases/quadra800.rom`

Command-register immediates the ROM ever writes (`move.b #imm,$30(An)`):

```
$01 x38  $02 x6  $03 x6  $06 x1  $07 x2  $08 x1  $10 x12  $11 x2
$12 x5   $1B x1  $22 x1  $80 x1  $90 x13  $C1 x1  $C2 x1  $FE x1
```

Non-DMA TI (`$10`) sites: `$40898F14 $4089921E $40899240 $40899270 $4089934E
$408998C6 $408D1B00 $408D1E58 $408D1E8A $408D1FE8 $408D237A $408D25A8`
DMA TI (`$90`) sites: `$408992CC $40899408 $4089950E $40899610 $408997A4
$4089986A $408D1A10 $408D1F74 $408D20AA $408D21B8 $408D22DE $408D24AE $408D254E`

The two regions are **one manager**, not two drivers: `$408D1xxx` calls
`bsr.l $40899704` into the `$40898xxx` helpers.

**`$40898F14` — the MESSAGE IN fetch:**

```
40898F08   moveq #$7,d3 ; and.b $40(a3),d3 ; cmpi.b #$7,d3   ; phase == MSG IN?
40898F12   bne  -> d0 = 5
40898F14   move.b #$10,$30(a3)      ; non-DMA TRANSFER INFO
40898F1A   bsr  $4089972A           ; wait, WITH timeout
40898F1E   beq  -> d0 = 2           ; TIMED OUT
40898F20   move.b $20(a3),d2        ; message byte out of the FIFO
40898F24   move.b #$12,$30(a3)      ; MSG ACCEPT
40898F2A   bsr  $4089972A
40898F30   moveq #$0,d0             ; success
```

**`$4089921E` — the single-byte polled data-in:**

```
4089921E   move.b #$10,$30(a3)
40899224   jsr  $40899704(pc)       ; wait, NO timeout -- infinite spin
40899228   bne  -> error
4089922A   move.b $20(a3),(a2)+     ; byte out of the FIFO
4089922E   move.b $50(a3),d3 ; btst #$5,d3 ; bne -> error   ; DISC?
40899238   moveq #$0,d0
```

**The two wait helpers — both poll STATUS bit 7 (INT):**

```
$40899704  (NO timeout — spins forever)
    loop: move.b $40(a3),d5 ; btst #$7,d5 ; beq loop
          move.b $70(a3),d5        ; FIFO flags
          move.b $50(a3),d5        ; INTR read LAST -- it clears
          andi.b #$30,d0 ; cmpi.b #$10,d0 ; rts   ; expects INTR & $30 == BS

$4089972A  (timeout = TimeSCSIDB, lowmem $0B24, << 8 DBRA iterations)
    loop: move.b $40(a3),d5 ; btst #$7,d5 ; dbne d3,loop ; dbne d0,loop
          beq -> timeout
          move.b $70(a3),d5 ; move.b $50(a3),d5 ; btst #$7,d5 ; rts
    timeout: move.b $70(a3),d5 ; clr.b d5        ; INTR forced to 0
```

Consequences: **a missing interrupt is invisible except as a long gap** — which
is exactly the 7 heartbeats after `C 10`. And the ROM reads **FIFO flags (`r7`)
on every wait**, taken or timed out, which is why the tracer now traces that
channel: it yields the FIFO count at each completion with no new ports into
`ncr53c96.sv`.

**The bulk DMA read** (`$4089927C`ff) matches
`docs/scsi/rom-driver-scsi-access-patterns.md` exactly — `FLUSH`, `TCM=0`,
`TCL=16`, `$90`, poll `STATUS bit 4 (TC0)`, read the 32-bit bulk port at
`a3+$40000`, residual `d2 & $0F` handled byte-at-a-time.

### 2.7 The machine-identity theory is moot, and was also wrong

A/UX Startup never launches a kernel, so `boardinit`, `machineID` and `c94info`
never run. Read anyway, from `/unix`'s symbol table:

- `machineID` is **not probed from hardware**. `_start` (`pstart` `0x54000`)
  takes it from the booter: with `d0 == $536D7201` and `a0` = the kernel-info
  block, `machineID = *(a0 + 0xB0)` (`a0+0x8C` + 9 longs of section info).
- `boardinit` (`0x583DE`) calls `setupProductInfo` then switches on `machineID`
  through a table of **16-bit** offsets at `0x5882A`, indexed by `machineID - 4`,
  range 4..`$39`. **35 of the 54 slots are `panic`.**
- machineIDs `$1C $21 $22 $32 $33 $39` (cpuspeed 25/33/33/20/25/40) take the
  branch at `0x5868A`, which patches
  **`c94info[2] = { base $50F10000, dreq $50F03A00, flag 1 }`** and sets
  `c94index[0] = 2`. `$50F03A00` = VIA2 + `$1A00` = register 13 = **IFR**, i.e.
  precisely the "Q800 reads DREQ from VIA2 IFR bit 0" arrangement in
  `netbsd-ncr53c9x-expectations.md` §1.1. **Correct for Wombat33 already.**
- machineIDs `$12 $14 $18` (Q900/Q950) take `0x58530`, leaving `c94info[2]` at
  its static `{ $50F0F000, $F9800024 }` — the DAFB DREQ. Not our machine.
- `setupProductInfo` (`0x589EE`) reads `RomVersion` from `$40800008` and takes
  `ProductInfoPtr` from `*(kstart + 0xDD8)` — lowmem `$0DD8`, `UnivROMInfoPtr`,
  i.e. handed over by the booter from the ROM's own UniversalInfo record.
- `c94info` = 4 entries × **24 bytes** at `0x5B60E`; `c94index` = 4 longs at
  `0x5B66E` selecting among them. Static contents:
  `[0] {$FE000200, 0, $200, $FE000300, $0E, 0}`, `[1] {$FE000000, …}`,
  `[2] {$50F0F000, $F9800024, $200}`, `[3] {$50F0F402, $F9800028, $200}`.
- `find_c94_pds` (`0x588A4`) only fires when `*(kernelinfoptr + 0x3C) == 0x48D`.

**And the "machine-dependent device table" the previous session found is not a
table.** `aux_whichfile.py` names the addresses:

```
0x0008c9e4 -> /core    + 0x9e4       <- a kernel CRASH DUMP (.text/.data/.bss pointers)
0x0007285c -> /newunix + 0x485c
0x0007573a -> /newunix + 0x773a
0x0006e82e -> /newunix + 0x82e
0x08c19742 -> /etc/config.d/newunix + 0x7742
```

### 2.8 `aux-c94-driver.md`'s addresses were wrong; they are now fixed

There are **four** COFF kernels on the disk, different builds:
`/unix` (5905 syms — the one `/nextunix` names), `/newunix` (6035),
`/etc/config.d/newunix` (3942), and a stale copy in free space at `0x1B4AC000`
(5805). The previous session disassembled a **free-space copy at `0x6C88000`**
and hand-derived a VMA↔disk delta; **none** of its `$1004xxxx` citations lands
on a function boundary in `/unix`, and no single constant relates them.

Every finding in that document was re-verified against `/unix` by searching for
the instruction sequences themselves, and the headings now carry symbol names:

| the doc used to say | actually, in `/unix` |
|---|---|
| chip setup `$1004FA6A` | **`c94_initchip`** `$10051534`; CONFIG1/2/3 writes at `$100515CC` |
| select sequence `$1004FAC6` | **`c94_select`** `$10051602`; IDENTIFY→FIFO `$10051668`, `$42` `$100516A2` |
| interrupt handler `$1004FF0A` | **`c94_intr`** `$10051046`; STATUS/STEP/INTR at `$1005106C`–`$10051088` |
| select-completion `$1004FB4E` | **`c94_iselect`** `$10050C86`; the DISC/FIFO-count test at `$10050CD0` |
| `dophase` `$1004EB80` | **`c94_phase`** `$1004FC64` |
| ret=8 default `$1004FD88` | **`doabort + $66`** `$1004B6CC` (and `scsitask + $1D0`) |
| string table `$1100C826` | **correct as it stood** |

---

## 3. What has been ruled out

- **A selection timeout** — it would print `ret = 5`, not `ret = 8` (§2.4).
- **A/UX's own `c94` driver** — it never runs; no kernel is ever launched.
- **A/UX autoconfiguration / machine identity** — downstream of a failure that
  happens first, and correct for a Q800 anyway (§2.7).
- **A missing SCSI command in our target model.** `rtl/ncr53c96.sv` implements
  TEST UNIT READY, REQUEST SENSE, INQUIRY, MODE SENSE(6), READ CAPACITY(10),
  READ(6), READ(10), WRITE(6), WRITE(10); everything else returns CHECK
  CONDITION / ILLEGAL REQUEST, which `saio` handles via its `stat == 2` branch
  and which would produce `ret = 4`, not `ret = 8`.
- **A separate, never-executed ROM driver.** `$40898xxx` and `$408D1xxx` are one
  manager sharing helpers (§2.6). The difference between the Mac OS boot path
  and A/UX Startup's path is *usage*, not code that has never run.
- **Our model's single-byte polled data-in path, by inspection.** The ROM
  expects `INTR & $30 == $10` (BS, not DISC) after a non-DMA `$10` in DATA IN;
  `rtl/ncr53c96.sv`'s `arm_pio_in` pushes one byte and `raise(I_BUS)`, i.e.
  INTR = `$10`. Matches. (Inspection only — not yet observed on hardware.)

**Still open:** which of `SCSIGet` / `SCSICmd` / `SCSIComplete` fails, and why.
Leading suspect, from §2.5 and §2.6: a `$10`/`$90` transfer that never raises
the interrupt the ROM polls for, with TC0 as the thing that differs.

---

## 4. Next moves, in order

1. **Deploy and capture.** Everything is staged: guest shut down, disk pristine,
   `output_files/wombat33.rbf` is the tracer build with timing met.
   ```sh
   bash scripts/scsi_trace.sh 300      # deploy + 300 s capture + decode
   ```
   A/UX Startup is in `System Folder:Startup Items` (as an alias), so it launches
   by itself — no ⌘B needed. With epoch-scoped dedup the attempt is visible
   whenever it happens.
2. **Read the epoch that contains the A/UX attempt.** Look for a `$10` or `$90`
   with no interrupt behind it, and the FIFO-flags value at the stall.
3. **Pin the sequence** in `verilator/tb_ncr53c96.sv` as a third dialect beside
   the ROM's DMA path and A/UX's `c94` path.
4. **Then** fix `rtl/ncr53c96.sv` — most likely the non-DMA TI path and the TC0
   semantics around it. `qemu-esp-behavior.md`: non-DMA TI = 1 byte in; TC is a
   DMA-mode concept, so *what TC0 should read after a non-DMA TI* is the open
   question, and the old trace's `$83/$03/$87` (TC0 clear) vs the ROM's
   `$93/$13/$97` (TC0 set) is the concrete discrepancy to explain.
5. **Turn `SCSI_TRACE` back off** in `wombat33.qsf` line 125 and rebuild before
   keeping anything. Note the debug build is 89 % ALMs vs 82 % for a release one.

Cheap fallbacks if that stalls: a different A/UX image installed for a Quadra
800 (a data problem, not an RTL one); NetBSD/mac68k as a differential probe.

---

## 5. The tracer — what changed and why

`rtl/iosb.sv`, gated behind `` `ifdef SCSI_TRACE ``, streams ASCII out the modem
port, which the MiSTer exposes as `/dev/ttyS1`.

**The change made this session.** First sightings used to be scoped to the whole
session (`seen_*` cleared only on `!nreset`), which is what destroyed the one
measurement that mattered. They are now scoped to an **epoch** of
`DBG_EPOCH_HB` = 8 heartbeats (~8 s):

- `dbg_epoch_clr` is a **registered one-shot** that wipes every `seen_*` table.
  It is consumed in the block that already owns those regs, so each net keeps
  exactly one driver — Verilator waves a second driver through under
  `-Wno-MULTIDRIVEN`, **Quartus rejects it outright (Error 10028)**. Do not lint
  with the Makefile's `-Wno-MULTIDRIVEN`.
- The epoch boundary emits an **`"E"` record carrying the epoch number**, in
  place of that second's heartbeat.
- Two new traced read channels: **FIFO flags (`r7`, tag `"f"`)** and **sequence
  step (`r6`, tag `"s"`)** — the ROM reads `r7` on every interrupt wait, so this
  gives the FIFO count at each completion without adding ports to
  `ncr53c96.sv`.
- `scripts/scsi_trace.sh`'s decoder understands `E` / `f` / `s`.

Verified: lint clean **with and without** `SCSI_TRACE` and **with
`MULTIDRIVEN` enabled**; `make tb_ncr53c96` still passes **87/87**; full Quartus
compile met timing at +0.248 ns.

**Other design notes worth keeping.** A once-a-second `H00` heartbeat, so a
silent port proves a broken link rather than being ambiguous. Bus faults traced
unconditionally, deduped by address, fed from `quadra800.sv`'s `svc == S_BERR` /
`svc_addr`. A "went somewhere else" probe for any `$5xxxxxxx` access that either
decodes nowhere or is 16-byte-strided inside a window we *do* decode — built
because the IOSB **acks undecoded `$5xxxxxxx` reads with zero rather than
faulting**, so a driver at a wrong base polls a permanently-zero register and
times out invisibly. (`sel_scsi = in_low && addr[17:8] == 10'h100`, so both
`$50F10000` and `$50010000` decode as SCSI.)

```sh
bash scripts/scsi_trace.sh [seconds]        # deploy + capture + decode
bash scripts/scsi_trace.sh --capture-only 60
```
Leaves `scratch/scsi_trace.txt` and `scratch/scsi_trace.decoded.txt`.

`scripts/build_only.sh` greps `wombat33.qsf` for the `SCSI_TRACE` line and, when
it is active, prints `*** DEBUG BUILD -- SCSI_TRACE on, guest serial port
hijacked, DO NOT RELEASE ***` in the BUILD STATUS summary, so a traced bitstream
cannot be mistaken for a release one.

---

## 6. Offline tooling built this session — the disk is readable on the host

None of the analysis in §2 needs hardware. The pristine image is on the MiSTer
as `games/Wombat33/backup/HD60_512-AUX3.1-Installed.zip` (61 MB, ~13 s to copy,
~8 s to unzip):

```sh
scp root@$MISTER_HOST:/media/fat/games/Wombat33/backup/HD60_512-AUX3.1-Installed.zip scratch/aux/
cd scratch/aux && unzip -o HD60_512-AUX3.1-Installed.zip   # b44b762375d90879973baaf7f817c020
```

| tool | what it does |
|---|---|
| `scripts/aux_ufs.py` | the `Apple_UNIX_SVR2` root slice (4.3BSD FFS) — `parts`, `ls`, `find`, `cat`, `stat` |
| `scripts/aux_whichfile.py` | raw image byte offset → which file owns it (also `--grep`) |
| `scripts/aux_coff.py` | m68k COFF: sections + the kernel's full symbol table — `hdr`, `syms`, `addr`, `off`, `dump` |
| `scripts/aux_dis.py` | capstone disassembly of a COFF range, annotated with those symbols, resyncing over embedded jump tables |
| `scripts/mac_hfs.py` | the `Apple_HFS` partition — `vol`, `ls`, `find`, `cat` (both forks), `at` (offset → file+fork) |
| `scripts/mac_rsrc.py` | resource fork — `list`, `get`, `dumpall` |
| `scripts/mac_dis.py` | 68k disassembly that resyncs over A-line traps, names them, and names SCSI Manager selectors |

```sh
python3 scripts/aux_ufs.py       IMG find /
python3 scripts/aux_ufs.py       IMG cat /unix scratch/aux/x/unix.bin
python3 scripts/aux_whichfile.py IMG 0x6c88000
python3 scripts/aux_coff.py      scratch/aux/x/unix.bin syms 'c94|scsi'
python3 scripts/aux_dis.py       scratch/aux/x/unix.bin boardinit
python3 scripts/mac_hfs.py       IMG at 0x7fe1002e
python3 scripts/mac_hfs.py       IMG cat ':A/UX Startup' scratch/aux/x/AUXStartup.rsrc --rsrc
python3 scripts/mac_rsrc.py      scratch/aux/x/AUXStartup.rsrc dumpall CODE scratch/aux/x/code/
python3 scripts/mac_dis.py       scratch/aux/x/code/CODE_6_saio.bin 0x1218 0x14e0
```

**Environment gotchas that will otherwise waste an hour:**

- Git Bash mangles `/`-leading arguments — export
  `MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'`.
- `python3` here is a **Windows** build: give it `C:/Temp/...` paths, not
  `/c/Temp/...`, or `open()` fails on paths `ls` can see.
- Export `PYTHONIOENCODING=utf-8:replace` or a Mac-Roman filename aborts a
  listing with a `cp1252` `UnicodeEncodeError`.
- `mac_hfs.py` uses **`:` as the path separator**, because `/` is legal in HFS
  names — `:A/UX Startup` is one file.
- `capstone` 5.0.7 with `CS_ARCH_M68K` is installed; no `dis68k` build is
  needed any more. Capstone stops dead on an undecodable word, hence the resync
  in both disassemblers.
- Verilator lives in WSL (`5.020`); `wsl -e bash -lc '...'` from Git Bash works.
  `wsl` prints a harmless `Failed to mount I:\` line on stderr.
- `ssh` without `-n` eats the rest of a piped bash script.

---

## 7. Working with the guest

**Boot A/UX on demand:** A/UX Startup's **Execute** menu has `Boot ⌘B`,
`AutoRecovery`, `AutoLaunch ⌘L`, `Kill ⌘K`, `Restart`, `Shut Down`. ⌘B triggers
a boot from the keyboard. Guest Command is PS/2 Left Alt (keycode 56); B is 48.

```sh
python scripts/mister_ws.py --host $MISTER_HOST --delay 0.15 down:56 raw:48 up:56   # Cmd-B
python scripts/mister_ws.py --host $MISTER_HOST --delay 0.15 down:56 raw:16 up:56   # Cmd-Q
bash scripts/guest/shutdown_finder.sh
bash scripts/grab.sh scratch/state.png      # screenshot, to verify before flashing
```

**Restore the pristine image between attempts** — A/UX writes during its failed
autorecovery (md5 goes from `b44b7623…` to something else; it was
`38fb0ddfd4584fc821ee38ead5f5d055` when this session started):

```sh
ssh root@$MISTER_HOST 'cd /media/fat/games/Wombat33 && unzip -o backup/HD60_512-AUX3.1-Installed.zip'
```
That takes about **6 minutes**. Do it with the guest shut down.

`scripts/guest/shutdown_finder.sh` supersedes `shutdown.sh`, which was tuned for
a five-item Special menu and aims at a hardcoded y=104 — this disk's System 7.1
Finder has **eight** rows, so that lands two rows below "Erase Disk…". The new
one confirms from the screenshot that the highlighted band is the panel's *last*
row before releasing, measured relative to the panel; its probe samples x
295..335, to the right of the item text where a hovered row is solid black, and
requires a run ≥ 8 px tall so the panel's own border is not mistaken for a row.
**Tune probes like this offline against saved screenshots, not on hardware.**

---

## 8. RTL changes carried in the working tree — keep them, they are real

From the previous session. None fixed the boot, but all are genuine defects
found by reading A/UX's and NetBSD's actual expectations, all are covered by
`verilator/tb_ncr53c96.sv` (87 directed checks over both driver dialects; T9
replays A/UX's register sequence verbatim), and the ROM path stayed green.

1. **`ncr53c96.sv`: do not flush the FIFO on a selection timeout.** A real 53C94
   leaves the driver's preloaded bytes there — nothing went out, because nothing
   answered. Both A/UX's `c94` (`c94_iselect`, `$10050CD0`) and NetBSD read that
   count to tell "this SCSI ID is empty" from "the target vanished mid-command".
   Clearing it made every empty ID look like a bus fault. Gap analysis item 17;
   pinned by T7.
2. **`ncr53c96.sv`: `$43` SELATNS and `$46` SELATN3** — both previously returned
   ILLEGAL COMMAND. `$43` now reports sequence step 1 with MESSAGE OUT visible
   and answers an EXTENDED message with MESSAGE REJECT, after which `$12`
   resumes into COMMAND rather than disconnecting, plus the sequence-step
   duplicate in FIFO-flags bits 7:5. Gap analysis item 16.
3. **`iosb.sv`: VIA2 IFR bit 0 (DREQ) reads as a live level.** A
   write-1-to-clear could knock the latched copy down while DRQ was still
   asserted, and the edge-detect could only restore it when DRQ *changed* — so a
   driver acknowledging the whole IFR mid-transfer would spin its DREQ poll out.
   Gap analysis item 11.

Two things learned the hard way, worth not repeating:

- **Do not lint with `-Wno-MULTIDRIVEN`.** It waved through a net driven from
  two `always` blocks that Quartus rejects outright (Error 10028), costing a
  build cycle.
- **`$11` ICCS must raise FC *without* BS.** A/UX's status handler fails on BS.
  NetBSD's notes say `FC|BS`; "correcting" our model to match NetBSD would have
  broken A/UX. Verified by T9.

Also inherited: the fitter-seed lottery. `wombat33.qsf` carries a long comment
on it — at ~82–89 % ALMs the `clk_sys` critical path is inside `ap040_core`
(`ir[7] -> exc_fmt[0]`) and swings ±0.4 ns with placement, so **walk seeds
rather than hunting in your own diff**. Seed 13 is current and met at +0.248 ns
with the tracer in.

---

## 9. Uncommitted files

Modified: `docs/scsi/README.md`, `docs/scsi/rtl-gap-analysis.md`, `rtl/iosb.sv`,
`rtl/ncr53c96.sv`, `rtl/quadra800.sv`, `scripts/build_only.sh`,
`verilator/Makefile`, `wombat33.qsf`.

New: `RESUME-aux-machine-id.md`, `RESUME-aux-scsi-manager.md` (this file),
`docs/scsi/aux-c94-driver.md`, `docs/scsi/aux-startup-boot-path.md`,
`scripts/aux_coff.py`, `scripts/aux_dis.py`, `scripts/aux_ufs.py`,
`scripts/aux_whichfile.py`, `scripts/mac_dis.py`, `scripts/mac_hfs.py`,
`scripts/mac_rsrc.py`, `scripts/guest/shutdown_finder.sh`,
`scripts/scsi_trace.sh`, `verilator/tb_ncr53c96.sv`.

`scratch/` is gitignored, so the 2 GB local disk image and the extracted
binaries cannot be committed by accident.
