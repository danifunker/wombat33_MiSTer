#!/usr/bin/env python3
"""Read an A/UX (m68k COFF, magic 0x0150) binary: sections and symbol table.

The A/UX 3.1 kernel ships with its full symbol table, which turns blind
disassembly of `/unix` into reading named functions.  Section VMAs are
.text 0x10000000, .data 0x11000000, .bss 0x12000000.

    python3 scripts/aux_coff.py FILE hdr
    python3 scripts/aux_coff.py FILE syms [regex]     # sorted by address
    python3 scripts/aux_coff.py FILE addr 0x1004fa6a  # which symbol is this?
    python3 scripts/aux_coff.py FILE off  0x1004fa6a  # VMA -> file offset
    python3 scripts/aux_coff.py FILE dump 0x1004fa6a 64
"""

import re
import struct
import sys

STORAGE = {2: 'ext', 3: 'stat', 6: 'label', 100: 'file', 101: 'line'}


class Coff:
    def __init__(self, path):
        self.d = open(path, 'rb').read()
        d = self.d
        (self.magic, self.nscns, self.timdat, self.symptr,
         self.nsyms, self.opthdr, self.flags) = struct.unpack_from('>HHIIIHH', d, 0)
        if self.magic != 0x0150:
            raise ValueError("not m68k COFF (magic 0x%04x)" % self.magic)
        self.aout = struct.unpack_from('>HHIIIIII', d, 20) if self.opthdr else None
        self.sections = []
        o = 20 + self.opthdr
        for _ in range(self.nscns):
            h = d[o:o + 40]
            name = h[0:8].split(b'\0')[0].decode('latin1')
            paddr, vaddr, size, scnptr, relptr, lnnoptr = struct.unpack_from('>IIIIII', h, 8)
            self.sections.append(dict(name=name, paddr=paddr, vaddr=vaddr, size=size,
                                      fptr=scnptr, flags=struct.unpack_from('>I', h, 36)[0]))
            o += 40
        self._syms = None

    # --- symbols ----------------------------------------------------------
    @property
    def syms(self):
        if self._syms is not None:
            return self._syms
        d = self.d
        strtab_off = self.symptr + 18 * self.nsyms
        strtab = d[strtab_off:]
        out, n = [], 0
        while n < self.nsyms:
            e = d[self.symptr + 18 * n: self.symptr + 18 * n + 18]
            if struct.unpack_from('>I', e, 0)[0] == 0:
                so = struct.unpack_from('>I', e, 4)[0]
                name = strtab[so:strtab.index(b'\0', so)].decode('latin1')
            else:
                name = e[0:8].split(b'\0')[0].decode('latin1')
            value, scnum, typ = struct.unpack_from('>IhH', e, 8)
            sclass, numaux = e[16], e[17]
            out.append(dict(name=name, value=value, scnum=scnum, type=typ,
                            sclass=sclass, aux=numaux))
            n += 1 + numaux
        self._syms = out
        return out

    def funcs(self):
        """Named symbols with an address, sorted, de-duplicated."""
        seen, out = set(), []
        for s in self.syms:
            if s['scnum'] <= 0 or s['sclass'] not in (2, 3):
                continue
            k = (s['value'], s['name'])
            if k in seen:
                continue
            seen.add(k)
            out.append(s)
        out.sort(key=lambda s: s['value'])
        return out

    def nearest(self, addr):
        best = None
        for s in self.funcs():
            if s['value'] <= addr:
                best = s
            else:
                break
        return best

    # --- addressing -------------------------------------------------------
    def sec_of(self, vma):
        for s in self.sections:
            if s['size'] and s['vaddr'] <= vma < s['vaddr'] + s['size']:
                return s
        return None

    def off(self, vma):
        s = self.sec_of(vma)
        if not s or not s['fptr']:
            return None
        return s['fptr'] + (vma - s['vaddr'])


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 1
    c = Coff(argv[1])
    cmd = argv[2]
    if cmd == 'hdr':
        print("magic 0x%04x  nsyms %d  flags 0x%x" % (c.magic, c.nsyms, c.flags))
        if c.aout:
            print("a.out magic 0%o entry 0x%x text 0x%x data 0x%x bss 0x%x"
                  % (c.aout[0], c.aout[5], c.aout[2], c.aout[3], c.aout[4]))
        for s in c.sections:
            print("  %-9s vaddr 0x%08x size 0x%-7x fptr 0x%-7x flags 0x%x"
                  % (s['name'], s['vaddr'], s['size'], s['fptr'], s['flags']))
    elif cmd == 'syms':
        pat = re.compile(argv[3], re.I) if len(argv) > 3 else None
        for s in c.funcs():
            if pat and not pat.search(s['name']):
                continue
            sec = c.sections[s['scnum'] - 1]['name'] if 0 < s['scnum'] <= len(c.sections) else '?'
            print("0x%08x %-6s %-5s %s" % (s['value'], sec,
                                           STORAGE.get(s['sclass'], s['sclass']), s['name']))
    elif cmd == 'addr':
        for a in argv[3:]:
            v = int(a, 0)
            s = c.nearest(v)
            print("0x%08x = %s + 0x%x" % (v, s['name'], v - s['value']) if s else "0x%08x = ?" % v)
    elif cmd == 'off':
        for a in argv[3:]:
            v = int(a, 0)
            o = c.off(v)
            print("0x%08x -> file offset %s" % (v, hex(o) if o is not None else '(bss/none)'))
    elif cmd == 'dump':
        v = int(argv[3], 0)
        n = int(argv[4], 0) if len(argv) > 4 else 64
        o = c.off(v)
        d = c.d[o:o + n]
        for k in range(0, len(d), 16):
            print("%08x  %-47s  %s" % (v + k, ' '.join('%02x' % x for x in d[k:k + 16]),
                                       ''.join(chr(x) if 32 <= x < 127 else '.' for x in d[k:k + 16])))
    else:
        print("unknown command", cmd)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
