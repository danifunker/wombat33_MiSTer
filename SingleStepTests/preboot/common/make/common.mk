# preboot/common/make/common.mk — shared Make plumbing for every preboot
# bench. Bench Makefiles `include` this file relative to themselves and
# get a consistent toolchain, flags, and paths to the common library.
#
# Tested with Retro68 toolchain (m68k-apple-macos-*). Override RETRO68
# from the environment if your Retro68 install is elsewhere.

RETRO68 ?= $(HOME)/repos/Retro68-build/toolchain
PREFIX  := $(RETRO68)/bin/m68k-apple-macos-
CC      := $(PREFIX)gcc
AS      := $(PREFIX)as
LD      := $(PREFIX)ld
OBJCOPY := $(PREFIX)objcopy

# Path to the preboot/common/ tree from a bench's own directory:
#   preboot/<bench>/Makefile  -> ../common
COMMON ?= ../common

# ----------------------------------------------------------------------------
# VIDEO_VARIANT — selects the display card the bench is built for. This
# controls ROW_BYTES (the 1 bpp framebuffer stride in bytes), which the
# card's declaration ROM programs into the TFB/CRTC at boot and must
# match exactly or text renders as fragmented garbage across the top of
# the screen (verified in MAME with --nb9 m2hires + iotest.hda).
#
# Why this is card-specific: each card's declaration ROM picks its
# preferred default stride based on the card's max resolution, not the
# visible 640-pixel area:
#
#   m2hires (Apple Mac II High Resolution Card)
#     - Default 1 bpp, LENGTH register = 32 (32-bit words)
#     - Stride = 32 * 4 = 128 bytes per row (1024-pixel-wide buffer,
#       only first 640 visible)
#
#   mdc824  (Apple Macintosh Display Card 8•24, 341-0868)
#     - Default 1 bpp, 80-byte stride (640 pixels exact)
#
#   toby    (Apple Macintosh II Video Card, 342-0008-a)
#     - 1 bpp only, 80-byte stride (640 pixels exact)
#
# To add a future card: append a case to the ifeq cascade below.
# Mismatched ROW_BYTES is the easiest-to-misdiagnose bug in this tree,
# so the comment is verbose on purpose. Mac OS apps (Retro68) ignore
# all of this; they paint via QuickDraw, which the OS programs to
# match whatever card is active.
# ----------------------------------------------------------------------------
# Default for the Quadra 800 core is the built-in DAFB display, whose
# stride is software-programmed (not a fixed card constant) — so we
# read it from the ROM at runtime. `dafb` is therefore an alias for the
# auto-stride build.
VIDEO_VARIANT ?= dafb

# Quadra 800 (Wombat) core additions:
#   dafb  — Macintosh Quadra 800 built-in DAFB II video (djMEMC). VRAM at
#           CPU $F9000000 (2 MB); ScrnBase = $F9001000. The ROM boots it
#           at 640x480 @ 8 bpp (256 colors, Apple 67 Hz mode) — REQUIRED
#           display mode. So this variant paints 8 bpp (-DDISPLAY_BPP8,
#           one byte per pixel) and reads the byte stride (1024 for
#           640x480) from the ROM's ScrnRow low-mem global ($0106) at
#           runtime, so other 256-color resolutions work too.
#   dafb1 — same, but 1 bpp paint for when the screen is set to B&W.
#
# Carried Mac II / IIvi NuBus + built-in variants (still usable if a
# NuBus video card is fitted in a Q800 slot, or for cross-checks):
#   v8    — Macintosh LC / LC II built-in video. Fixed 1024-byte VRAM
#           row stride regardless of mode (MAME v8.cpp screen_update).
#   vasp  — Macintosh IIvi built-in video. Fixed 2048-byte stride
#           (MAME vasp.cpp).
#   auto  — runtime stride from the ROM's ScrnRow low-mem global
#           ($0106), set by the ROM video driver before the boot block
#           runs. Falls back to 80 if the value is implausible. One
#           binary covers DAFB + mdc824 + V8 + VASP; the asm-side debug
#           dots still assume 80 (cosmetic only).
CDEFS_VIDEO :=
ifeq ($(VIDEO_VARIANT),dafb)
    # Quadra 800 built-in DAFB: REQUIRES the display set to 640x480, 256
    # colors (8 bpp, 67 Hz) — the machine's boot default. 8 bpp = one
    # byte per pixel; the byte stride (1024 for 640x480) is read from
    # ScrnRow ($0106) at runtime.
    ROW_BYTES := 1024
    CDEFS_VIDEO := -DROW_BYTES_AUTO -DDISPLAY_BPP8
else ifeq ($(VIDEO_VARIANT),dafb1)
    # DAFB escape hatch: 1 bpp paint, for when the screen is set to B&W.
    ROW_BYTES := 80
    CDEFS_VIDEO := -DROW_BYTES_AUTO
else ifeq ($(VIDEO_VARIANT),m2hires)
    ROW_BYTES := 128
else ifeq ($(VIDEO_VARIANT),mdc824)
    ROW_BYTES := 80
else ifeq ($(VIDEO_VARIANT),toby)
    ROW_BYTES := 80
else ifeq ($(VIDEO_VARIANT),v8)
    ROW_BYTES := 1024
else ifeq ($(VIDEO_VARIANT),vasp)
    ROW_BYTES := 2048
else ifeq ($(VIDEO_VARIANT),auto)
    ROW_BYTES := 80
    CDEFS_VIDEO := -DROW_BYTES_AUTO
else
    $(error Unknown VIDEO_VARIANT=$(VIDEO_VARIANT); known: dafb dafb1 m2hires mdc824 toby v8 vasp auto)
endif

# MC68040 target (Quadra 800). -m68040 enables the 040 ISA (MOVE16,
# cache ops) and the on-chip FPU; the freestanding runner itself uses
# no floating point, so codegen stays integer.
CPUFLAGS := -m68040
CFLAGS   := $(CPUFLAGS) -ffreestanding -fno-builtin -fomit-frame-pointer \
            -nostdlib -Os -Wall -Wextra -fno-pic -fno-exceptions \
            -fno-asynchronous-unwind-tables \
            -I. -I$(COMMON)/runtime -I$(COMMON)/display \
            -DROW_BYTES=$(ROW_BYTES) $(CDEFS_VIDEO)
# gas: --defsym propagates ROW_BYTES into the .s files. Each .s wraps
# its fallback default behind `.ifndef ROW_BYTES` so direct AS invocations
# without the Makefile still assemble (the default is 80 = legacy).
ASFLAGS  := $(CPUFLAGS) --defsym ROW_BYTES=$(ROW_BYTES)
LDFLAGS  := -nostdlib --no-eh-frame-hdr

# Linker scripts live in common/runtime.
PAYLOAD_LD   := $(COMMON)/runtime/payload.ld
BOOT_STUB_LD := $(COMMON)/runtime/boot_stub.ld

# The canonical boot block (SCSI-bootable, PAYLDOFF-patchable). Older
# variants live under common/boot/old/ but aren't selected by default.
BOOT_STUB_SRC := $(COMMON)/boot/boot_stub_scsi.s

# Active display kernel — 1bpp paint, works on the Mac II built-in
# framebuffer and on any NuBus video card in its power-on 1bpp default
# (Toby, m2hires, mdc824). 8bpp paint lives under common/display/old/
# until depth-switch init code exists.
DISPLAY_SRC := $(COMMON)/display/display_1bpp.c
