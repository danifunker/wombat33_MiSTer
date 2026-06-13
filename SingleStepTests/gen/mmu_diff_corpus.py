#!/usr/bin/env python3
"""mmu_diff_corpus.py -- compare a 68040 MMU bench run (real Quadra 800
via preboot/supervisor_bench/mmu_bench_main.c, or the MAME harness build)
against the MAME oracle corpus (results/mmu/mame_baseline_*.json).

The 68040 MMU corpus uses a single identity page table (root/pointer/
page) mapping va $00000..$3FFFF; see gen/mame_mmu_capture.lua for the
fixed addresses. The hardware runner RELOCATES those fixed addresses into
payload statics and reports the mapping in its first JSONL line
({"reloc":...}); this tool translates corpus-side addresses through that
mapping before comparing descriptor address fields and An values.

MMU registers compared every row: tc, itt0, itt1, dtt0, dtt1, urp, srp,
mmusr. NOTE: MAME's 040 PTEST/MMUSR is impoverished (see the capture
header) -- rows flagged hw_unsafe with PTEST bytes are reported but their
mmusr mismatch is informational; the Quadra 800 silicon is authoritative.

Fault rows (raises_exception): the epilogue never ran, so GP registers
and payload-relative frame fields aren't compared -- only the taken
vector (2), the table/remap windows, and the stacked frame's format/
vector word.

Usage:
  mmu_diff_corpus.py <mame_baseline.json> <bench_run.jsonl> [--verbose]
"""
import json
import sys

# (base, length) -- must match WINDOWS in mame_mmu_capture.lua.
DATA, ROOT, PTR, PAGE = 0x1800, 0x3000, 0x3200, 0x3400
REMAP1, REMAP2, STACK = 0x1F000, 0x1E000, 0x3FFA0
WINDOWS = [(DATA, 0x40), (ROOT, 0x20), (PTR, 0x20), (PAGE, 0x100),
           (REMAP1, 0x40), (REMAP2, 0x40), (STACK, 0x60)]
TABLE_WINDOWS = {ROOT, PTR, PAGE}

MMU_FIELDS = ("tc", "itt0", "itt1", "dtt0", "dtt1", "urp", "srp", "mmusr")

U_BIT = 0x08   # descriptor "used" flag (any walk sets it)
M_BIT = 0x10   # page-descriptor "modified" flag (any write sets it)


def load_jsonl(path):
    rows = []
    for line in open(path, "rb").read().decode("ascii", "replace").splitlines():
        line = line.strip().strip("\x00").rstrip()
        if not line or not line.startswith("{"):
            continue
        try:
            rows.append(json.loads(line))
        except json.JSONDecodeError:
            pass
    return rows


class Reloc:
    REGIONS = [("data", DATA, 0x40), ("root", ROOT, 0x200),
               ("ptr", PTR, 0x200), ("page", PAGE, 0x100),
               ("remap1", REMAP1, 0x1000), ("remap2", REMAP2, 0x1000)]

    def __init__(self, hdr):
        self.map = hdr

    def addr(self, a):
        for name, base, size in self.REGIONS:
            if base <= a < base + size:
                return self.map.get(name, base) + (a - base)
        if a == 0x40000:
            return self.map.get("stack_top", a)
        return a

    def desc(self, v):
        """Relocate the address field of a 68040 descriptor, leave flags."""
        pdt = v & 3
        if pdt == 0:
            return v
        # page descriptor: pa in bits 31-12; table descriptor: addr in 31-9.
        # Either way relocate the high address part, keep the low flag bits.
        return self.addr(v & 0xFFFFF000) | (v & 0xFFF)


def corpus_expected_windows(row):
    mem = {}
    for a, b in row["initial"]["ram"]:
        mem[a] = b
    for a, b in row["final"]["ram"]:
        mem[a] = b
    out = {}
    for base, length in WINDOWS:
        out[base] = [mem.get(base + i, 0) for i in range(length)]
    return out


def bench_windows(brow):
    out = {}
    for w in brow.get("windows", []):
        data = bytes.fromhex(w["hex"]) if "hex" in w else bytes(w["bytes"])
        out[w["base"]] = list(data)
    return out


def translate_table_window(reloc, expected):
    out = list(expected)
    for i in range(0, len(expected), 4):
        v = int.from_bytes(bytes(expected[i:i+4]), "big")
        out[i:i+4] = reloc.desc(v).to_bytes(4, "big")
    return out


