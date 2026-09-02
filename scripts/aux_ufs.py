#!/usr/bin/env python3
"""Read the A/UX root slice (4.3BSD FFS) straight out of a raw .hda image.

The A/UX 3.1 disk is an Apple partition map with a big Apple_UNIX_SVR2 root
slice.  Nothing on this side of the wire can mount it, so this walks the
filesystem itself: superblock -> cylinder groups -> inodes -> directories.

Only the bits needed to find and extract files are implemented; there is no
write path and no attempt at being a general UFS driver.

    python3 scripts/aux_ufs.py IMAGE ls /
    python3 scripts/aux_ufs.py IMAGE find /            # recursive listing
    python3 scripts/aux_ufs.py IMAGE cat /unix > unix.bin
    python3 scripts/aux_ufs.py IMAGE stat /unix

Inode layout note: A/UX keeps the Mac Finder type/creator in the timeval
"spare" halves, so di_atime/mtime/ctime are the 32-bit words at 0x10/0x18/0x20
and 0x14/0x1c/0x24 hold Finder info.  Block pointers sit at the usual 0x28.
"""

import struct
import sys

SBOFF = 8192          # superblock offset within the slice
DINODE_SIZE = 128


def be32(b, o):
    return struct.unpack_from('>I', b, o)[0]


def sbe32(b, o):
    return struct.unpack_from('>i', b, o)[0]


def be16(b, o):
    return struct.unpack_from('>H', b, o)[0]


class Partition:
    def __init__(self, name, ptype, start, length):
        self.name, self.type, self.start, self.length = name, ptype, start, length

    def __repr__(self):
        return "<%s %s @0x%x len 0x%x>" % (self.name, self.type, self.start, self.length)


def read_partitions(f):
    """Apple partition map -> list of Partition (byte offsets into the image)."""
    f.seek(0)
    blk0 = f.read(512)
    if blk0[0:2] != b'ER':
        raise ValueError("no Apple driver descriptor (block 0 sig %r)" % blk0[0:2])
    bs = be16(blk0, 2)
    out = []
    n = 1
    while True:
        f.seek(n * bs)
        b = f.read(bs)
        if len(b) < 92 or b[0:2] != b'PM':
            break
        start, count = be32(b, 8), be32(b, 12)
        name = b[16:48].split(b'\0')[0].decode('mac-roman', 'replace')
        ptype = b[48:80].split(b'\0')[0].decode('mac-roman', 'replace')
        out.append(Partition(name, ptype, start * bs, count * bs))
        n += 1
    return out


def find_root_slice(f):
    for p in read_partitions(f):
        if p.type == 'Apple_UNIX_SVR2' and 'wap' not in p.name.lower():
            return p
    raise ValueError("no Apple_UNIX_SVR2 root slice")


class Inode:
    __slots__ = ('num', 'mode', 'nlink', 'uid', 'gid', 'size', 'mtime',
                 'db', 'ib', 'blocks', 'ftype', 'creator')

    @property
    def isdir(self):
        return (self.mode & 0o170000) == 0o040000

    @property
    def isreg(self):
        return (self.mode & 0o170000) == 0o100000

    @property
    def islnk(self):
        return (self.mode & 0o170000) == 0o120000


