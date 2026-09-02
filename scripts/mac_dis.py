#!/usr/bin/env python3
"""Disassemble a Macintosh 68k CODE resource, resyncing over A-line traps.

Capstone stops dead at an A-line word, which in Mac code is a Toolbox/OS
trap rather than an error -- so this decodes the trap itself and restarts
the stream after it.  SCSI Manager calls get their selector named from the
`move.w #sel,-(a7)` that precedes the dispatch.

    python3 scripts/mac_dis.py CODE_6_saio.bin 0x1218 0x14e0
"""

import struct
import sys

from capstone import Cs, CS_ARCH_M68K, CS_MODE_BIG_ENDIAN, CS_MODE_M68K_040

TRAPS = {
    0xA815: '_SCSIDispatch', 0xA06E: '_SlotManager', 0xA1AD: '_Gestalt',
    0xA07E: '_PrimaryInit', 0xA346: '_GetOSTrapAddress', 0xA746: '_GetToolTrapAddress',
    0xA89F: '_Unimplemented', 0xA11A: '_GetZone', 0xA054: '_UprString',
    0xA000: '_Open', 0xA001: '_Close', 0xA002: '_Read', 0xA003: '_Write',
    0xA004: '_Control', 0xA005: '_Status', 0xA008: '_Create', 0xA009: '_Delete',
    0xA027: '_SetApplLimit', 0xA02E: '_BlockMove', 0xA122: '_NewHandle',
    0xA023: '_DisposHandle', 0xA11E: '_NewPtr', 0xA01F: '_DisposPtr',
    0xA9F0: '_LoadSeg', 0xA9F1: '_UnloadSeg', 0xA9C8: '_SysBeep',
    0xA03C: '_CmpString', 0xA9ED: '_Pack6', 0xA260: '_HFSDispatch',
    0xA995: '_LoadResource', 0xA9A0: '_GetResource', 0xA9A2: '_LoadResource2',
    0xABEB: '_DebugStr',
}

SEL = {0: 'SCSIReset', 1: 'SCSIGet', 2: 'SCSISelect', 3: 'SCSICmd',
       4: 'SCSIComplete', 5: 'SCSIRead', 6: 'SCSIWrite', 8: 'SCSIRBlind',
       9: 'SCSIWBlind', 10: 'SCSIStat', 11: 'SCSISelAtn', 12: 'SCSIMsgIn',
       13: 'SCSIMsgOut'}

# scsireq.c's req->ret codes -- see docs/scsi/aux-c94-driver.md section 7.
RET = {0: 'driver implementation error', 1: 'bus dropped busy', 2: 'error during command',
       3: 'error during status', 4: 'error during sense command', 5: 'cannot select device',
       6: 'timeout', 7: 'id already has active request', 8: 'PROTOCOL ERROR (default)',
       9: 'more data than requested', 10: 'less data than requested',
       11: 'extended status returned', 12: 'retry required', 13: 'caller/SCSI Mgr out of date',
       14: 'cancelled by Scsican'}


def disasm(code, base, lo, hi, out=print):
    md = Cs(CS_ARCH_M68K, CS_MODE_BIG_ENDIAN | CS_MODE_M68K_040)
    pc = lo
    lastsel = None
    while pc < hi:
        w = struct.unpack_from('>H', code, pc - base)[0]
        if (w & 0xF000) == 0xA000:
            name = TRAPS.get(w, '_Trap_%04X' % w)
            note = ''
            if w == 0xA815:
                note = '   <<< selector = %s' % SEL.get(lastsel, '?%s' % lastsel)
            out("  %04x  %-10s %-34s%s" % (pc, 'dc.w', '$%04x   ; %s' % (w, name), note))
            pc += 2
            continue
        got = False
        # Feed capstone a little past `hi` so the last instruction in the
        # range decodes from whole bytes rather than a truncated tail.
        end = min(len(code), hi - base + 16)
        for ins in md.disasm(code[pc - base:end], pc):
            if ins.address >= hi:
                pc = ins.address
                got = True
                break
            note = ''
            ops = ins.op_str
            if ins.mnemonic.startswith('move.w') and ops.endswith('-(a7)') and ops.startswith('#$'):
                try:
                    lastsel = int(ops.split(',')[0][2:], 16)
                except ValueError:
                    pass
            if ins.mnemonic.startswith('move.b') and ops.startswith('#$') and '$27(a4)' in ops:
                try:
                    note = '   ; req->ret = %s' % RET.get(int(ops.split(',')[0][2:], 16), '?')
                except ValueError:
                    pass
            out("  %04x  %-10s %-34s%s" % (ins.address, ins.mnemonic, ops, note))
            pc = ins.address + ins.size
            got = True
            if (struct.unpack_from('>H', code, pc - base)[0] & 0xF000) == 0xA000:
                break
        if not got:
            out("  %04x  dc.w       $%04x" % (pc, w))
            pc += 2


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 1
    code = open(argv[1], 'rb').read()
    lo = int(argv[2], 0) if len(argv) > 2 else 4
    hi = int(argv[3], 0) if len(argv) > 3 else len(code)
    disasm(code, 0, lo, min(hi, len(code)))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
