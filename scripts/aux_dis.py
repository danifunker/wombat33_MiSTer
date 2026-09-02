#!/usr/bin/env python3
"""Disassemble a range of an A/UX COFF binary, annotated with its symbols.

The A/UX kernel keeps its full symbol table, so every branch target and most
absolute operands can be named.  That is the difference between reading this
code and guessing at it.

    python3 scripts/aux_dis.py unix.bin machineID          # whole function
    python3 scripts/aux_dis.py unix.bin 0x589ee 0x58aae    # explicit range
    python3 scripts/aux_dis.py unix.bin boardinit --raw    # show opcode bytes

Ranges given as a symbol name run to the next symbol.  Hardware addresses
that the MacQuadra800 core decodes are called out inline.
"""

import struct
import sys

from capstone import Cs, CS_ARCH_M68K, CS_MODE_BIG_ENDIAN, CS_MODE_M68K_040

sys.path.insert(0, __file__.rsplit('/', 1)[0] if '/' in __file__ else '.')
from aux_coff import Coff  # noqa: E402

# Addresses worth flagging while reading bring-up code.
HW = [
    (0x50F00000, 0x50F01FFF, 'VIA1'),
    (0x50F02000, 0x50F03FFF, 'VIA2/RBV'),
    (0x50F04000, 0x50F05FFF, 'SCC'),
    (0x50F06000, 0x50F07FFF, 'SCSI DMA'),
    (0x50F08000, 0x50F09FFF, 'SCSI handshake'),
    (0x50F0F000, 0x50F0FFFF, 'IOSB/asc? $50F0Fxxx'),
    (0x50F10000, 0x50F1FFFF, 'NCR 53C96'),
    (0x50F14000, 0x50F15FFF, 'sound'),
    (0x50F16000, 0x50F17FFF, 'SWIM'),
    (0x50F18000, 0x50F18FFF, 'IOSB config'),
    (0x50F1A000, 0x50F1BFFF, 'SCSI DMA (Q800)'),
    (0x5FFF0000, 0x5FFFFFFF, 'machine ID reg'),
    (0xF9000000, 0xF9FFFFFF, 'DAFB / slot 9 super'),
    (0xFEE00000, 0xFEFFFFFF, 'A/UX mapped I/O'),
]


def hwname(v):
    for lo, hi, n in HW:
        if lo <= v <= hi:
            return n
    return None


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 1
    raw = '--raw' in argv
    argv = [a for a in argv if a != '--raw']
    c = Coff(argv[1])
    funcs = c.funcs()
    byname = {}
    for s in funcs:
        byname.setdefault(s['name'], s['value'])

    def resolve(tok):
        if tok in byname:
            return byname[tok]
        return int(tok, 0)

    start = resolve(argv[2])
    if len(argv) > 3:
        end = resolve(argv[3])
    else:
        end = None
        for s in funcs:
            if s['value'] > start:
                end = s['value']
                break
        end = end or start + 0x200

    off = c.off(start)
    if off is None:
        print("0x%x is not in a loaded section" % start)
        return 1
    code = c.d[off:off + (end - start)]

    md = Cs(CS_ARCH_M68K, CS_MODE_BIG_ENDIAN | CS_MODE_M68K_040)
    names = {s['value']: s['name'] for s in funcs}

    def annotate(text):
        out = []
        import re
        for m in re.finditer(r'\$(?:0x)?([0-9a-fA-F]{4,8})', text):
            v = int(m.group(1), 16)
            tag = names.get(v) or hwname(v)
            if tag:
                out.append("%s=%s" % (m.group(0), tag))
        return out

    def emit(addr, text, opbytes=b''):
        lbl = names.get(addr)
        if lbl:
            print("\n%s:" % lbl)
        notes = annotate(text)
        pre = ' '.join('%02x' % b for b in opbytes) if raw else ''
        print("  %08x  %-22s%-46s %s" % (addr, pre, text,
                                         ('; ' + ', '.join(notes)) if notes else ''))

    # Capstone stops dead on a word it cannot decode, and kernel .text is full
    # of embedded jump tables -- so resync past the bad word and keep going, or
    # the first table truncates the rest of the listing.
    pc = start
    while pc < end:
        emitted = False
        for ins in md.disasm(code[pc - start:], pc):
            emit(ins.address, "%s %s" % (ins.mnemonic, ins.op_str), ins.bytes)
            pc = ins.address + ins.size
            emitted = True
        if not emitted:
            w = struct.unpack_from('>H', code, pc - start)[0]
            emit(pc, "dc.w $%04x" % w, code[pc - start:pc - start + 2])
            pc += 2
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
