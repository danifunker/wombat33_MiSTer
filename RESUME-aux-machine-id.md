# Resume prompt — A/UX 3.1: the pivot away from SCSI

> **SUPERSEDED 2026-09-01 by `RESUME-aux-scsi-manager.md`.** §1's central claim
> — "A/UX never issues a SCSI select at all, so this is not a SCSI bug" — is a
> misreading of the trace. `A/UX Startup` is a Mac application that drives the
> disk through the ROM's SCSI Manager and was never going to write a select to
> the chip; the tracer dedups per core load, so its ROM-dialect traffic was
> already marked seen during the Mac OS boot. §3's machine-identity theory is
> also moot: that code is downstream of a failure that happens first, and it is
> correct for a Q800 anyway. See
> [`docs/scsi/aux-startup-boot-path.md`](docs/scsi/aux-startup-boot-path.md).
> §5–§8 (the tracer, the guest scripts, the RTL changes, machine state) are
> still accurate and still useful.

Paste this as the opening message of a new session. **This supersedes
`RESUME-aux-scsi.md`, whose central premise turned out to be wrong.** Read
this one instead; keep that one only for the history of what was tried.

Repo on `main`, uncommitted working tree (nothing has been committed this
session). Goal unchanged: **get A/UX 3.1 to boot on Wombat33.**

**Binding rule, unchanged:** never load a core while the guest is running.
`bash scripts/guest/shutdown_finder.sh` now does the Mac OS shutdown
reliably — see §6.

---

## 1. The headline: it is not a SCSI bug

The previous session assumed A/UX was failing *inside* the 53C96 model.
It is not. **A/UX never issues a SCSI select at all.** Its stack fails
before it ever touches the chip.

This was established on hardware, not in simulation, with a protocol
tracer built into the core (§5). The complete set of command bytes ever
written to the 53C96 across a whole session — power-on, Mac OS boot, A/UX
Startup running and failing, 175 s of capture — is:

```
$02 RESET CHIP   $00 NOP   $01 FLUSH   $03 RESET BUS
$C1 DMA-SELECT   $90 DMA TRANSFER INFO   $11 ICCS   $12 MSG ACCEPT   $10 TI
```

Every one of those is the **Quadra 800 ROM's** dialect. There is no `$42`
SELATN, no `$41` SELNATN, no `$1A` SET ATN — the FIFO-preloaded forms that
A/UX's own `c94` driver provably uses (`docs/scsi/aux-c94-driver.md` §3,
disassembled from this very disk image).

The tracer records **first sightings** — one record the first time each
distinct value appears on a channel — so this is not a sampling artifact.
A single `$42` anywhere in the session would be in that list. It is not.

Corroborating, from the same capture:

- **Zero** accesses anywhere in `$5xxxxxxx` that our decode does not answer.
- **Zero** 16-byte-strided (i.e. 53C9x-shaped) accesses outside the SCSI
  window — the striding test discriminates, because VIA1/VIA2 registers are
  512-byte strided and the SCC is 4-byte strided.
- The only bus faults are an ordinary NuBus slot probe: `$FFFFxxxx` down to
  `$F1FFxxxx` in 16 MB steps, reading near the top of each slot. Unrelated.
- The last **124 seconds** of the capture are pure silence — heartbeats
  only. That is A/UX Startup running, failing, and printing its errors,
  while touching no SCSI hardware whatsoever.

So A/UX is not looking in the wrong place. **It is not looking.**

## 2. Why "Protocol Error" told us nothing

The log line that drove the whole previous investigation —

```
Disk c0d0s0 Error: Protocol Error Processing SCSI request
```

— is A/UX's **catch-all default**, not a diagnosis. From `$1004fd88`, the
generic "fail this request" routine (disk `0x6C8F828`):

```
    tst.b  ([A3],$27)        ; req->ret already set by a specific path?
    bne    keep
    move.b #$8, ([A3],$27)   ; else ret = 8
```

and `table[8]` is "Protocol Error Processing SCSI request". Every failure
path that does not set something more specific lands here. The message is
emitted on the **first** request (the A/UX Startup log has nothing before
it — the scrollbar is at the top), three retries, then "Retry limit".

That is the signature of a controller that was never attached, not of a
protocol that went wrong.

## 3. Where the evidence points now

