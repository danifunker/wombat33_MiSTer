# A/UX 3.1's `c94` SCSI driver — what it actually does to the chip

> **This driver is not what fails today.** It is the *kernel's* driver, and the
> boot dies in `A/UX Startup` — a Mac application that drives the disk through
> the ROM's SCSI Manager and never touches the 53C96 — long before any kernel
> is launched. See [`aux-startup-boot-path.md`](aux-startup-boot-path.md).
> Everything below stays correct and stays needed for when the kernel does run;
> only §5's framing of "the boot died here" is superseded.

Disassembled from the shipped kernel inside
`HD60_512-AUX3.1-Installed.hda` on 2026-09-01, while chasing

```
Disk c0d0s0 Error: Protocol Error Processing SCSI request
generic disk c0d0s0 Retry limit: Logical block 0, physical block 0
```

Unlike the rest of `docs/scsi/`, this is not oracle-mining from another
emulator — it is the actual driver that fails on our hardware, read
instruction by instruction. Where NetBSD's `ncr53c9x` was a *proxy* for
"what a Unix driver expects", this is the real thing.

---

## 1. Finding it

There are **four** COFF kernels on the disk — `/unix` (5905 symbols, and the
one `/nextunix` names), `/newunix` (6035), `/etc/config.d/newunix` (3942),
and a stale copy in free space at `0x1B4AC000` (5805). They are different
builds. `/unix` is the one to read. (There is no "A/UX Startup standalone
kernel": that application is a Mac program driving the ROM's SCSI Manager —
see [`aux-startup-boot-path.md`](aux-startup-boot-path.md).)

Its SCSI stack is Apple's, in five modules, each with its SCCS stamp in
`.data`:

| module | version |
|---|---|
| `scsidma.c` | Apple 2.6, 92/11/11 |
| `scsifsm.c` | Apple 2.12, 91/08/01 |
| `scsireq.c` | Apple 2.10, 91/10/02 |
| `scsitask.c` | Apple 2.12, 91/12/06 |
| `scsitrace.c` | Apple 2.5, 91/05/14 |

plus a chip-specific layer whose trace strings all start `c94` —
`c94_cancel`, `c94resel..->c94_iafterresel`. That is the NCR 53C94/53C96
driver, and it is what talks to `rtl/ncr53c96.sv`.

`scsifsm.c` carries its state names as strings, which is the fastest map
of the driver you will get:

```
inputs   SI_FSEL SI_SEL SI_RESET SI_PHASE SI_PARITY SI_FREE SI_UNK
         SI_NEWTASK SI_DONE SI_ABT SI_BSY SI_DMA SI_EOP SI_DMAWDOG SI_WAITP
states   SG_IDLE SG_CHOOSE SG_RUN SG_WPHASE SG_WRECON SG_WBUS SG_WRESET
         SG_ABORTJ SG_RESET SG_NOTIFY SG_DMA SG_EOP SG_PANIC
phases   SP_SEL SP_IDNT SP_CMD SP_DATA SP_STAT SP_ABT
```

**Reproducing the disassembly.** Do not carve raw regions out of the image
and hand-derive a VMA↔disk delta — that is how the address citations in the
first version of this document ended up wrong (see the box below). Extract
the file and read its symbol table instead:

```sh
python3 scripts/aux_ufs.py IMG cat /unix unix.bin      # /nextunix says /unix boots
python3 scripts/aux_coff.py unix.bin syms 'c94|scsi'   # 5905 symbols, all named
python3 scripts/aux_dis.py  unix.bin c94_select        # symbol-annotated disasm
```

Sections are `.text` at VMA `0x10000000`, `.data` at `0x11000000`, `.bss` at
`0x12000000`, plus a `pstart` bring-up section at `0x54000`.

> **Address correction, 2026-09-01.** The `$1004xxxx` VMAs cited throughout
> the original version of this document came from one of the *other* kernel
> copies on the disk (there are four, and they are different builds), so
> none of them land on a function boundary in `/unix` — the kernel that
> actually boots — and no single constant relates them. **Every code
> description below was re-verified against `/unix` by searching for the
> instruction sequences themselves**, and the headings now carry the symbol
> names, which is what to search for. The findings were all correct; only
> the addresses were mislabelled. The one address that was right is the
> `scsireq.c` error-string table at `.data` VMA `0x1100C826` — 15 pointers
> terminated by `$FFFFFFFF`, with the strings starting at `0x1100C87A`.

---

## 2. The register map it uses