def mask_placement_bits(buf):
    """On live/fault rows clear U everywhere (any walk sets it). M stays
    strict -- it is the write-translation signal we care about."""
    out = list(buf)
    for i in range(3, len(out), 4):
        out[i] &= ~U_BIT & 0xFF
    return out


def main():
    verbose = "--verbose" in sys.argv
    base_rows = {r["name"]: r for r in load_jsonl(sys.argv[1])}
    bench = load_jsonl(sys.argv[2])

    reloc = None
    n_pass = n_fail = n_skip = n_info = 0
    for brow in bench:
        if "reloc" in brow:
            reloc = Reloc(brow["reloc"])
            continue
        name = brow.get("name")
        if name is None or reloc is None:
            continue
        if brow.get("skipped"):
            n_skip += 1
            continue
        crow = base_rows.get(name)
        if crow is None:
            print(f"?? no corpus row: {name}")
            n_fail += 1
            continue

        problems = []
        info_only = "hw-adjudicated" in name or "PTEST" in name
        is_fault = crow["flags"]["raises_exception"]

        want_vec = 2 if is_fault else 0
        if brow.get("vec", 0) != want_vec:
            problems.append(f"vec: got {brow.get('vec')}, expected {want_vec}")

        cm, bm = crow["final"]["mmu"], brow["final"]["mmu"]
        for k in MMU_FIELDS:
            if k not in cm or k not in bm:
                continue
            want = cm[k]
            if k in ("urp", "srp"):
                want_alt = reloc.addr(cm[k])
                if bm[k] not in (want, want_alt):
                    problems.append(f"mmu.{k}: got {bm[k]:#x}, expected "
                                    f"{want:#x} or {want_alt:#x}")
                continue
            if bm[k] != want and not (k == "mmusr" and info_only):
                problems.append(f"mmu.{k}: got {bm[k]:#x}, expected {want:#x}")

        if not is_fault and brow.get("regs_valid"):
            cd, ca = crow["final"]["d"], crow["final"]["a"]
            bd, ba = brow["final"]["d"], brow["final"]["a"]
            for i in range(8):
                if bd[i] != cd[i]:
                    problems.append(f"d{i}: got {bd[i]:#x}, expected {cd[i]:#x}")
            for i in range(7):
                if ba[i] not in (ca[i], reloc.addr(ca[i])):
                    problems.append(f"a{i}: got {ba[i]:#x}, expected "
                                    f"{ca[i]:#x} or {reloc.addr(ca[i]):#x}")

        cw = corpus_expected_windows(crow)
        bw = bench_windows(brow)
        live = crow["flags"]["mmu_live"] or is_fault
        for base, length in WINDOWS:
            if base not in bw:
                continue
            expected = cw[base]
            if base in TABLE_WINDOWS:
                expected = translate_table_window(reloc, expected)
            got = bw[base]
            if base in TABLE_WINDOWS and live:
                expected = mask_placement_bits(expected)
                got = mask_placement_bits(got)
            if base == STACK:
                if not is_fault:
                    if any(got):
                        problems.append("stack window dirty on non-fault row")
                else:
                    a7_off = crow["final"]["a"][7] - STACK
                    fv_off = a7_off + 6
                    if 0 <= fv_off < length - 1 and \
                       got[fv_off:fv_off+2] != expected[fv_off:fv_off+2]:
                        problems.append(
                            f"frame fmt/vec: got "
                            f"{bytes(got[fv_off:fv_off+2]).hex()}, expected "
                            f"{bytes(expected[fv_off:fv_off+2]).hex()}")
                continue
            if got != expected:
                diffs = [i for i in range(length) if got[i] != expected[i]]
                problems.append(f"window ${base:X}: {len(diffs)} byte diffs at "
                                f"+{[hex(d) for d in diffs[:8]]}")

        if problems and info_only:
            n_info += 1
            if verbose:
                print(f"INFO {name} (hardware-adjudicated)")
                for p in problems:
                    print(f"      {p}")
        elif problems:
            n_fail += 1
            print(f"FAIL {name}")
            for p in problems[: None if verbose else 4]:
                print(f"      {p}")
        else:
            n_pass += 1
            if verbose:
                print(f"PASS {name}")

    print(f"\n{n_pass} passed, {n_fail} failed, {n_skip} skipped, "
          f"{n_info} hw-adjudicated (corpus rows: {len(base_rows)})")
    return 1 if n_fail else 0


if __name__ == "__main__":
    sys.exit(main())