A/UX's *disk* driver (`gd`) is running and issuing requests. Its *SCSI
controller* is not. The failure is in A/UX's autoconfiguration.

**The kernel does know this machine.** Scanning the disk image for I/O base
constants finds both families present:

| constant | meaning | disk offsets |
|---|---|---|
| `50 F1 00 00` | `$50F10000`, the **Quadra 800** 53C96 register base | `0x7285C`, then a cluster at `0x8C9E4, 0x8CA04, 0x8CA14, 0x8CA60, 0x8CADE` |
| `F9 80 00 24` | `$F9800024`, the **Q700/900/950** DREQ register (a DAFB register) | `0x7573A`, `0x8C19742` |
| `F9 80 00 00` | DAFB base | `0x6E82E`, `0x6E884`, … |

The five-reference cluster at `0x8C9E4`–`0x8CADE` looks like a
**machine-dependent device table**. So A/UX 3.1 is not missing Quadra 800
support — it is declining to select that entry.

**Why it might be choosing wrong.** This disk image is an **Apple
Workgroup Server 95** installation. The AWS line is 60 / 80 / 95, matching
Centris 610 / Quadra 800 / **Quadra 950** — "95" is a model number, not a
year. Evidence on the disk: Retrospect A/UX "for the Apple Workgroup Server
95" documentation and Read Me files, and AppleShare Pro benchmark tables
comparing "on Macintosh Quadra 950" with "on AWS 95". The A/UX Startup
splash also reads *"Welcome to The Apple® Workgroup Server 95"*.

**Be careful with that splash** — a scan of the whole image found the string
"Workgroup Server 95" only inside Retrospect and AppleShare documentation,
never in a machine-name lookup table. So it is not by itself proof of
runtime detection. It is, however, consistent with the image being a Q950
system installed on Q950 hardware.

The two families take genuinely different SCSI paths
(`docs/scsi/netbsd-ncr53c9x-expectations.md` §1.1): Q800 ("Wombat") reads
DREQ from the IOSB's emulated VIA2 vIFR bit 0, while Q700/900/950 read it
from `$F9800024` in DAFB. If A/UX has decided this is the second kind, its
glue would be configured for hardware we do not present.

**Caution against over-committing to this.** It is the leading hypothesis,
not a proven one. What is *proven* is only that A/UX never touches the
chip. An equally live possibility is that autoconfig fails for an unrelated
reason and the machine identity is a red herring.

## 4. What to do next

In rough order of cost:

1. **Open A/UX Startup's `Preferences → Booting…` and `Preferences →
   General…`** (menu at x≈222; the two items are the only ones). Free, and
   it may name the machine, the kernel path, or offer a verbose/monitor
   mode. Not yet looked at.
2. **Disassemble the machine dispatch.** Pull the region around disk
   `0x8C9E4`–`0x8CADE` and `0x7285C` / `0x7573A` and find what the table is
   indexed by, and where that index comes from. The method is written up in
   `docs/scsi/aux-c94-driver.md` §1 (dd the region, build `dis68k` against
   the Musashi disassembler already vendored in `verilator/sim/`, derive the
   VMA↔disk delta by voting `link A6` prologues against absolute constants —
   do not compute it by hand, that produced a wrong answer once).
3. **Find what A/UX reads to identify the machine** and check what our core
   returns for it. Candidates: the ROM's Gestalt (our ROM is a genuine Q800
   ROM, so this *should* be right), VIA1 port A (we hardcode `8'h12` in
   `rtl/iosb.sv`), the `$5FFFxxxx` ID register (we return `$A55A2BAD`), and
   the djMEMC / IOSB config registers.
4. **Consider a different disk image.** If the AWS 95 theory holds, an A/UX
   image installed for a Quadra 800 may simply boot. That is a data problem,
   not an RTL one, and would be by far the cheapest fix.
5. **NetBSD/mac68k as a differential probe.** Worth it *if* the above
   stalls. It separates "our machine looks wrong to a Unix kernel" from
   "A/UX specifically declines this hardware", and it would independently
   exercise the `$43`/`$46`/message-out code that A/UX never reaches. It is
   a real bring-up though (mac68k boots via a MacOS Booter app much like
   A/UX Startup), so it is not the cheap first move.

## 5. The tooling built this session — use it