16-byte strides, exactly as `rtl/iosb.sv` decodes (`rs = addr[7:4]`):

| offset | reg | use |
|---|---|---|
| `$00`/`$10` | 0,1 | transfer counter, read back as `TCL + (TCM<<8)` |
| `$20` | 2 | FIFO |
| `$30` | 3 | command |
| `$40` | 4 | STATUS (read) / SELID (write) |
| `$50` | 5 | INTR (read) / sel-resel timeout (write) |
| `$60` | 6 | sequence step — **read, masked `& $0F`** |
| `$70` | 7 | FIFO flags — **read, masked `& $1F`** |
| `$80` | 8 | CONFIG1 |
| `$90` | 9 | clock conversion |
| `$B0`/`$C0` | B,C | CONFIG2, CONFIG3 |

Chip setup (**`c94_initchip`**, `$10051534`): clock conversion and timeout
come from a table keyed on the bus clock, then the three CONFIG writes at
`$100515CC`:

```
CONFIG1 = $47        ; DISR set (no interrupt on SCSI reset), host ID 7
CONFIG2 = $00
CONFIG3 = $04
```

Note `CONFIG1` bit 6: `rtl/ncr53c96.sv` already gates the `$03` bus-reset
interrupt on `conf1[6]`, which is correct for this driver.

## 3. The select sequence (**`c94_select`**, `$10051602`)

```
    move.b  #$1, ($30,A5)     ; FLUSH FIFO
    move.b  #$c0, ($20,A5)    ; FIFO <- IDENTIFY, LUN 0, DISCONNECT OK
    move.l  D0, ($20,A3)      ; task->nfifo = cdblen + 1     <<< remember this
    move.b  (A4)+, ($20,A5)   ; FIFO <- CDB, byte at a time
    ...
    move.b  ($1f,A2), ($40,A5); SELID <- target
    move.l  ($10,A6), ($10,A2); softc->handler = continuation
    move.w  #$4, ($1c,A2)     ; softc->state
    move.b  #$42, ($30,A5)    ; SELATN     (or $41 SELNATN, no IDENTIFY)
```

**This is the FIFO-preloaded form, and only `$42`/`$41` are ever used.**
A whole-image scan for `move.b #imm,$30(An)` finds `$01 $90 $10 $1A $12
$03 $42 $41` and no others; `$43` SELATNS and `$46` SELATN3 appear
nowhere. (The model implements them anyway — NetBSD needs them, and
`rtl-gap-analysis.md` item 16 asks for them — but they are not what A/UX
does.)

Everything above is byte-sized `move.b`, all at 16-byte-aligned
addresses, so every access lands in the same byte lane the ROM uses.

## 4. The interrupt handler (**`c94_intr`**, `$10051046`)

```
    btst    #$7, ($40,A2)     ; STATUS bit 7 = INT?  (mirrors IRQ)
    move.b  ($40,A2), ($27,A3); save STATUS
    moveq   #$f, D0
    and.b   ($60,A2), D0      ; save SEQUENCE STEP
    move.b  ($50,A2), ($26,A3); read INTR *LAST* — it clears
```

Same read order NetBSD documents as "a hard chip expectation"
(`netbsd-ncr53c9x-expectations.md` §2.2): STATUS, STEP, INTR last. A
core must keep STATUS and STEP valid until INTR is read, and must not
let a STATUS read have side effects.

## 5. The select-completion handler — and the bug it exposed

**`c94_iselect`**, `$10050C86`; the test below is at `$10050CD0`.

```
    btst    #$2, ($26,A2)     ; RESEL?     -> reselection path
    btst    #$5, ($26,A2)     ; DISC?      -> selection timed out:
        move.b  ($70,A5), D0
        andi.l  #$1f, D0      ;   FIFO count
        cmp.l   ($20,A3), D0  ;   == the bytes we preloaded?
        beq     -> ret = 5    ;   yes: "Cannot select SCSI device"
                -> ret = 8    ;   no:  "Protocol Error Processing SCSI request"
    move.b  ($26,A2), D0
    andi.l  #$18, D0
    cmpi.l  #$18, D0          ; BS *and* FC both set?
    bne     -> ret = 8        ;   "Protocol Error Processing SCSI request"
    -> dophase()
```

**The selection-timeout branch is the one that mattered.** A real 53C94
that selects nobody leaves the preloaded bytes sitting in the FIFO —
nothing went out, because nothing answered. A/UX uses exactly that to
tell "this SCSI ID is empty" (benign, and the expected result for six of
seven IDs on every bus scan) from "the target answered and then vanished
mid-command" (a genuine bus fault).

