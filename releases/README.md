# releases/

Dated core builds, named `wombat33_YYYYMMDD.rbf` (the convention the sibling
Mac cores use). The date is the **work date** the build belongs to, not
necessarily the wall-clock minute Quartus finished — an overnight session that
starts on the 29th is stamped `20260829` even if the fitter returned after
midnight.

Each entry records the md5 so a core on a MiSTer can be identified without
guessing, and the timing margin, because a build that fits but violates timing
must never be flashed (`scripts/deploy_screenshot.sh` refuses one).

| build | md5 | timing | notes |
|---|---|---|---|
| `wombat33_20260902.rbf` | `70716e92871448d1ff81ebb430902f4a` | met, **+0.130 ns** | **A/UX 3.1 boots to multiuser.** Both NCR53C96 SCSI bugs fixed (control-path phase flip + write-path chunk-flush). First build verified on hardware against BOTH A/UX 3.1 and Mac OS 8.1. Tracer off; seed 13; 85 % ALMs. |
| `wombat33_20260831_2.rbf` | `4414e7b3294b3d554a9e43faa16682bd` | met, **+0.062 ns** | **The machine has a serial port.** Ports the Z8530 SCC from MacLC onto the beat bus, plus MIDI-over-SCC and MT32-pi. 85 % ALMs — watch the slack. |
| `wombat33_20260831_1.rbf` | `3901ef5705f58dba3279c0417412f5f8` | met, +0.243 ns | **Sound works.** Fixes the watch-cursor wedge (ASC FIFOSTAT reported an empty FIFO as full) and hooks up the $806 volume slider. |
| `wombat33_20260830.rbf` | `64c79dfb93ceefb549200c78671cdc31` | met, +0.248 ns | **ADB actually works** — the mouse button reaches the guest and motion stops inventing input. |
| `wombat33_20260829.rbf` | `4c46a65c3a48b44ddb6f4fd6808d0422` | met, +0.245 ns | First build that boots Mac OS unattended. |

## `wombat33_20260902.rbf`

md5 `70716e92871448d1ff81ebb430902f4a`, timing met at **+0.130 ns** (seed 13,
`SCSI_TRACE` off). Fitter/STA reports next to it as
`wombat33_20260902.{fit,sta}.summary` (gitignored, local only).

**A/UX 3.1 now boots to the multiuser Finder desktop.** Two NCR53C96 SCSI bugs
in `rtl/ncr53c96.sv`, both needed:

1. **Control path:** non-DMA `$10` TRANSFER INFO flips phase to STATUS on the
   request's last byte. Killed "Protocol Error Processing SCSI request"; A/UX
   reaches `fsck`.
2. **Write path:** saio splits one WRITE into `$90` TIs of TC=256; the old
   completion arm flushed a part-filled sector buffer at every chunk boundary,
   so each sector got 256 real bytes + stale zeros and fsck saw "BAD SUPER
   BLOCK: MAGIC NUMBER WRONG." Fix: a chunk end is an interrupt only; only
   `sbuf_pos == 512` flushes. (Mac OS writes single-TI and never tripped it,
   which is why every prior build booted Mac OS but corrupted A/UX.)

Pinned in sim by `verilator/tb_ncr53c96.sv` T1–T15 (6556 checks). Full story in
`RESUME-aux-superblock.md`, `docs/scsi/rtl-gap-analysis.md` item 19, and
`docs/scsi/aux-startup-boot-path.md` §9.

**This is the tracer-off release of the seed-13 build.** `SCSI_TRACE` (the
`rtl/iosb.sv` modem-TX debug mux) is commented out in `wombat33.qsf`, so the
SCC reaches the serial pin normally. Removing the tracer logic reroutes the
netlist, so this is a distinct fit from the 09-01 `scratch/seeds` seed-13
backup (`abb5ede4…`, +0.132 ns) — same seed, different bytes.

**Hardware result (192.168.99.143, 2026-09-02):**

| guest | result |
|---|---|
| A/UX 3.1 (`HD60_512-AUX3.1-Installed.hda`) | boots through fsck → multiuser Finder desktop; 16+ min interactive (CommandShell, menus); `shutdown -h now` → "You may now switch off." |
| Mac OS 8.1 (`QuadSquad8.hda`) | boots to Finder; keyboard + mouse responsive; menu-bar clock ticks at idle; clean Shut Down. No regression. |

Both guests were exercised at idle and shut down cleanly. An apparent Mac OS
"foreground wedge" seen mid-session was traced to a test-harness bug (a guest
menu-driver script killed by a timeout left the mouse button held down), not
the bitstream; it did not reproduce with clean input.

## `wombat33_20260831_2.rbf`

