#!/usr/bin/env python3
"""List and extract resources from a Macintosh resource fork.

    python3 scripts/mac_rsrc.py FORK list
    python3 scripts/mac_rsrc.py FORK get CODE 6 out.bin
    python3 scripts/mac_rsrc.py FORK dumpall CODE outdir/
"""

import os
import struct
import sys


class Rsrc:
    def __init__(self, path):
        self.d = open(path, 'rb').read()
        d = self.d
        self.dataOff, self.mapOff, self.dataLen, self.mapLen = struct.unpack_from('>IIII', d, 0)
        tlOff, nlOff = struct.unpack_from('>HH', d, self.mapOff + 24)
        self.tl = self.mapOff + tlOff
        self.nl = self.mapOff + nlOff
        self.types = []
        n = struct.unpack_from('>H', d, self.tl)[0] + 1
        for i in range(n):
            o = self.tl + 2 + 8 * i
            typ = d[o:o + 4].decode('latin1')
            cnt = struct.unpack_from('>H', d, o + 4)[0] + 1
            rlo = struct.unpack_from('>H', d, o + 6)[0]
            items = []
            for j in range(cnt):
                r = self.tl + rlo + 12 * j
                rid = struct.unpack_from('>h', d, r)[0]
                nameOff = struct.unpack_from('>h', d, r + 2)[0]
                doff = struct.unpack_from('>I', d, r + 4)[0] & 0x00FFFFFF
                rlen = struct.unpack_from('>I', d, self.dataOff + doff)[0]
                name = ''
                if nameOff >= 0:
                    no = self.nl + nameOff
                    name = d[no + 1:no + 1 + d[no]].decode('mac-roman', 'replace')
                items.append(dict(id=rid, name=name, len=rlen,
                                  body=self.dataOff + doff + 4))
            self.types.append((typ, items))

    def get(self, typ, rid):
        for t, items in self.types:
            if t != typ:
                continue
            for it in items:
                if it['id'] == rid:
                    return self.d[it['body']:it['body'] + it['len']], it
        raise KeyError("%s %d" % (typ, rid))


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 1
    r = Rsrc(argv[1])
    cmd = argv[2]
    if cmd == 'list':
        for t, items in r.types:
            for it in items:
                print("%-4s %6d %8d  %s" % (t, it['id'], it['len'], it['name']))
    elif cmd == 'get':
        data, it = r.get(argv[3], int(argv[4], 0))
        out = argv[5] if len(argv) > 5 else None
        (open(out, 'wb') if out else sys.stdout.buffer).write(data)
        if out:
            sys.stderr.write("%s %d %r -> %s (%d bytes, body at fork 0x%x)\n"
                             % (argv[3], it['id'], it['name'], out, it['len'], it['body']))
    elif cmd == 'dumpall':
        typ, outdir = argv[3], argv[4]
        os.makedirs(outdir, exist_ok=True)
        for t, items in r.types:
            if t != typ:
                continue
            for it in items:
                nm = "%s_%d_%s.bin" % (t, it['id'],
                                       ''.join(c if c.isalnum() else '_' for c in it['name']))
                with open(os.path.join(outdir, nm), 'wb') as f:
                    f.write(r.d[it['body']:it['body'] + it['len']])
                print("%s  %d bytes  body at fork 0x%x" % (nm, it['len'], it['body']))
    else:
        print("unknown command", cmd)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