**`rtl/iosb.sv` now contains a SCSI protocol tracer.** It streams ASCII out
the modem port, which the MiSTer exposes as `/dev/ttyS1`. It exists because
the ROM *polls* the chip (so its failures are visible hangs) while A/UX uses
the interrupt line and message phases the ROM never touches — so an A/UX
failure otherwise has no observable surface at all.

```sh
bash scripts/scsi_trace.sh [seconds]        # deploy + capture + decode
bash scripts/scsi_trace.sh --capture-only 60
```

Leaves `scratch/scsi_trace.txt` (raw) and `scratch/scsi_trace.decoded.txt`.
Design notes worth keeping:

- **First-sighting records.** One record per distinct value per channel
  (command byte, INTR value, STATUS value, target id, each config register,
  each probe address). Bounds a session to a few hundred records. The
  earlier stream-everything version was useless: the ROM's own bursts fill
  the 64-entry queue faster than 115200 drains it, so "I saw no A/UX
  select" could just mean it was dropped.
- **A once-a-second heartbeat** (`H00`) before anything else happens, so a
  silent port proves a broken link rather than being ambiguous. This is what
  established the channel was working when the first capture was empty.
- **Bus faults** are traced unconditionally, deduped by address, fed from
  `quadra800.sv`'s `svc == S_BERR` / `svc_addr` (previously unconnected).
- **A "went somewhere else" probe**: any `$5xxxxxxx` access that either
  decodes nowhere, or is 16-byte-strided inside a window we *do* decode.
  Note the trap it was built to catch — the IOSB **acks undecoded
  `$5xxxxxxx` reads with zero rather than faulting**, so a driver at a wrong
  base polls a permanently-zero register and times out invisibly.

**The tracer is gated — a normal build does not contain it.** It is wrapped in
`` `ifdef SCSI_TRACE `` in `rtl/iosb.sv`; with the macro undefined the whole
block compiles out and `assign scc_txd_a = scc_txd_int;` gives the modem port
back to the guest's SCC. Both configurations are lint-clean.

To build **with** the tracer, uncomment this line in `wombat33.qsf` (it sits in
the existing block of commented `VERILOG_MACRO` switches, with the warning
alongside it):

```
set_global_assignment -name VERILOG_MACRO "SCSI_TRACE=1"
```

`scripts/build_only.sh` greps for that line and, when it is active, prints

```
*** DEBUG BUILD: SCSI_TRACE is ENABLED in wombat33.qsf ***
```

before the compile and

```
  *** DEBUG BUILD -- SCSI_TRACE on, guest serial port hijacked, DO NOT RELEASE ***