md5 `4414e7b3294b3d554a9e43faa16682bd`, timing met at **+0.062 ns**.

The Quadra 800 gets a serial port for the first time: `rtl/scc.v` (the Zilog
85C30) ported from the MacLC/MacIIvi lineage, hung off the beat bus through a
new adapter in `rtl/iosb.sv` at `$5000C000`, plus MIDI-over-SCC and the
MT32-pi user-port block. Full rationale and the port map in
`docs/scc-port-survey.md`.

**Hardware result (192.168.99.143, 2026-08-31):** boots clean to the Mac OS 8
desktop with the SCC live. This was the real risk — the space previously
decoded as present-but-inert (reads 0, writes discarded, always acked), so the
ROM's `InitSCC` and its loopback selftest now get real answers for the first
time. A wrong answer there does not fail quietly: the sibling `lbmactwo` core
hit exactly this and the ROM dropped into the Test Manager. This one walks
straight through ROM → "Welcome to Mac OS" → extensions → Finder, and the
Serial Driver loads without the freeze that had to be fixed on the LC.

**Utilization moved, and the slack with it.**

| | before | after |
|---|---|---|
| Logic (ALMs) | 34,223 / 41,910 (82 %) | **35,436 / 41,910 (85 %)** |
| Registers | 28,980 | 29,886 |
| DSP blocks | 47 (42 %) | 51 (46 %) |
| RAM blocks | 421 (76 %) | 423 (76 %) |
| Worst slack | +0.243 ns | **+0.062 ns** |

+1,213 ALMs buys the whole feature set (both SCC channels, four UART
serializers, the MT32-pi block). The four extra DSPs are the baud arithmetic
introduced by the `SYS_CLK_HZ` parameterisation — one operand is constant, so
they can be forced into logic if DSPs ever get tight.

**62 ps is the number to watch.** It met, and every other domain is
comfortable (HDMI next at +0.243 ns), but this core is seed-sensitive and the
next netlist change could push `clk_sys` negative. Expect a seed re-roll rather
than a structural problem if it does.

Still unproven on hardware: PPP, MIDI and MT32-pi end to end. Those need
guest-side setup (a PPP client and MacTCP/OT) and, for MT32-pi, a Pi on the
user port. The RTL paths are covered in simulation by
`verilator/tb_iosb_scc.v`, which measures 1056 clk/bit on `scc_txd_a` — 31250
baud at 33 MHz — through the real bus adapter.

## `wombat33_20260831_1.rbf`

md5 `3901ef5705f58dba3279c0417412f5f8`, timing met at +0.243 ns (seed 6).

Two changes, both in `rtl/easc.sv`.

**The watch-cursor wedge is fixed.** `$804` FIFOSTAT bits 1/3 read
`(cap == 0) || (cap >= 1023)`, so an EMPTY FIFO reported itself FULL. A guest
that fills until the full flag sets therefore wrote nothing; with no bytes
queued nothing ever popped, so the half-empty edge never fired and no refill
interrupt was ever raised. The wait never ended. Mac OS sat at a fully drawn
desktop with a watch cursor and a stopped menu-bar clock while ADB kept
tracking the mouse at interrupt level -- interrupts were fine all along, the
foreground was simply blocked forever.

Scored on hardware against `wombat33_20260830.rbf`, every run on a freshly
restored disk:

| build | scanout | ASC IRQ | menu-bar clock |
|---|---|---|---|
| `20260830` (known good) | 33 MHz | n/a | ticks |
| pre-fix | 25.175 MHz | off | FROZEN |
| pre-fix | 33 MHz | off | FROZEN |
| pre-fix | 25.175 MHz | off | FROZEN (2nd sample) |
| this build | 25.175 MHz | **on** | ticks |

Note rows 2-4: the wedge reproduced with the ASC interrupt DISCONNECTED and
with the DAFB scanout forced back off the 25.175 MHz pixel clock. Both of
those were the prime suspects and both are innocent. Do not re-investigate
them; the fault was always the status register.

**The Sound control panel's volume slider works.** `$806` was stored and
ignored (MAME does not apply it either). Bits 7-5 are the eight steps the
panel offers; the gain table is `x*256/7` so step 7 is EXACTLY unity and a
machine at maximum sounds identical to before. `volume` resets to `0xE0`
(max), not 0 -- the boot chime is ROM-generated before Mac OS loads any sound
preference, and a zero reset would silence it.

`make tb_easc` passes 18/18, including `stat after reset = 05`.

## `wombat33_20260830.rbf`

The build where ADB input is correct. Deployed to the MiSTer at
192.168.99.143 and verified against the pristine *Quad Squad* image (md5
`f4287aee9ff9a4413fa1e5fd9f2d63b4`) on two separate boots.