class UFS:
    def __init__(self, path, part_off=None):
        self.f = open(path, 'rb')
        self.base = part_off if part_off is not None else find_root_slice(self.f).start
        self.f.seek(self.base + SBOFF)
        sb = self.f.read(8192)
        if be32(sb, 0x55C) != 0x00011954:
            raise ValueError("bad UFS magic at slice+0x2000")
        self.iblkno = sbe32(sb, 16)
        self.cgoffset = sbe32(sb, 24)
        self.cgmask = sbe32(sb, 28)
        self.ncg = sbe32(sb, 44)
        self.bsize = sbe32(sb, 48)
        self.fsize = sbe32(sb, 52)
        self.frag = sbe32(sb, 56)
        self.fragshift = sbe32(sb, 96)
        self.nindir = sbe32(sb, 116)
        self.inopb = sbe32(sb, 120)
        self.ipg = sbe32(sb, 184)
        self.fpg = sbe32(sb, 188)

    # --- addressing -------------------------------------------------------
    def cgstart(self, c):
        return self.fpg * c + self.cgoffset * (c & ~self.cgmask)

    def ino_to_off(self, ino):
        c = ino // self.ipg
        base = self.cgstart(c) + self.iblkno
        fsba = base + ((ino % self.ipg) // self.inopb) * self.frag
        return self.base + fsba * self.fsize + (ino % self.inopb) * DINODE_SIZE

    def frag_off(self, fragno):
        return self.base + fragno * self.fsize

    # --- inodes -----------------------------------------------------------
    def inode(self, ino):
        self.f.seek(self.ino_to_off(ino))
        d = self.f.read(DINODE_SIZE)
        i = Inode()
        i.num = ino
        i.mode = be16(d, 0)
        i.nlink = struct.unpack_from('>h', d, 2)[0]
        i.uid, i.gid = be16(d, 4), be16(d, 6)
        i.size = be32(d, 0x0C)
        i.mtime = be32(d, 0x18)
        i.ftype = d[0x14:0x18]
        i.creator = d[0x1C:0x20]
        i.db = [be32(d, 0x28 + 4 * n) for n in range(12)]
        i.ib = [be32(d, 0x58 + 4 * n) for n in range(3)]
        i.blocks = be32(d, 0x68)
        return i

    # --- data -------------------------------------------------------------
    def _indirect(self, fragno, level, want, out):
        """Append block numbers from an indirect block, depth `level`."""
        if len(out) >= want or fragno == 0:
            return
        self.f.seek(self.frag_off(fragno))
        tbl = self.f.read(self.bsize)
        for k in range(self.nindir):
            if len(out) >= want:
                return
            b = be32(tbl, 4 * k)
            if level == 1:
                out.append(b)
            else:
                self._indirect(b, level - 1, want, out)

    def blocklist(self, i):
        """Logical block numbers (in frags, one per fs block) covering di_size."""
        nblk = (i.size + self.bsize - 1) // self.bsize
        out = list(i.db[:min(12, nblk)])
        for lvl in (1, 2, 3):
            if len(out) >= nblk:
                break
            self._indirect(i.ib[lvl - 1], lvl, nblk, out)
        return out[:nblk]

    def read(self, i):
        if i.islnk and i.size < 60:
            # fast symlink: target stored in the block-pointer area
            self.f.seek(self.ino_to_off(i.num) + 0x28)
            return self.f.read(i.size)
        data = bytearray()
        for b in self.blocklist(i):
            if b == 0:
                data += b'\0' * self.bsize
                continue
            self.f.seek(self.frag_off(b))
            data += self.f.read(self.bsize)
        return bytes(data[:i.size])

    # --- directories ------------------------------------------------------
    def readdir(self, i):
        """[(name, ino)] for a directory inode."""
        data = self.read(i)
        out, o = [], 0
        while o + 8 <= len(data):
            ino = be32(data, o)
            reclen = be16(data, o + 4)
            namlen = be16(data, o + 6)
            if reclen < 8 or o + reclen > len(data) + 8:
                break
            if ino:
                out.append((data[o + 8:o + 8 + namlen].decode('latin1'), ino))
            o += reclen
        return out

    def lookup(self, path):
        i = self.inode(2)
        for part in [p for p in path.split('/') if p]:
            if not i.isdir:
                raise ValueError("not a directory: %s" % path)
            ent = dict(self.readdir(i))
            if part not in ent:
                raise FileNotFoundError(path)
            i = self.inode(ent[part])
        return i

    def walk(self, path='/', depth=0, maxdepth=99, _seen=None):
        _seen = _seen if _seen is not None else set()
        i = self.lookup(path)
        if not i.isdir or i.num in _seen or depth > maxdepth:
            return
        _seen.add(i.num)
        for name, ino in self.readdir(i):
            if name in ('.', '..'):
                continue
            sub = path.rstrip('/') + '/' + name
            child = self.inode(ino)
            yield sub, child
            if child.isdir:
                for r in self.walk(sub, depth + 1, maxdepth, _seen):
                    yield r


def fmt(i, name):
    kind = 'd' if i.isdir else ('l' if i.islnk else '-')
    extra = ''
    if i.ftype.strip(b'\0') and i.ftype != b'\0\0\0\0':
        extra = '  [%s/%s]' % (i.ftype.decode('latin1'), i.creator.decode('latin1'))
    return "%s%s %2d %4d/%-4d %10d  %s%s" % (
        kind, oct(i.mode & 0o777)[2:].rjust(4, '0'), i.nlink, i.uid, i.gid,
        i.size, name, extra)


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 1
    img, cmd = argv[1], argv[2]
    fs = UFS(img)
    if cmd == 'parts':
        for p in read_partitions(fs.f):
            print(p)
    elif cmd == 'ls':
        d = fs.lookup(argv[3] if len(argv) > 3 else '/')
        for name, ino in sorted(fs.readdir(d)):
            print(fmt(fs.inode(ino), name))
    elif cmd == 'find':
        root = argv[3] if len(argv) > 3 else '/'
        for path, i in fs.walk(root):
            print(fmt(i, path))
    elif cmd == 'stat':
        i = fs.lookup(argv[3])
        print(fmt(i, argv[3]))
        print("  ino=%d blocks=%d db=%s ib=%s" % (i.num, i.blocks,
              [hex(x) for x in i.db], [hex(x) for x in i.ib]))
        print("  first data byte offset in image: 0x%x" % fs.frag_off(i.db[0]))
    elif cmd == 'cat':
        i = fs.lookup(argv[3])
        out = sys.stdout.buffer if len(argv) < 5 else open(argv[4], 'wb')
        out.write(fs.read(i))
        out.flush()
    else:
        print("unknown command", cmd)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
