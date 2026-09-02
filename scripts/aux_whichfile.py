#!/usr/bin/env python3
"""Map raw image byte offsets in the A/UX root slice back to file paths.

Builds a frag -> path index by walking every inode's block list once, then
answers offset queries.  Useful when a raw scan of the .hda turns up an
interesting constant and you want to know which file it lives in.

    python3 scripts/aux_whichfile.py IMAGE 0x6C88000 0x8C9E4 ...
    python3 scripts/aux_whichfile.py IMAGE --grep 'c94_cancel'
"""

import re
import sys

sys.path.insert(0, __file__.rsplit('/', 1)[0] if '/' in __file__ else '.')
from aux_ufs import UFS  # noqa: E402


def build_index(fs):
    """frag number -> (path, offset within file)."""
    idx = {}
    for path, i in fs.walk('/'):
        if not i.isreg or i.size == 0:
            continue
        try:
            blks = fs.blocklist(i)
        except Exception:
            continue
        fpb = fs.bsize // fs.fsize          # frags per block
        for n, b in enumerate(blks):
            if b == 0:
                continue
            for k in range(fpb):
                idx[b + k] = (path, n * fs.bsize + k * fs.fsize)
    return idx


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 1
    fs = UFS(argv[1])
    idx = build_index(fs)
    sys.stderr.write("indexed %d frags\n" % len(idx))

    if argv[2] == '--grep':
        pat = argv[3].encode() if len(argv) > 3 else b''
        f = open(argv[1], 'rb')
        f.seek(fs.base)
        pos, CH = fs.base, 1 << 22
        while True:
            buf = f.read(CH)
            if not buf:
                break
            for m in re.finditer(re.escape(pat), buf):
                report(fs, idx, pos + m.start())
            pos += len(buf) - 64
            f.seek(pos)
        return 0

    for a in argv[2:]:
        report(fs, idx, int(a, 0))
    return 0


def report(fs, idx, off):
    frag = (off - fs.base) // fs.fsize
    hit = idx.get(frag)
    if hit:
        path, base = hit
        print("0x%08x -> %s + 0x%x" % (off, path, base + (off - fs.base) % fs.fsize))
    else:
        print("0x%08x -> (free space / metadata / not in any file)" % off)


if __name__ == '__main__':
    sys.exit(main(sys.argv))
