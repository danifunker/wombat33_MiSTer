# 53C96 RTL gap analysis — what to fix for the disk-boot gate

Synthesis of the five research docs in this directory (2026-08-28), mapping
`rtl/ncr53c96.sv` + `rtl/iosb.sv` as of `eb3311f` against what the Quadra 800
ROM actually does (`rom-driver-scsi-access-patterns.md`), with QEMU
(`qemu-esp-behavior.md`), MAME (`mame-ncr53c90-quadra-pdma.md`) and NetBSD
(`netbsd-ncr53c9x-expectations.md`) as behavior oracles, plus the repo's own
failure history (`repo-scsi-issue-history.md`).

## The contract, compressed

The ROM's disk boot uses exactly this chip vocabulary (nothing else):
`$01` flush · `$02` chip reset · `$03` bus reset · **`$C1`/`$C2` DMA select
with TC=1 and an EMPTY FIFO** · `$90` DMA transfer-info · `$10` PIO
transfer-info · `$11` ICCS (never `$91`) · `$12` message accept.
It polls STATUS bits 7 (INT), 4 (TC0), 2:0 (phase); INTR bit 5 (disconnect);
FIFO-flags `& $1F` (count) and bit 4 (=16 bytes); and DREQ as **VIA2 IFR
bit 0**. It **never reads the sequence-step register** on the Q800 path, and
never uses TCH/reg 14 (16-bit counter, 0 = 65536). CDBs are delivered as:
select leaves a 1-byte DMA request pending → SCSICmd flushes, loads TC=1,
issues `$90` in COMMAND phase, PIO-pushes CDB bytes 0..n−2 into the FIFO,
waits for the FIFO to drain, then writes the **last byte through the PDMA
port** to retire TC. Bulk data: `$90` with TC=16 per chunk (non-blind read:
gate on TC0 + DREQ + FIFO=16, drain 4×`move.l` from `base+$40100`, wait INT,
read INTR) or TC=full-count (writes/blind). Status+message: `$11`, wait INT
(FC), read FIFO twice, `$12`.

## P0 — showstoppers (the boot cannot mount a disk until these are fixed)

1. **DMA select executes a garbage CDB.** `exec_command` masks off the DMA bit
   (`ncr53c96.sv:327`) and `run_cdb` reads the CDB from the FIFO immediately —
   but the ROM's FIFO is *empty* at select time, so `opc = 8'h00` and every
   command runs as TEST UNIT READY. The scan survives by coincidence (the probe
   *is* TEST UNIT READY); the first READ(6) of the partition map returns
   status instead of data and the mount dies.
   **Fix:** on `$C1`/`$C2` to a mounted target: latch TC, set phase = COMMAND
   (2) — the ROM's SCSICmd explicitly waits for phase 2 — assert DRQ
   (DMA-out pending, TC≠0, FIFO not full), raise **no interrupt** (the ROM's
   select poll exits on DREQ, `$408D1988`). Accumulate CDB bytes from BOTH
   sources — FIFO-register writes *and* PDMA-window bytes (the mixed delivery
   is also QEMU-documented MacOS behavior, commit `8ba3204893`) — until
   `group_len(byte0)` bytes have arrived ($C2: byte 0 of the stream is the
   IDENTIFY message, then the CDB). Then execute, set the command's data/status
   phase, raise `I_BUS|I_FC`. Selection timeout stays as-is: `I_DISC` only,
   seq 0.
2. **The 32-bit PDMA window doesn't decode.** The ROM's bulk port is
   `base+$40000+$100` = `$50F50100` (`$408D1EC0`), i.e. **address bit 18 set**
   — an I/O image per the dev note ($50040000–$53FFFFFF repeat every $40000).
   `iosb.sv:369` matches `addr[19:8] == 12'h101`, which requires bits 19:18
   clear → the bulk window falls through to whatever else decodes there. Every
   boot-path 16-byte burst hits it.
   **Fix:** treat the image bits as don't-care in `sel_scsi`/`sel_sdma`
   (match `addr[17:8]` == `1'h1_00`/`1'h1_01` within the low window, or mask
   bit 18 explicitly). MAME's map does the same (`.select(0x00fc0000)`, and
   `.mirror(0x00fc0000)` on the register window).