`rtl/ncr53c96.sv` used to do `fifo_cnt <= 0` on the selection-timeout
path, so the count always read 0 and never matched. Fixed 2026-09-01;
`verilator/tb_ncr53c96.sv` T7 pins it.

**This was NOT the A/UX boot failure**, though it looked like it at first.
`ret = 8` is A/UX's *catch-all default* — see §7 — so the message it
produces says nothing about which path failed. Hardware tracing later
showed A/UX never issues a select at all, so it never reaches this code.
See `RESUME-aux-machine-id.md`. The fix is still correct and still worth
having: both this driver and NetBSD lean on that FIFO count.

NetBSD leans on the same FIFO count at select step 3 — "the arbiter of
did the CDB actually go out is the FIFO count"
(`netbsd-ncr53c9x-expectations.md` §2.4). Two independent drivers, same
assumption: **do not flush the FIFO out from under the driver.**

## 6. `dophase` — the phase jump table (**`c94_phase`**, `$1004FC64`)

`STATUS & 7` indexes a word table; the accepted phases are:

| phase | handled? |
|---|---|
| 0 DATA OUT | yes |
| 1 DATA IN | yes |
| 2 COMMAND | **no — hard error** |
| 3 STATUS | yes |
| 4, 5 | reserved — hard error |
| 6 MESSAGE OUT | yes |
| 7 MESSAGE IN | yes |

So the phase the chip publishes at the select-complete interrupt must
already be the command's *data or status* phase. Our model's deferred
select interrupt (raise `I_BUS|I_FC` only once the CDB has run, with the
new phase visible) is exactly right for this; publishing COMMAND phase
there would be fatal.

## 7. Error codes

`scsireq.c`'s message table is at VMA `$1100C826` and is indexed
**0-based** by `req->ret` (`$27` off the request; `$26` is `stat`).
Pinned by the CHECK CONDITION path, which does
`if (stat == 2) ret = $0B` — and `table[$0B]` is "SCSI extended status
returned".

| ret | message |
|---|---|
| 0 | SCSI driver implementation error |
| 1 | SCSI bus dropped busy |
| 2 | Error during SCSI command |
| 3 | Error during SCSI status |
| 4 | Error during SCSI sense command |
| 5 | Cannot select SCSI device |
| 6 | SCSI timeout |
| 7 | id already has active request |
| **8** | **Protocol Error Processing SCSI request** — the DEFAULT, see below |
| 9 | More data than SCSI device requested |
| 10 | Less data than SCSI device requested |
| 11 | SCSI extended status returned |
| 12 | SCSI Retry required |
| 13 | Caller or Scsi Manager out-of-date |
| 14 | Cancelled by Scsican |

`ret = 8` is written at two sites in the select handler (§5) — **and, far
more importantly, as a DEFAULT by the generic failure routine**
(`doabort + $66`, `$1004B6CC`; `scsitask + $1D0` carries a second copy for
the I/O-wait timeout):

```
    tst.b  ([A3],$27)        ; req->ret already set by a specific path?
    bne    keep
    move.b #$8, ([A3],$27)   ; else ret = 8
```

So "Protocol Error Processing SCSI request" is what A/UX prints whenever a
request fails and nothing set a more specific code. It is emitted by
*every* such path, including ones that never touch hardware. Do not read it
as a diagnosis of the SCSI protocol — that mistake cost a whole session.

## 8. What to look at next

The parts of this driver our model has not been through yet:

- **`scsidma.c` PDMA with bus-error flow control** — the strings are
  `start dma` / `scsiin buserr` / `scsiout buserr` / `write finish`, i.e.
  it runs raw bursts and expects the bus error to stop them, the same
  mechanism `rtl-gap-analysis.md` item 7 describes. `rtl/iosb.sv`'s
  `sdma_fault` timeout is the thing that has to catch this.
- **Disconnect and reselect.** A/UX sends IDENTIFY `$C0` — the
  disconnect-privilege bit is SET, and there is a full `c94resel`
  path. Our target never disconnects, which is legal, but it means the
  reselection contract (two FIFO bytes, §2.5 of the NetBSD notes) is
  still unexercised.
- **`$1A` SET ATN** is issued from 27 sites. The model treats it as a
  no-op; a driver that asserts ATN mid-transfer expects the target to
  move to MESSAGE OUT.
- **LUN.** The model answers every LUN. A/UX has a
  "Lun %d does not match expected %d" check, so a probe that walks LUNs
  will find eight copies of the same disk.