One RTL hunk, in **`rtl/via6522.sv`**: in ACR modes `011`/`111` CB1 is an input
and the internal shift clock IS the pin, but the RTL forced `shift_clock` high
whenever `shift_active` was low. Clearing `shift_active` on an `sr_ext_complete`
therefore drove it 0→1, and that rising edge shifted the byte the completion had
just loaded one place left, with `cb2_i` (tied low) in the LSB — **every byte the
ADB shim delivered, every time**.

An ADB mouse Talk R0 byte 0 is `{~button, dy[6:0]}`, so the button is exactly the
bit a left shift throws away, and what took its place was the old bit 6, the sign
of dy. That is both halves of the fault the previous entry lists as a known
issue: clicks did nothing, and plain motion with dy ≥ 0 read as button-down,
which is why mouse movement alone opened menus and appeared to type.

Scored against a control build differing only in that hunk — same disk, same ROM,
same injected mouse traffic — non-`$00` bytes surviving from the transceiver to
the driver went from **0 / 82** to **670 / 670**. Full derivation and the
measurement method: `docs/adb-via-shift.md`.

Also here: fitter `SEED` 2 → 3. Seed 2 gave −0.283 ns hold on the 99 MHz
`clk_ram` domain, which a `clk_sys`-domain change cannot reach — the placement
swing the qsf comment warns about, not the RTL.

What this build makes possible: `scripts/mac_shutdown.sh` now drives Special →
Shut Down unattended, so a core can be swapped without power-cutting a mounted
HFS volume.

**Known issues.**

- **Boot stalls roughly 1 in 3.** Frozen at "Starting Up…", disk `pos` frozen,
  screen byte-identical for minutes. Present before this build and not caused by
  it; reproduced here on a freshly restored pristine image. See
  `RESUME-adb-and-corruption.md` for the ADB-deadlock hypothesis and the
  detector committed to test it.
- **Host keystrokes never reach the guest.** Host-side, not the core —
  `kbd:osd` does not open the MiSTer OSD either, so nothing is arriving at the
  Main. The core's ADB keyboard path is therefore untested end to end.
- The Mac reads exactly one hour behind the host (minutes dead-on), which looks
  like standard vs daylight time in what the Main sends.

## `wombat33_20260829.rbf`

First core that reaches the Mac OS desktop with no operator intervention:
core load → `SC0` auto-mount of `games/Wombat33/QuadSquad8.hda` → Finder.
Verified on the MiSTer at 192.168.99.143 against the pristine *Quad Squad*
image (md5 `f4287aee9ff9a4413fa1e5fd9f2d63b4`).

Fixes in this build, over the first hardware run:

- **`ncr53c96`** — a non-DMA transfer-info that underflows now ends the data
  phase (`PH_STAT` + `I_BUS`) instead of waiting forever for a byte the target
  will never produce. This was the freeze at "Starting Up…": an INQUIRY with a
  `$24` allocation length delivered all 36 bytes and the chip then sat in
  DATA-IN. Matches QEMU `esp.c:667-671`.
- **`iosb`** — the A_SDMA hold-off got an escape (a wedged pseudo-DMA beat
  releases into a bus error rather than deadlocking the machine), and that
  escape's watchdog is frozen while a platform block transfer is outstanding,
  so SD latency cannot trip it.
- **`iosb`** — the ADB transceiver handshake moved into the `adb_en` domain.
  Driving it at full `clk` dropped command bytes and delivered response bytes
  more than once.
- **`wombat33.sv`** — CONF_STR `S0` → `SC0` so the mount is remembered, plus a
  latch that replays a mount arriving while the machine is held in reset.
- **`wombat33.qsf`** — fitter `SEED` 1 → 2; seed 1 produced a −0.122 ns hold
  violation on the 99 MHz `clk_ram` domain.

**Known issue (RESOLVED in `wombat33_20260830.rbf`, and the guess below was
wrong — it was the VIA shift register, not the heartbeat):** occasional phantom
keystrokes remain. The ADB duplicate-byte
defect is fixed and measured (VIA deliveries per transceiver byte dropped from
~2.3× to ~1.3×), and mrext is ruled out — it sends only `mouseMove`/`mouseBtn`,
never `kbd`. The residue is most likely the idle-autopoll heartbeat
re-delivering a stale `kbd_to_mac`; see `RESUME-first-hardware-run.md`.

The Quadra 800 ROM (`quadra800.rom`) is **not** committed — Apple firmware, see
`.gitignore`. Put your own 1 MB image there; the deploy seeds it to the MiSTer
as `games/Wombat33/boot.rom`.