3. **DMA data bypasses the FIFO, so FIFO-flags never gate.** The non-blind
   read loop tests `btst #4,$70(a3)` ("16 bytes present", `$408D1FAC`) after
   TC0 sets and before each burst; our DMA path streams from `sbuf` with
   `fifo_cnt` stuck at 0 → infinite poll.
   **Fix:** route DMA data through the FIFO. `$90` in DATA IN: move
   `min(TC, 16, room)` bytes sbuf→FIFO (decrement TC per byte; TC0 on 1→0);
   PDMA reads pop the FIFO; when `TC==0 && fifo_cnt < 2` raise `I_BUS` (QEMU
   `esp_dma_ti_check` — the ROM drains first, then spins for INT, so the
   interrupt condition must include the FIFO-drained term). DATA OUT: PDMA
   pushes → FIFO, decrement TC per pushed byte (MAME `48f836e5c08`: "transfer
   count only decrements on DACK in DMA write mode, **and 68040 Macs require
   it**"), chip drains FIFO → sbuf; the ROM polls FIFO-empty between chunks.
   DRQ becomes a continuous function: DMA active && !TC0 && (in: used ≥ 2 —
   with the LBTM/TC0-set exception; out: free ≥ 2). Both QEMU and MAME use the
   2-byte threshold for 16-bit PDMA; the last odd byte deliberately never
   raises DRQ and arrives via the byte port.
4. **Same-cycle interrupt-raise vs INTR-read race.** The target FSM's
   `raise()` and the register block's reg-5 read-clear are in one `always`
   block; a collision drops the interrupt (`ncr53c96.sv:153-156` vs
   `306-309`). B1 proved the ROM spins on INT bits; a dropped raise is an
   infinite poll. Give the raise priority (or make clear-then-raise explicit).
5. **Sector chaining under TC-sized bursts.** The ROM reads 512 bytes as 32 ×
   (`$01` flush + TC=16 + `$90`) — the flush between bursts must NOT discard
   prefetched data (keep read-ahead in `sbuf`, load the FIFO per `$90`), and
   phase must flip to STATUS only when `blocks_left == 0` and the buffer is
   drained, so the ROM's next poll sees phase ≠ 1 / dispatches to `$11`.

## P1 — needed shortly after (driver takeover, writes, suites)

6. **IOSB PDMA byte-lane handling** (`iosb.sv:528-540`): a byte access
   currently moves **two** bytes (`sdma_left <= 2` for anything not
   `be==4'b1111`) and word accesses at odd offsets take the wrong lanes. The
   ROM uses `move.b`/`move.w` at `base+$100` (CDB last byte, residuals,
   SCSIComp reads) and `move.l` at `base+$40100`. Match MAME's cases: 32-bit =
   two 16-bit halves MSB-first; 16-bit = one half; byte = **one** byte, MSB
   lane. Byte order end-to-end is already verified correct (first SCSI byte =
   D31-24/D15-8; MAME `dma16_swap` + NetBSD agree).
7. **Hold-off needs an escape.** *(FIXED 2026-08-29 — `iosb.sv` now times
   `A_SDMA` out after 2^18 ce-cycles ≈ 7.9 ms and releases the beat with a new
   `sdma_fault`, which `quadra800.sv` turns into a bus error.)* `iosb.sv` used
   to withhold `ack` on `!DRQ` forever, and `quadra800.sv` has no watchdog, so a
   stalled PDMA beat deadlocked the machine — `svc` reaches `S_IDLE` only on the
   matching ack, so it could never recover even after the CPU escaped.
   **Correction to the original note:** the CPU watchdog *does* exist — the
   `ap040_bus_timeout` at `wombat_cpu.sv:85` (2^21 ≈ 63 ms). It was added in
   `46bd86c`, before this doc was written; the doc author looked only at
   `quadra800.sv`. It let the *CPU* fault out, but left the bus and IOSB state
   machines wedged, so the machine died anyway. The new IOSB timeout is
   deliberately ~8x shorter so the fault is reported with the bus released.
   The non-blind boot
   path pre-gates on DREQ so it may survive, but the **blind** driver path
   (`$408D228E`/`$408D216C`, chosen per-drive at `$00001936`) does raw
   unrolled `move.l` with no polling and *relies* on a bus error + the ROM's
   handler at `$408D2606` (which also reads IOSB `$50F18300` fault-status /
   `$50F18400` data-latch and clears `$50F18300`). Minimum: a cycle-limit on
   `A_SDMA` that releases into a bus error, asserted also when the chip raises
   INT mid-stall (NetBSD case 3); implement the `$50F18300`/`$400` pair if the
   blind path is exercised.
8. **Non-DMA transfer-info is wrong in both directions.**
   *(The one-byte-per-`$10` handover and the data-out drain are implemented.
   The missing piece — an underflow escape — was FIXED 2026-08-29, and it is
   what froze Mac OS on hardware: `arm_pio_in` gates on `byte_avail`, so once
   the source ran dry `xfer_pio_in` stayed armed forever with no `I_BUS` and no
   phase change. Reproduced in sim: an INQUIRY with a $24 allocation length
   moves all 36 bytes, the last four one at a time, and the chip then sits in
   DATA-IN with the driver polling for an interrupt that never comes. The DMA
   side already had this escape at `ncr53c96.sv:553`; only PIO lacked it.)*
   Data-in must move **exactly 1 byte per `$10`** and raise `I_BUS` (QEMU,
   MAME, and NetBSD's msg-in contract all agree; MSG IN via `$10` completes
   with `I_FC` instead) — `fill_fifo_from_buf`'s 16-byte handover
   (`ncr53c96.sv:403-419`) silently discards 15 bytes per command. Data-out
   via `$10` doesn't exist at all: FIFO bytes must drain into `sbuf`, `I_BUS`
   when the FIFO empties. Also stop consulting `tc_zero` on non-DMA commands
   (TC is untouched in PIO mode on every reference implementation), and zero
   the latched command at TI end (QEMU `cb22ce5038`).
9. **Write-path data loss.** Data-out only flushes at exactly
   `sbuf_pos == 512`; a transfer ending mid-sector drops the tail, and `drq`
   stays asserted on the boundary cycle so a back-to-back handshake can push
   byte 513 (`sbuf[256]` doesn't exist) and the `== 512` check never fires
   again. Flush partial sectors at TC-zero; make the boundary check `>= 512`
   or gate `drq` on `sbuf_pos < 512`.
10. **`$12` message accept** should also clear the FIFO count and seq (QEMU
    zeroes RSEQ+RFLAGS); keep raising `I_DISC`. `$11` ICCS is already close
    (status + `$00` message into FIFO, phase → MSG IN, `I_FC` only — QEMU
    `0ee71db4fc`).
11. **VIA2 IFR bit 0 (DREQ) must behave as a live level.** The ROM polls it
    (`$408D1988`, `$408D1FA8`) and never acknowledges it; QEMU patched mac_via
    specifically to present it live rather than latched. Our edge-detect
    follow (`iosb.sv:472-473`) is close, but verify an IFR write-1-to-clear
    can't wedge the bit low while DRQ is still asserted.

## P2 — hygiene / future-proofing

12. **INTR read side effects**: also clear seq-step (MAME clears; QEMU
    deliberately keeps it; the ROM never reads it — either is safe, don't
    clear phase or TC0). STATUS reads must stay side-effect-free (NetBSD polls
    it in tight loops).
13. **STATUS bit 3 is hardwired 1** (`ncr53c96.sv:124`) — no reference ever
    sets it; the ROM masks around it, but make it 0.
14. **TC latch semantics**: TC regs write a holding latch; ANY command with
    bit 7 loads the live counter and clears TC0 (`NOP|DMA` is NetBSD's
    documented latch idiom); 0 → 65536; TCL/TCM readable live mid-transfer
    (NetBSD's bus-error recovery reads them and panics on mismatch).
15. **`ce` gating asymmetry** between `dma_valid` (ungated) and the IOSB's
    `A_SDMA` consumer (ce-gated) — harmless in sim (`ce=1`), a hang on real
    ce. Align them.
16. *(LARGELY DONE 2026-09-01, and it was not NetBSD-only after all — A/UX
    3.1's own `c94` driver is the same shape; see
    [`aux-c94-driver.md`](aux-c94-driver.md).)* Non-ROM-driver features:
    FIFO-preloaded `$41`/`$42` (these already worked — `exec_command` masks
    the DMA bit off, so the bare and DMA forms share a case, and the FIFO
    drain feeds `cdb_byte`), `$43` SELATNS and `$46` SELATN3 (both used to
    return ILLEGAL COMMAND; now implemented, `$43` reporting seq-step 1 with
    MESSAGE OUT and answering an EXTENDED message with MESSAGE REJECT), and
    the seq-step duplicate in FIFO-flags bits 7:5. Still open: the
    reselection two-byte FIFO contract, and `$1A` SET ATN mid-transfer.
    `verilator/tb_ncr53c96.sv` covers both driver dialects.

17. **Do not flush the FIFO on a selection timeout.** *(FIXED 2026-09-01 —
    a real bug, but NOT the
    A/UX 3.1 boot failure -- see RESUME-aux-machine-id.md.)* A real 53C94 that selects nobody
    leaves the driver's preloaded bytes in the FIFO, because nothing went
    out. Both real drivers depend on that:
    - A/UX's `c94` records how many bytes it pushed (IDENTIFY + CDB) and, on
      the disconnect interrupt, compares it against FIFO-flags `& $1F`.
      Equal means "this SCSI ID is empty" -> `ret = 5`, *Cannot select SCSI
      device*, which is the expected answer for six of the seven IDs on
      every bus scan. Short means "the target answered and then vanished
      mid-command" -> `ret = 8`, ***Protocol Error Processing SCSI request***.
    - NetBSD makes the same test at select step 3: "the arbiter of did the
      CDB actually go out is the FIFO count"
      (`netbsd-ncr53c9x-expectations.md` 2.4).

    `ncr53c96.sv` did `fifo_cnt <= 0` there, so the count never matched,
    every empty ID reported a fatal protocol error, and A/UX condemned the
    bus — which is why even the disk it *could* talk to never completed a
    request. The ROM is untouched by this: its DMA-form select starts from
    an empty FIFO either way. Pinned by `tb_ncr53c96.sv` T7.

18. **Non-DMA `$10` TRANSFER INFO must flip the phase to STATUS on the
    target's last byte.** *(FIXED 2026-09-01 — validated against a QEMU
    master boot of this exact ROM+disk; this is the A/UX 3.1 boot failure.)*
    A/UX Startup's `saio` reaches the disk through the Mac ROM's SCSI
    Manager (`_SCSIDispatch`), which selects with the ROM's `$C1` DMA-select
    dialect — **not** the Unix `$42` (confirmed both ways: our hardware
    traces show only `$C1`, zero `$42`; QEMU's A/UX-Startup window shows 580
    `$C1`, zero `$42`, and the `$42` traffic is the already-loaded A/UX
    *kernel* after handoff). The ROM SCSI Manager reads bulk data as `$90`
    DMA chunks, but handles the unaligned tail of a transfer (INQUIRY = 36 =
    16+16+4, disklabels, partition entries) one byte at a time with non-DMA
    `$10` TI. On the byte that empties the SCSI request, real silicon — and
    QEMU `esp_command_complete` — flips the phase to STATUS and leaves that
    last byte in the FIFO for the initiator to read *after* it sees the
    phase change (`esp.c`: "Non-DMA transfers from the target will leave the
    last byte in the FIFO").

    Our `arm_pio_in` pushed the byte and raised BS but **left the phase at
    DATA IN**. The ROM's original-API `SCSIComplete` ends its byte loop by
    count and then polls `STATUS` for the phase to leave DATA IN; it never
    did, so the ROM spun its calibrated `TimeSCSIDB` wait (~7 s) and
    returned `ret = 8` *Protocol Error Processing SCSI request* → `$03` bus
    reset → retry → give up. **Fix:** on the `$10` handshake that pushes the
    last byte (`sbuf_pos == sbuf_len-1 && blocks_left == 0`), set phase
    STATUS as BS is raised, byte still in the FIFO. Mid-tail `$10`s
    (`sbuf_pos <` last) keep phase DATA IN, exactly like QEMU's
    `reg[4]=0x91`. Pinned by `tb_ncr53c96.sv` T11.

    The `$90` bulk-read completion was **already correct** and needed no
    change: QEMU always drains a chunk fully on DRQ (`lower_drq` at
    `fifo<2`) and only *then* raises the chunk/completion interrupt, so the
    completion never arrives with data in the FIFO. `tb_ncr53c96.sv` T10
    (16-byte ROM chunks) and T12 (saio's 256-byte chunks) both transcribe
    QEMU's exact byte stream and confirm the existing `tc_zero && fifo_cnt <
    2` arm matches.

    Corollary found by T11's tight timing: the "source exhausted"
    predicates (the underflow arm, the completion arm, and the `arm_pio_in`
    underflow) must treat `synth_on` — the synthesized-response sequencer
    still streaming INQUIRY/SENSE/MODE/CAPACITY bytes into the buffer — as
    "data in flight", exactly like `io_busy` for a sector. A driver issuing
    TI within a few cycles of the select interrupt otherwise sees the data
    phase close before the response exists. Real buses are too slow to hit
    it today; the tb is not.

    **A dead end that cost a build, recorded so it is not retried.** The
    first cut mis-read the epoch-deduped hardware trace as a "$90 final
    chunk, INT-before-drain" deadlock and added a second completion arm that
    fired with a full FIFO (`fifo_cnt >= 2`), plus a `drain_tail` register to
    hold DREQ through the undrained tail. That scenario **does not occur** —
    QEMU never completes with data in the FIFO — and the early arm cleared
    `xfer_in` with 16 bytes still pending, dropping DREQ (VIA2 IFR bit 0,
    item 11) mid-burst so the ROM abandoned the read and the boot scan
    flashed `?`. Both the arm and `drain_tail` were reverted once the QEMU
    trace showed the real `$10` mechanism; the lesson is to diff against the
    QEMU golden trace, not to theorise from the lossy first-sighting stream.

## Verification hooks

- The boot block's `C` checksum row (expected `C=862D7F48` on the 2026-08-28b
  all-in-one) is the free data-path oracle: `A/D/E` painting with `C` wrong =
  byte order/data path; nothing painting = control path.
- Diskless boot to the flashing-`?` at `$408014CA` (~420M cycles fastboot) is
  the regression floor — any select-path change must keep it.
- Expected hang signatures: PC parked on `$50F101xx`/`$50F501xx` = hold-off
  wedge (P0-2/P1-7); spin at `$408D1FA2-FB2` = DREQ/FIFO-flags gating (P0-3);
  spin in `$408D2436` phase wait = select left the wrong phase (P0-1).
