# Macintosh Quadra 800 — Hardware Configuration & MAME Implementation

A reference for the Apple Macintosh Quadra 800 covering its data-bus layout, CPU
cache, real-hardware vs. MAME differences, support-chip architecture, the **major
architectural changes** versus the V8/VASP-based 68030 Macs, a compatible NuBus-card
subset (unchanged from the IIvi sheet), serial/modem/PPP options, and the
interrupt/VIA register map.

MAME references are to the `macqd800` machine in `src/mame/apple/macquadra800.cpp` and
the two big ASIC devices `src/mame/apple/djmemc.cpp` (memory + DAFB video) and
`src/mame/apple/iosb.cpp` (I/O), plus `src/mame/apple/dafb.cpp`,
`src/devices/machine/dp83932c.cpp` (SONIC Ethernet), `src/devices/machine/ncr53c90.cpp`
(SCSI), `src/devices/machine/pseudovia.cpp`, and the NuBus / RS-232 infrastructure.
Line numbers reflect the tree at time of writing.

> **The Quadra 800 in one sentence:** a full **32-bit 68040 @ 33 MHz** built around
> **two** ASICs — **djMEMC** (memory controller + DAFB II video) and **IOSB** (all
> other I/O) — with a **flat 32-bit memory bus** (no 16-bit narrowing), **built-in
> SONIC Ethernet**, faster **NCR 53C96** SCSI, and the 68040's big on-chip caches.
> This is a genuinely different machine from the LC/IIvi, not a V8 derivative.

The `macquadra800.cpp` driver covers five machines (`macquadra800.cpp:353-357`); the
Quadra 800 (`macqd800`) is the lead config:

| Machine | CPU | Clock | FPU (full 040?) |
|---|---|---|---|
| **Quadra 800** (this doc) | **M68040** | **33 MHz** | yes | 
| Quadra 650 | M68040 | 33 MHz | yes |
| Quadra 610 | M68040 | 25 MHz | yes |
| Centris 650 | M68**LC**040 | 25 MHz | no FPU |
| Centris 610 | M68**LC**040 | 20 MHz | no FPU |

(`macquadra800.cpp:282-327`. The `LC` parts lack the on-chip FPU.)

---

## Table of Contents