```

in the BUILD STATUS summary — so a traced bitstream cannot be mistaken for a
release one. **Turn it back off before building anything you intend to keep,**
and note that the bitstream currently on the MiSTer (§8) is a traced one.

Other tooling:

- **`scripts/guest/shutdown_finder.sh`** — Finder Special → Shut Down,
  verified. The existing `shutdown.sh` was tuned for a five-item Special
  menu and aims at a hardcoded y=104; this disk's System 7.1 Finder has
  **eight** rows, so that y lands two rows below "Erase Disk…". The new one
  confirms from the screenshot that the highlighted band is the panel's
  *last* row before releasing, measured relative to the panel rather than an
  absolute pixel. Its probe samples x 295..335 — to the right of the item
  text, where a hovered row is solid black — and requires a run ≥ 8 px tall
  so the panel's own 1–2 px bottom border is not mistaken for a row.
  Tune probes like this **offline against saved screenshots**, not by
  iterating on hardware.
- **`verilator/tb_ncr53c96.sv`** (`make tb_ncr53c96`, seconds, no ROM or
  disk) — 87 directed checks over **both** driver dialects. T9 replays
  A/UX's register sequence verbatim as transcribed from its disassembly.
- **`docs/scsi/aux-c94-driver.md`** — A/UX's own driver, disassembled:
  register map, select sequence, interrupt handler, `dophase` table, the
  `ret` code table, and how to redo the disassembly.

## 6. Working with the guest

**Boot A/UX on demand:** A/UX Startup's **Execute** menu has
`Boot ⌘B`, `AutoRecovery`, `AutoLaunch ⌘L`, `Kill ⌘K`, `Restart`,
`Shut Down`. **⌘B triggers a boot from the keyboard** — so start the serial
capture *first*, then send ⌘B, and the trace contains only A/UX's attempt
instead of a whole Mac OS boot. Guest Command is PS/2 Left Alt (keycode 56);
B is keycode 48.

**Shut down before every flash:**
```sh
python scripts/mister_ws.py --host $MISTER_HOST --delay 0.15 down:56 raw:16 up:56   # Cmd-Q
bash scripts/guest/shutdown_finder.sh
```
Verify the "It is now safe to switch off your Macintosh" screen before
flashing.

**Restore the pristine image between attempts** — A/UX writes during its
failed autorecovery (md5 goes from `b44b7623…` pristine to something else):
```sh
ssh root@$MISTER_HOST 'cd /media/fat/games/Wombat33 && unzip -o backup/HD60_512-AUX3.1-Installed.zip'
```

## 7. RTL changes made this session — keep them, they are real

None of these fixed the boot (nothing was reaching them), but all are
genuine defects found by reading A/UX's and NetBSD's actual expectations,
all are covered by `tb_ncr53c96.sv`, and the Mac ROM path stayed green
throughout (verified in the full-machine Verilator gate run: READ(6),
READ(10), WRITE(10), zero illegal-command interrupts).

1. **`ncr53c96.sv`: do not flush the FIFO on a selection timeout.** A real
   53C94 leaves the driver's preloaded bytes in the FIFO — nothing went out,
   because nothing answered. Both A/UX's `c94` and NetBSD read that count to
   tell "this SCSI ID is empty" from "the target vanished mid-command".
   Clearing it made every empty ID look like a bus fault. Gap analysis
   item 17; pinned by T7.
2. **`ncr53c96.sv`: `$43` SELATNS and `$46` SELATN3.** Both previously
   returned ILLEGAL COMMAND. `$43` now reports sequence step 1 with MESSAGE
   OUT visible and answers an EXTENDED message with MESSAGE REJECT, after
   which `$12` resumes into COMMAND rather than disconnecting. Plus the
   sequence-step duplicate in FIFO-flags bits 7:5. Gap analysis item 16.
3. **`iosb.sv`: VIA2 IFR bit 0 (DREQ) reads as a live level.** A
   write-1-to-clear could knock the latched copy down while DRQ was still
   asserted, and the edge-detect could only restore it when DRQ *changed* —
   so a driver acknowledging the whole IFR mid-transfer would spin its DREQ
   poll out. Gap analysis item 11 asked for this to be verified; it was
   reachable.

Two things learned the hard way, worth not repeating:

- **Do not lint with `-Wno-MULTIDRIVEN`.** It waved through a net driven
  from two `always` blocks that Quartus rejects outright (Error 10028),
  costing a build cycle.
- **`$11` ICCS must raise FC *without* BS.** A/UX's status handler
  (`$1004ec36`) fails on BS. NetBSD's notes say `FC|BS`; "correcting" our
  model to match NetBSD would have broken A/UX. Verified by T9.

## 8. Machine state as left

| | |
|---|---|
| Guest | **shut down** ("safe to switch off") |
| Core running | `output_files/wombat33.rbf`, md5 `eb427f3fb5fe64b7b7dbbba2482caefe` — **a DEBUG build: it was made before the tracer was gated, so the tracer is active in it and it owns the serial port. Do not keep it. Rebuild with `SCSI_TRACE` commented out in the .qsf for anything else.** |
| Timing | met, worst slack +0.245 ns |
| A/UX disk | `/media/fat/games/Wombat33/HD60_512-AUX3.1-Installed.hda`, restored pristine, md5 `b44b762375d90879973baaf7f817c020` |
| Mount | slot 0 → the A/UX image (`/media/fat/config/Wombat33.s0`) |
| Mac OS control disk | `games/Wombat33/QuadSquad8.hda` — **not re-verified on hardware this session**; do that before trusting any of the RTL changes on real hardware |

Working tree (uncommitted): `rtl/ncr53c96.sv`, `rtl/iosb.sv`,
`rtl/quadra800.sv`, `verilator/Makefile`, `docs/scsi/README.md`,
`docs/scsi/rtl-gap-analysis.md`, `wombat33.qsf` (the gated `SCSI_TRACE`
switch), `scripts/build_only.sh` (debug-build banner), plus new
`verilator/tb_ncr53c96.sv`,
`docs/scsi/aux-c94-driver.md`, `scripts/scsi_trace.sh`,
`scripts/guest/shutdown_finder.sh`, and this file.
