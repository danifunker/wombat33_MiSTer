#!/usr/bin/env python3
"""Read the HFS partition of a Mac .hda image: catalog, files, both forks.

Enough HFS to list the volume, extract a file's data or resource fork, and
answer "which file lives at this raw image offset?" — the last one is what
makes a raw string hit in a disk image actionable.

    python3 scripts/mac_hfs.py IMAGE ls ':'
    python3 scripts/mac_hfs.py IMAGE find :
    python3 scripts/mac_hfs.py IMAGE cat ':A/UX Startup' out.bin [--rsrc]
    python3 scripts/mac_hfs.py IMAGE at 0x7fe1002e

Extents overflow is followed when a fork is fragmented past its first three
extents.
"""

import struct
import sys

sys.path.insert(0, __file__.rsplit('/', 1)[0] if '/' in __file__ else '.')
from aux_ufs import read_partitions  # noqa: E402

NODE = 512


def u8(b, o):
    return b[o]


def u16(b, o):
    return struct.unpack_from('>H', b, o)[0]


def u32(b, o):
    return struct.unpack_from('>I', b, o)[0]


def pstr(b, o, maxlen):
    n = min(b[o], maxlen)
    return b[o + 1:o + 1 + n].decode('mac-roman', 'replace')


class HFS:
    def __init__(self, path, part_off=None):
        self.f = open(path, 'rb')
        if part_off is None:
            for p in read_partitions(self.f):
                if p.type == 'Apple_HFS':
                    part_off = p.start
                    break
            if part_off is None:
                raise ValueError("no Apple_HFS partition")
        self.base = part_off
        self.f.seek(self.base + 1024)
        m = self.f.read(512)
        if m[0:2] != b'BD':
            raise ValueError("no HFS MDB at partition+1024 (got %r)" % m[0:2])
        self.mdb = m
        self.alBlkSiz = u32(m, 20)
        self.alBlSt = u16(m, 28)
        self.nmAlBlks = u16(m, 18)
        self.name = pstr(m, 36, 27)
        # MDB: drVCSize/drVBMCSize/drCtlCSize are three u16 at 124/126/128,
        # so the fork descriptors start at 130 -- not 132.
        self.xtFlSize = u32(m, 130)
        self.xtExt = self._extrec(m, 134)
        self.ctFlSize = u32(m, 146)
        self.ctExt = self._extrec(m, 150)
        self._extents_ovf = None
        self._cat = None
        self._nodes = None

    # --- block addressing -------------------------------------------------
    def ablk_off(self, n):
        return self.base + self.alBlSt * 512 + n * self.alBlkSiz

    @staticmethod
    def _extrec(b, o):
        return [(u16(b, o + 4 * i), u16(b, o + 4 * i + 2)) for i in range(3)]

    def read_extents(self, extrec, length):
        out = bytearray()
        for start, count in extrec:
            if count == 0:
                continue
            self.f.seek(self.ablk_off(start))
            out += self.f.read(count * self.alBlkSiz)
            if len(out) >= length:
                break
        return bytes(out[:length])

    # --- extents overflow B-tree -----------------------------------------
    def _load_ovf(self):
        if self._extents_ovf is not None:
            return
        data = self.read_extents(self.xtExt, self.xtFlSize)
        self._extents_ovf = {}
        for rec_key, rec_data in self._btree_leaves(data, keylen=7):
            # key (keyLen already stripped): xkrFkType u8, xkrFNum u32, xkrFABN u16
            if len(rec_key) < 7:
                continue
            xkrFkType, xkrFNum, xkrFABN = rec_key[0], u32(rec_key, 1), u16(rec_key, 5)
            ext = self._extrec(rec_data, 0)
            self._extents_ovf.setdefault((xkrFNum, xkrFkType), []).append((xkrFABN, ext))

    def fork_extents(self, cnid, first3, length, rsrc=False):
        """Full extent list for a fork, following the overflow file if needed."""
        blks = (length + self.alBlkSiz - 1) // self.alBlkSiz
        ext = [e for e in first3 if e[1]]
        have = sum(c for _, c in ext)
        if have >= blks:
            return ext
        self._load_ovf()
        key = (cnid, 0xFF if rsrc else 0x00)
        for abn, more in sorted(self._extents_ovf.get(key, [])):
            for e in more:
                if e[1]:
                    ext.append(e)
            if sum(c for _, c in ext) >= blks:
                break
        return ext

    # --- B*-tree ----------------------------------------------------------
    @staticmethod
    def _btree_leaves(data, keylen):
        """Yield (key_bytes, record_bytes) for every leaf record, in order."""
        hdr = data[0:NODE]
        bthFNode = u32(hdr, 14 + 10)
        n = bthFNode
        seen = set()
        while n and n not in seen:
            seen.add(n)
            nd = data[n * NODE:(n + 1) * NODE]
            if len(nd) < NODE:
                break
            flink, nrecs = u32(nd, 0), u16(nd, 10)
            for i in range(nrecs):
                o = u16(nd, NODE - 2 * (i + 1))
                oe = u16(nd, NODE - 2 * (i + 2))
                if o >= NODE or oe > NODE or oe <= o:
                    continue
                klen = nd[o]
                key = nd[o + 1:o + 1 + klen]
                doff = o + 1 + klen
                doff += doff & 1
                yield key, nd[doff:oe]
            n = flink

    # --- catalog ----------------------------------------------------------
    def catalog(self):
        if self._cat is not None:
            return self._cat
        data = self.read_extents(self.ctExt, self.ctFlSize)
        if len(data) < self.ctFlSize:
            ext = self.fork_extents(4, self.ctExt, self.ctFlSize)
            out = bytearray()
            for s, c in ext:
                self.f.seek(self.ablk_off(s))
                out += self.f.read(c * self.alBlkSiz)
            data = bytes(out[:self.ctFlSize])
        nodes = {}          # cnid -> dict
        children = {}       # parent cnid -> [(name, cnid)]
        for key, rec in self._btree_leaves(data, keylen=37):
            if len(key) < 5 or not rec:
                continue
            parid = u32(key, 1)
            name = pstr(key, 5, 31)
            t = rec[0]
            if t == 1 and len(rec) >= 10:      # directory
                cnid = u32(rec, 6)
                nodes[cnid] = dict(kind='d', name=name, parent=parid, cnid=cnid)
                children.setdefault(parid, []).append((name, cnid))
            elif t == 2 and len(rec) >= 98:    # file
                cnid = u32(rec, 20)
                nodes[cnid] = dict(kind='f', name=name, parent=parid, cnid=cnid,
                                   type=rec[4:8].decode('latin1'),
                                   creator=rec[8:12].decode('latin1'),
                                   dlen=u32(rec, 26), rlen=u32(rec, 36),
                                   dext=self._extrec(rec, 74),
                                   rext=self._extrec(rec, 86))
                children.setdefault(parid, []).append((name, cnid))
        nodes[2] = dict(kind='d', name='', parent=1, cnid=2)
        self._cat = (nodes, children)
        return self._cat

    def path_of(self, cnid):
        nodes, _ = self.catalog()
        parts = []
        while cnid and cnid != 2 and cnid in nodes:
            parts.append(nodes[cnid]['name'])
            cnid = nodes[cnid]['parent']
        return ':' + ':'.join(reversed(parts))

    def lookup(self, path):
        nodes, children = self.catalog()
        cur = 2
        # HFS allows '/' inside a filename ("A/UX Startup"), so ':' is the
        # separator here, exactly as on the Mac.  '/' still works when the
        # path is unambiguous.
        sep = ':' if ':' in path else '/'
        for part in [p for p in path.split(sep) if p]:
            hit = None
            for name, cnid in children.get(cur, []):
                if name.lower() == part.lower():
                    hit = cnid
                    break
            if hit is None:
                raise FileNotFoundError(path)
            cur = hit
        return nodes[cur]

    def read_fork(self, node, rsrc=False):
        length = node['rlen'] if rsrc else node['dlen']
        first3 = node['rext'] if rsrc else node['dext']
        ext = self.fork_extents(node['cnid'], first3, length, rsrc)
        out = bytearray()
        for s, c in ext:
            self.f.seek(self.ablk_off(s))
            out += self.f.read(c * self.alBlkSiz)
        return bytes(out[:length])

    # --- offset -> file ---------------------------------------------------
    def at(self, off):
        nodes, _ = self.catalog()
        blk = (off - self.base - self.alBlSt * 512) // self.alBlkSiz
        for cnid, n in nodes.items():
            if n['kind'] != 'f':
                continue
            for rsrc, (length, first3) in ((False, (n['dlen'], n['dext'])),
                                           (True, (n['rlen'], n['rext']))):
                if not length:
                    continue
                pos = 0
                for s, c in self.fork_extents(cnid, first3, length, rsrc):
                    if s <= blk < s + c:
                        inner = pos + (blk - s) * self.alBlkSiz + \
                            (off - self.base - self.alBlSt * 512) % self.alBlkSiz
                        return self.path_of(cnid), ('rsrc' if rsrc else 'data'), inner
                    pos += c * self.alBlkSiz
        return None


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 1
    h = HFS(argv[1])
    cmd = argv[2]
    if cmd == 'vol':
        print("volume %r  alBlkSiz=%d nmAlBlks=%d catalog=%d bytes"
              % (h.name, h.alBlkSiz, h.nmAlBlks, h.ctFlSize))
    elif cmd in ('ls', 'find'):
        nodes, children = h.catalog()
        root = h.lookup(argv[3] if len(argv) > 3 else '/')['cnid']
        stack = [(root, 0)]
        while stack:
            cur, d = stack.pop()
            for name, cnid in sorted(children.get(cur, [])):
                n = nodes[cnid]
                if n['kind'] == 'd':
                    print("%sd %s/" % ('  ' * d, h.path_of(cnid) if cmd == 'find' else name))
                    if cmd == 'find':
                        stack.append((cnid, d + 1))
                else:
                    print("%s- %-9s %8d %8d  %s" % ('  ' * d, n['type'] + '/' + n['creator'],
                          n['dlen'], n['rlen'], h.path_of(cnid) if cmd == 'find' else name))
    elif cmd == 'cat':
        n = h.lookup(argv[3])
        rsrc = '--rsrc' in argv
        data = h.read_fork(n, rsrc)
        out = argv[4] if len(argv) > 4 and not argv[4].startswith('--') else None
        (open(out, 'wb') if out else sys.stdout.buffer).write(data)
    elif cmd == 'at':
        for a in argv[3:]:
            r = h.at(int(a, 0))
            print("0x%08x -> %s" % (int(a, 0), ("%s [%s fork] + 0x%x" % r) if r else "(not in a file)"))
    else:
        print("unknown command", cmd)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