1. [Major architectural changes vs. the V8/VASP family](#1-major-architectural-changes-vs-the-v8vasp-family)
2. [Data-bus specifications (MAME-configured)](#2-data-bus-specifications-mame-configured)
3. [Data-bus specifications (actual hardware)](#3-data-bus-specifications-actual-hardware)
4. [CPU cache](#4-cpu-cache)
5. [The two ASICs: djMEMC and IOSB](#5-the-two-asics-djmemc-and-iosb)
6. [Memory map](#6-memory-map)
7. [Compatible NuBus cards (curated subset — unchanged)](#7-compatible-nubus-cards-curated-subset--unchanged)
8. [Serial ports, modems, and PPP](#8-serial-ports-modems-and-ppp)
9. [Interrupt map (68k levels)](#9-interrupt-map-68k-levels)
10. [VIA1 and VIA2 register maps](#10-via1-and-via2-register-maps)
11. [MAME-implementation notes](#11-mame-implementation-notes)

---

## 1. Major architectural changes vs. the V8/VASP family

This is the section to read first if you know the LC/IIvi cores. The Quadra 800 is
*architecturally* different, not just faster:

| # | Change | LC / IIvi (V8/VASP) | Quadra 800 | Source |
|---|---|---|---|---|
| 1 | **Memory bus width** | **16-bit** narrowed path (the "Road Apple" bottleneck) | **Full 32-bit**, no narrowing | `dafb.cpp:915-933` vs `v8.cpp:15` |
| 2 | **CPU** | 68020 (HMMU) / 68030, ≤16 MHz | **68040 @ 33 MHz** (on-chip FPU + MMU + 8 KB cache) | `macquadra800.cpp:179` |
| 3 | **Chip topology** | one mega-ASIC (V8/VASP) does *everything* | **two ASICs**: djMEMC (mem+video) + IOSB (I/O) | `macquadra800.cpp:158-159` |
| 4 | **Address decode** | tiny 24-bit window, `global_mask(0x80ffffff)` | **flat 32-bit**: `map(0x0,0xffffffff)` | `macquadra800.cpp:158` vs `maclc.cpp:181` |
| 5 | **Video** | V8/VASP framebuffer + Ariel RAMDAC, 16-bit VRAM | **DAFB II** (DP8534 + AC842a DAC), 32-bit VRAM | `djmemc.cpp:40`, `dafb.cpp` |
| 6 | **Networking** | none | **built-in DP83932 SONIC Ethernet**, true bus-master DMA | `macquadra800.cpp:240-242` |
| 7 | **SCSI** | NCR 5380 + software SCSI-helper pseudo-DMA | **NCR 53C96** + IOSB hardware "Turbo SCSI" (longword) | `macquadra800.cpp:234`, `iosb.cpp:58-59` |
| 8 | **VIA2** | RBV-style pseudo-VIA (no VIA core) | **`quadra_pseudovia`** — a real-ish VIA core, timers disabled | `iosb.cpp:83`, `pseudovia.cpp:44` |
| 9 | **ADB / power** | **Egret** microcontroller | **GI/Microchip "ADB modem" + real VIA** (pre-Egret style) | `macquadra800.cpp:254-258` |
| 10 | **RTC / PRAM** | inside Egret | discrete **RTC3430042**, bit-banged over VIA1 | `iosb.cpp:106-107` |
| 11 | **Floppy** | SWIM1 | **SWIM2** | `iosb.cpp:94` |
| 12 | **Sound** | ASC_V8 | **EASC** (Enhanced ASC) | `iosb.cpp:89` |
| 13 | **RAM** | 30-pin SIMMs in pairs, ≤10–68 MB | **72-pin SIMMs**, 8 MB → 136 MB (real) | `macquadra800.cpp:266-268` |
| 14 | **NuBus mode** | `NORMAL` (IIvi) / `LC_PDS` (LC) | **`QUADRA_DAFB`** | `macquadra800.cpp:246` |

**What stayed the same:** the **3-level autovector interrupt scheme** (SCC=4,
VIA2=2, VIA1=1; `iosb.cpp:282-310`), ASC-family audio, the classic ROM/RAM **boot
overlay** (`djmemc.cpp:83-112`), the **DFAC** audio filter, the **SCC 85C30** serial
chip, three NuBus slots ($C/$D/$E), and the DFAC-over-GPIO sound-volume trick.

The single most important takeaway: **the V8/VASP 16-bit memory bottleneck is gone.**
On the LC/IIvi the 32-bit CPU was throttled to a 16-bit memory path; the Quadra 800
runs a true 32-bit bus, so RAM, ROM, VRAM, and NuBus all move 32 bits at a time.

---

## 2. Data-bus specifications (MAME-configured)

The CPU is a full 32-bit 68040. **djMEMC** decodes the whole 4 GB space and owns
memory + video; **IOSB** owns the `0x5xxxxxxx` I/O block; a few fast devices (SONIC,
SCC) are wired straight into the CPU map alongside IOSB.

| Component | MAME handler width | CPU address | Source |
|---|---|---|---|
| CPU — M68040 @ 33 MHz | **32-bit** | whole 4 GB | `macquadra800.cpp:179` |
| djMEMC (memory + video) | decoder | `0x00000000–0xFFFFFFFF` | `macquadra800.cpp:158` |
| RAM (DRAM) | **32-bit** (`u32*`) | `0x00000000` | `macquadra800.cpp:110`, `djmemc.cpp:107` |
| ROM | **32-bit** (`ROM_REGION32_BE`, 1 MB) | `0x40000000` (+ overlay at `0`) | `djmemc.cpp:29`, `macquadra800.cpp:339` |
| VRAM (DAFB) | **32-bit** (`u32[]`, 1 MB) | `0xF9000000–0xF91FFFFF` | `djmemc.cpp:30`, `dafb.cpp:915-933` |
| DAFB registers | 32-bit | `0xF9800000–0xF98003FF` | `djmemc.cpp:31` |
| IOSB (I/O block) | sub-map | `0x50000000–0x5FFFFFFF` | `macquadra800.cpp:159` |
| VIA1 (65C22) | **16-bit** wrapper / 8-bit core | `0x50000000` | `iosb.cpp:56` |
| VIA2 (quadra pseudo-VIA) | **8-bit** | `0x50002000` | `iosb.cpp:57` |
| Turbo SCSI registers | **8-bit** | `0x50010000` | `iosb.cpp:58` |
| Turbo SCSI pseudo-DMA | **32-bit** | `0x50010100` | `iosb.cpp:59` |
| ASC (EASC) sound | 8-bit | `0x50014000` | `iosb.cpp:60` |
| IOSB config registers | **16-bit** | `0x50018000` | `iosb.cpp:61` |
| SWIM2 (floppy) | **16-bit** | `0x5001E000` | `iosb.cpp:62` |
| SONIC Ethernet | **16-bit** (`umask32 0x0000ffff`) | `0x5000A000` (regs), `0x50008000` (MAC PROM) | `macquadra800.cpp:161-162` |
| SCC (85C30 serial) | **16-bit** wrapper / 8-bit core | `0x5000C000` | `macquadra800.cpp:163` |
| NuBus slots $C/$D/$E | 32-bit (card-defined) | super `0xC/D/E0000000`, slot `0xFC/FD/FE000000` | `macquadra800.cpp:244-252` |

Note the legacy I/O chips (VIA1/VIA2, SCC, SWIM2, SONIC, SCSI, ASC) are still 8- or
16-bit — but that's because those *parts* are genuinely narrow, exactly as on every
Mac. The difference from the LC/IIvi is the **memory side** (RAM/ROM/VRAM/NuBus),
which here is full 32-bit.

---

## 3. Data-bus specifications (actual hardware)

| Component | Real data-bus width | Notes |
|---|---|---|
| CPU — MC68040 @ 33 MHz | **32-bit** | On-chip FPU (full 040), on-chip paged MMU, 8 KB copyback cache. No external narrowing. |
| System / memory bus | **32-bit** | djMEMC drives a true 32-bit memory bus — the headline change from V8/VASP. |
| RAM — 8 MB onboard + 72-pin SIMMs | **32-bit** | 60 ns 72-pin SIMMs (32-bit wide each). 8 MB std → **136 MB** max (real). djMEMC itself supports far more. |
| ROM (1 MB) | **32-bit** | `ROM_REGION32_BE`. |
| VRAM (built-in DAFB) | **32-bit** | 512 KB or 1 MB; MAME fixes 1 MB. |
| djMEMC ASIC | **32-bit** | Memory controller + DAFB II video + ROM/RAM overlay. |
| IOSB ASIC | mixed | Bridges the CPU to the legacy 8/16-bit I/O chips it integrates. |
| VIA1 (65C22) | **8-bit** | Real 6522. |
| VIA2 (quadra pseudo-VIA) | **8-bit** | VIA-like core inside IOSB (no timers/SR). |
| SCC (Zilog 85C30) | **8-bit** | Serial. |
| SCSI (NCR 53C96) | **8-bit host / 16-bit DMA** | `BUSMD_1`; IOSB "Turbo SCSI" does longword pseudo-DMA. |
| SWIM2 (floppy) | **8-bit** | |
| EASC (sound) | **8-bit** | Enhanced Apple Sound Chip. |
| SONIC (DP83932) Ethernet | **16/32-bit bus master** | True DMA into main RAM (`DCR_DW` selects width). |
| NuBus (3 slots) | **32-bit** | `QUADRA_DAFB` addressing. |

### How this differs from the LC/IIvi tables

On the LC/IIvi, the "actual hardware" column was dominated by **16-bit** (CPU external
path, RAM, ROM, VRAM all narrowed by V8/VASP). Here that column is **32-bit** across
the board for memory and video. The narrow entries that remain (VIA/SCC/SCSI/SWIM/ASC)
are just the inherently 8-bit legacy I/O parts — present on *every* Mac and not a bus
compromise. **MAME models all of this at native width**, so unlike the LC/IIvi there
is essentially no "MAME is wider than the real bus" caveat for the Quadra 800.

**Sources:** [EveryMac — Quadra 800](https://everymac.com/systems/apple/mac_quadra/specs/mac_quadra_800.html),
[Wikipedia — Quadra 800](https://en.wikipedia.org/wiki/Macintosh_Quadra_800),
[Wikipedia — Motorola 68040](https://en.wikipedia.org/wiki/Motorola_68040).

---

## 4. CPU cache

A large jump from the 68030 in the IIvi:

- **L1 (on-chip 68040):** **4 KB instruction + 4 KB data = 8 KB total** — 16× the
  68030's 256 + 256 bytes.
- **CopyBack (write-back) mode:** the 68040 caches can run in copyback mode (vs the
  68020/030 write-through), so repeated writes hit the cache before flushing — Motorola
  cites up to ~50% gain, and ~3× the per-clock performance of a 68030.
- **On-chip FPU and MMU:** the full **M68040** (Quadra 800) integrates the FPU and a
  paged MMU on-die — no external 68882/68851. (The **68LC040** in the Centris 610/650
  drops the FPU; the Quadra 800 uses the full part, `macquadra800.cpp:179`.)
- **No L2 cache:** the Quadra 800 has no board-level L2 — the 68040's 8 KB on-chip
  cache made it unnecessary (contrast the IIvx, which needed a 32 KB L2 to paper over
  its 16-bit bus).
- **MAME** models the 68040 (caches/FPU/MMU) functionally via the Musashi core
  (`m68000_musashi_device`, `macquadra800.cpp:80`); there is no L2 to model.

---

## 5. The two ASICs: djMEMC and IOSB

### djMEMC — memory controller + DAFB II video (`djmemc.cpp`)

- **Role** (`djmemc.cpp:6-11`): memory controller for up to 640 MiB (10 banks × 64
  MiB), the ROM/RAM boot overlay, and **DAFB II** video (minus Turbo SCSI, which moved
  to IOSB). Instantiated at `macquadra800.cpp:183`, fed the CPU tag and ROM region
  (`:184-185`), VBL IRQ → IOSB VIA2 mask 0x40 (`:186`).
- **Map** (`djmemc.cpp:27-32`, all 32-bit): ROM switch `0x40000000` (mirror
  `0x0ff00000`), DAFB VRAM `0xF9000000–0xF91FFFFF`, DAFB regs `0xF9800000`.
- **Boot overlay** (`djmemc.cpp:83-112`): ROM mirrored at `0` on reset; first ROM
  fetch swaps RAM in at `0`. Same idea as V8/VASP, but on a **32-bit** RAM pointer
  (`set_ram_info(m_ram->pointer<u32>() …)`, `macquadra800.cpp:110`).
- **DAFB** (`dafb.cpp`): "Direct Access Frame Buffer," DP8534 timing generator + AC842a
  DAC, version 3 (`dafb.cpp:1182`). VRAM is a `u32[]`, fixed at **1 MB** for the MEMC
  variant (`dafb.cpp:1181`), 32-bit handlers with `COMBINE_DATA` (`dafb.cpp:915-933`).
  Internal register map splits DAFB regs / Swatch CRTC / RAMDAC / clock generator
  (`dafb.cpp:73-79`).

### IOSB — I/O Subsystem Buffer (`iosb.cpp`)

- **Role** (`iosb.cpp:3-24`): integrates **VIA1** (real 6522), **VIA2** (quadra
  pseudo-VIA), **SWIM2** floppy, **EASC** audio, the **Turbo SCSI** block, and glue for
  ADB/SCC/SONIC. The comment notes it's "similar to Sonora but replaces the
  RBV/V8/VASP/Sonora pseudo-VIA with a real VIA core that has the timers disabled."
  Instantiated at `macquadra800.cpp:188`.
- **Map** (`iosb.cpp:54-66`, offsets relative to `0x50000000`): VIA1 `0x0000` (16-bit),
  VIA2 `0x2000` (8-bit), Turbo SCSI regs `0x10000` (8-bit), Turbo SCSI DMA `0x10100`
  (32-bit), ASC `0x14000`, IOSB config regs `0x18000` (16-bit), SWIM2 `0x1E000`
  (16-bit), and a fixed ID `0xA55A2BAD` ("2BAD") at `0x0FFF0000`.
- **Turbo SCSI** (`iosb.cpp:58-59`, handlers `498-617`): hardware pseudo-DMA. Still
  CPU-driven, but assembles **longwords** and inserts programmable wait-states; when
  DRQ isn't ready it emulates the chip holding off /DTACK via
  `restart_this_instruction()` + `spin_until_time()`. Faster than the LC/IIvi's
  software SCSI-helper, but **not** a real DMA engine.
- **Machine ID** comes from four VIA port-A pins set by the driver (Quadra 800 = 0x12,
  `macquadra800.cpp:193-197`).

> **Note — no general DMA "PSC".** The Quadra 800 has *no* central DMA controller. SCSI
> uses IOSB Turbo-SCSI (CPU-driven pseudo-DMA); the one true bus-master DMA is the
> **SONIC** Ethernet chip (`set_bus(m_maincpu, 0)`, `macquadra800.cpp:241`). The PSC +
> DSP DMA architecture belongs to the later 660AV/840AV, not this machine.

---

## 6. Memory map

CPU-side addresses (after the boot overlay clears):

| Range | Contents |
|---|---|
| `0x00000000–…` | RAM (overlaid by ROM at reset) — **32-bit** |
| `0x40000000–0x4FFFFFFF` | ROM (1 MB image, mirrored) |
| `0x50000000` | VIA1 (IOSB) |
| `0x50002000` | VIA2 (IOSB, quadra pseudo-VIA) |
| `0x50008000` | Ethernet MAC-address PROM |
| `0x5000A000–0x5000B0FF` | SONIC Ethernet registers |
| `0x5000C000–0x5000DFFF` | SCC (channel A = modem, B = printer) |
| `0x50010000` | Turbo SCSI registers (NCR 53C96) |
| `0x50010100` | Turbo SCSI pseudo-DMA (longword) |
| `0x50014000` | ASC / EASC (sound) |
| `0x50018000` | IOSB configuration registers |
| `0x5001E000` | SWIM2 (floppy) |
| `0x50FFF000` | IOSB ID = `0xA55A2BAD` |
| `0xC/D/E0000000` | NuBus super-slot space ($C/$D/$E) |
| `0xF9000000–0xF91FFFFF` | DAFB VRAM |
| `0xF9800000–0xF98003FF` | DAFB registers |
| `0xFC/FD/FE000000` | NuBus slot space ($C/$D/$E) |

Most IOSB I/O is mirrored (`.mirror(0x00fc0000)` / `0x00f00000`).

---

## 7. Compatible NuBus cards (curated subset — unchanged)

Per request, the NuBus listing is **identical to the IIvi sheet** — the Quadra 800
exposes its three slots ($C/$D/$E) with the same `mac_nubus_cards` option list
(`macquadra800.cpp:250-252`):

| Card | MAME option | Device | What it's for |
|---|---|---|---|
| **Apple Macintosh Display Card 8•24 (MDC 1.2)** | `mdc824` | `NUBUS_MDC824` | Up to 24-bit color at 640×480, 8-bit at higher res. |
| Apple Macintosh Display Card 4•8 | `mdc48` | `NUBUS_MDC48` | Same hardware, 512 KB VRAM, 8-bit max. |
| **Apple NuBus Ethernet** | `enetnb` | `NUBUS_APPLEENET` | 10 Mbps Ethernet (DP8390/NE2000-style). |
| Apple Ethernet NB Twisted-Pair | `enetnbtp` | `NUBUS_ENETNBTP` | 10BASE-T (SONIC-based). |
| Asanté MC3NB Ethernet | `asmc3nb` | `NUBUS_ASNTMC3NB` | Popular 3rd-party Ethernet. |
| AE QuadraLink serial | `quadralink` | `NUBUS_QUADRALINK` | Four extra serial ports. |
| Brigent BootBug | `bootbug` | `NUBUS_BOOTBUG` | Debugger card. |
| Disk Image pseudo-card | `image` | `NUBUS_IMAGE` | MAME-only: mounts a host disk image over NuBus. |

```
mame macqd800 -nbc mdc824        # add a color display card in slot $C
```

> **Caveat specific to this machine:** the Quadra 800 already has **built-in DAFB
> video** and **built-in SONIC Ethernet**, so the MDC video card and the NuBus Ethernet
> cards are *redundant* here (useful for a second display or a second NIC, but not
> required). They remain in the list for parity with the IIvi sheet, as requested. For
> the connection deep-dives on the MDC 8•24 and the Ethernet cards, see
> **MacIIvi_HardwareConfig.md §7** — the cards behave identically on this bus.

---

## 8. Serial ports, modems, and PPP

The serial subsystem is the same as the IIvi (Zilog **Z85C30** SCC, two channels,
`SCC85C30(config, m_scc, C7M)`, `macquadra800.cpp:204`):

| SCC channel | MAME RS-232 slot | Real-Mac port | Wiring |
|---|---|---|---|
| A | `modem` | Modem port (DIN-8) | `out_txda → "modem"` (`macquadra800.cpp:207, 210-213`) |
| B | `printer` | Printer/LocalTalk port | `out_txdb → "printer"` (`macquadra800.cpp:208, 215-218`) |

(Here the SCC is wired straight into the CPU map at `0x5000C000` rather than through the
I/O ASIC; its handlers call `m_iosb->via_sync()` before touching the chip,
`macquadra800.cpp:163`.)

Both slots accept any option from `default_rs232_devices`. For modem/PPP use the
**`modem`** slot (SCC channel A). The options and the PPP story are identical to the
IIvi:

- **`null_modem`** — raw serial over a **bitbanger**; point `-bitbanger` at a file, a
  TCP socket (`socket.<host>:<port>`), or a pipe. Good for linking to a telnet BBS or
  another emulated Mac. *Not* a Hayes modem (no `AT`/dialing).
  ```
  mame macqd800 -modem null_modem -bitbanger socket.localhost:1234
  ```
- **`pty`** — host **pseudo-terminal**; MAME prints a `/dev/ttysNN` you attach host
  software to. The bridge of choice for host networking.
  ```
  mame macqd800 -modem pty
  ```
- **Period modem + PPP** — MAME has **no built-in Hayes modem and no PPP**; PPP is just
  serial framing. On the Mac (System 7) install **MacTCP / Open Transport** plus a PPP
  client (**MacPPP / FreePPP / OT-PPP**). MAME bridges SCC channel A out via `pty` (or
  `null_modem`+socket) to a **host-side `pppd`** (direct PPP) or **`tcpser`** (Hayes
  `ATDT`→TCP). Data flow:
  ```
  Mac PPP client → SCC ch.A → MAME "modem" RS-232 → pty/null_modem
     → host pppd → host network / Internet
  ```
  Recipes are in **MacIIvi_HardwareConfig.md §8** (they apply unchanged here).

> **Recommended for this machine:** because the Quadra 800 has **built-in SONIC
> Ethernet**, the simplest networking is MacTCP/OT in **Ethernet** mode — no modem,
> no PPP, far faster. Use the modem/PPP path only if you specifically want the
> period dial-up experience.

---

## 9. Interrupt map (68k levels)

Still the classic Mac **3-level autovector** scheme, now fielded by **IOSB**
(`iosb.cpp:282-310`):

| 68k level | Source | Wired by |
|---|---|---|
| **4** | SCC (serial) | `scc_irq_w` (`iosb.cpp:312-316`) |
| **2** | VIA2 (slots, SONIC, DAFB VBL, SCSI, ASC) | `via2_irq` (`iosb.cpp:273-280`) |
| **1** | VIA1 | `via1_irq` (`iosb.cpp:260-264`) |

The big change is **how much funnels into VIA2**. Secondary sources are OR-reduced into
VIA2 via the templated `via2_irq_w<mask>` aggregator (`iosb.cpp:318-344`):

| Mask | Source | Wired by |
|---|---|---|
| `0x40` | DAFB VBL | `djmemc → via2_irq_w<0x40>` (`macquadra800.cpp:186`) |
| `0x20` | NuBus slot $E | `macquadra800.cpp:249` |
| `0x10` | NuBus slot $D | `macquadra800.cpp:248` |
| `0x08` | NuBus slot $C | `macquadra800.cpp:247` |
| `0x01` | SONIC Ethernet | `macquadra800.cpp:242` |

SCSI and ASC have their own dedicated VIA2 lines (`scsi_irq_w → m_via2->scsi_irq_w`,
`asc_irq → m_via2->asc_irq_w`, `iosb.cpp:352-362`).

---

## 10. VIA1 and VIA2 register maps

### VIA1 — real Rockwell 65C22 (`R65NC22`)

Clock `C7M/10` ≈ **783.36 kHz** (`iosb.cpp:74`), at **`0x50000000`** (16-bit access,
mirror `0x00fc0000`, `iosb.cpp:56`). Standard 6522 register layout. Pin functions as
wired in IOSB:

| Pin | Function | Source |
|---|---|---|
| PA5 (out) | floppy head-select (HDSEL) | `iosb.cpp:242-253` |
| PB (in) | RTC data in (`m_rtc->data_r()`) | `iosb.cpp:623` |
| PB / port B | ADB state + RTC/scan bits | `via_in_b`/`via_out_b`, `iosb.cpp:75-78` |
| CA1 (in) | 60.15 Hz tick | IOSB timer, `iosb.cpp:212-216` |
| CA2 (in) | RTC clock-out (CKO) | `iosb.cpp:107` |
| CB1 / CB2 | ADB modem clock / data | `iosb.cpp:79-80, 255-259` |
| IRQ (out) | → 68k level 1 | `via1_irq`, `iosb.cpp:81, 260-264` |

Unlike the LC/IIvi (Egret over the VIA shift register), here **VIA1 talks to the
GI/Microchip "ADB modem"** (CB1/CB2 + port-B state) and to a **discrete RTC** — the
pre-Egret arrangement.

### VIA2 — `quadra_pseudovia` (`pseudovia.cpp`, type at `:44`)

Clock `C7M/10` (`iosb.cpp:83`), at **`0x50002000`** (8-bit, mirror `0x00f00000`,
`iosb.cpp:57`). This is the "maximally VIA-like" pseudo-VIA — it behaves like a real
6522 but with **no timers and no shift register**. It decodes A9-and-up
(`offset >>= 9`) and implements Port A (in), Port B (out), **IFR** (reg `0x03`), and
**IER** (reg `0x13`) (`pseudovia.cpp:697-780`). All the secondary interrupts (NuBus
slots, SONIC, DAFB VBL, SCSI, ASC — see §9) aggregate here and surface as 68k level 2.

> **Lineage note:** the pseudo-VIA evolved RBV → V8 → Sonora → **IOSB/quadra**
> (`pseudovia.h:54-110`). The LC uses `APPLE_V8_PSEUDOVIA`; the IIvi uses the base
> `APPLE_PSEUDOVIA`; the Quadra 800 uses `APPLE_QUADRA_PSEUDOVIA`, the closest of the
> three to a genuine VIA. If you share register code across cores, this is the spot
> that differs most.

---

## 11. MAME-implementation notes

- **Five machines, one driver.** `macqd800` and four siblings (Centris 610/650,
  Quadra 610/650) differ by CPU type/clock via `config.replace()`
  (`macquadra800.cpp:282-327`); the Centris parts use the FPU-less `M68LC040`.
- **Native widths, few caveats.** Because the real machine is 32-bit, MAME's model
  matches hardware closely — there's no "MAME is wider than the bus" caveat like the
  LC/IIvi. RAM/ROM/VRAM are `u32` *and* the hardware is 32-bit.
- **VRAM fixed at 1 MB.** DAFB-MEMC pins VRAM to 1 MB (`dafb.cpp:1181`); real machines
  could have 512 KB or 1 MB.
- **RAM ceiling.** MAME exposes up to 640 MB (`macquadra800.cpp:268`), matching
  djMEMC's theoretical capacity; the *real* Quadra 800 maxes at **136 MB** of 72-pin
  SIMMs.
- **Turbo SCSI is pseudo-DMA, not a DMA engine** (CPU-driven, longword; `iosb.cpp:498-617`).
- **SONIC is the only true bus master** (`set_bus`, `macquadra800.cpp:241`).
- **ADB via GI/Microchip modem, not Egret/Cuda** (`macquadra800.cpp:254-258`) — a
  deliberate IOSB choice; the PrimeTime sibling later switches to Cuda
  (`iosb.cpp:22-23`).

---

*Generated from analysis of the MAME source tree (`src/mame/apple/macquadra800.cpp`,
`djmemc.cpp`, `iosb.cpp`, `dafb.cpp`, `src/devices/machine/dp83932c.cpp`,
`ncr53c90.cpp`, `pseudovia.cpp`, and the NuBus / RS-232 buses) cross-referenced with
EveryMac / Wikipedia / Motorola hardware specifications. Companion to
MacLC_HardwareConfig.md and MacIIvi_HardwareConfig.md.*
