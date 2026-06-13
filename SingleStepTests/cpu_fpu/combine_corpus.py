#!/usr/bin/env python3
"""Build the combined CPU/FPU full corpus: FSAVE/FRESTORE FIRST, then the
math baseline.

This is the make/script step that keeps the CIR save/restore tests at the
FRONT of the full corpus and survives regeneration — regenerating
fpu_corpus_baseline.json from MAME does not touch save_restore_corpus.json,
and re-running this script rebuilds the combined corpus with save/restore
still first.

Order rationale:
  * the full run aborts ~test 1248 under MAME (an unrelated FMOVEM gap), so
    anything at the tail would never execute — front-loading guarantees the
    save/restore tests run;
  * a CIR save/restore wedge is worth catching before grinding through the
    1328 math tests.

Outputs (JSON arrays, sim_main.cpp / the supervisor bench consume them):
  cpu_fpu_full_corpus.json   save_restore_corpus.json ++ fpu_corpus_baseline.json

NOTE: FSAVE/FRESTORE are PRIVILEGED. This combined corpus is for the
supervisor-mode venues only (Verilator cpu_fpu bench — supervisor after
reset — and preboot/supervisor_bench). Do NOT feed it to the user-mode
Mac OS CpuFpuBench app; that keeps using cpu_fpu_tests.h (baseline only).
"""

import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
SOURCES = ["save_restore_corpus.json", "fpu_corpus_baseline.json"]
OUT = os.path.join(HERE, "cpu_fpu_full_corpus.json")


def main():
    combined = []
    for src in SOURCES:
        with open(os.path.join(HERE, src)) as f:
            rows = json.load(f)
        print(f"  {src}: {len(rows)} tests")
        combined += rows

    with open(OUT, "w") as f:
        f.write("[\n")
        for i, r in enumerate(combined):
            prog = ",".join(str(b) for b in r["program"])
            f.write('  {"name":%s, "op_a":%d, "program":[%s], "result_reg":%d, "expected":%d}%s\n'
                    % (json.dumps(r["name"]), r["op_a"], prog,
                       r["result_reg"], r["expected"],
                       "" if i == len(combined) - 1 else ","))
        f.write("]\n")
    print(f"wrote {OUT}: {len(combined)} tests "
          f"(save/restore first, then baseline)")


if __name__ == "__main__":
    main()
