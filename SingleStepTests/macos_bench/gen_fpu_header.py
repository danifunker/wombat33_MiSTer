#!/usr/bin/env python3
# Generate fpu_tests.h for the Mac-side FPU bench.
#
# This is the Python sibling of SingleStepTests/gen/mame_fpu_capture.lua's
# tests-table builder. It produces the same operand pool, the same op
# tables, and the same byte streams -- but without requiring MAME, so we
# can populate the Mac bench's test catalog independently of an oracle run.
# The two MUST stay in sync (test names + bytes); when the Lua script
# eventually runs to produce /tmp/fpu_corpus.json the records will line up
# by name and the diff tool can compare hardware against MAME.

import os

# ---------------------------------------------------------------------------
# Operand pool: 12-byte extended-precision big-endian representations.
# Mirror of mame_fpu_capture.lua OPERANDS table (lines 218-242).
# ---------------------------------------------------------------------------
OPERANDS = {
    "pos_zero":   [0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00],
    "neg_zero":   [0x80,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00],
    "pos_one":    [0x3F,0xFF,0x00,0x00, 0x80,0x00,0x00,0x00, 0x00,0x00,0x00,0x00],
    "neg_one":    [0xBF,0xFF,0x00,0x00, 0x80,0x00,0x00,0x00, 0x00,0x00,0x00,0x00],
    "pos_two":    [0x40,0x00,0x00,0x00, 0x80,0x00,0x00,0x00, 0x00,0x00,0x00,0x00],
    "neg_two":    [0xC0,0x00,0x00,0x00, 0x80,0x00,0x00,0x00, 0x00,0x00,0x00,0x00],
    "pos_half":   [0x3F,0xFE,0x00,0x00, 0x80,0x00,0x00,0x00, 0x00,0x00,0x00,0x00],
    "neg_half":   [0xBF,0xFE,0x00,0x00, 0x80,0x00,0x00,0x00, 0x00,0x00,0x00,0x00],
    "pos_three":  [0x40,0x00,0x00,0x00, 0xC0,0x00,0x00,0x00, 0x00,0x00,0x00,0x00],
    "pi":         [0x40,0x00,0x00,0x00, 0xC9,0x0F,0xDA,0xA2, 0x21,0x68,0xC2,0x35],
    "pi_half":    [0x3F,0xFF,0x00,0x00, 0xC9,0x0F,0xDA,0xA2, 0x21,0x68,0xC2,0x35],
    "pi_quarter": [0x3F,0xFE,0x00,0x00, 0xC9,0x0F,0xDA,0xA2, 0x21,0x68,0xC2,0x35],
    "e":          [0x40,0x00,0x00,0x00, 0xAD,0xF8,0x54,0x58, 0xA2,0xBB,0x4A,0x9A],
    "ten":        [0x40,0x02,0x00,0x00, 0xA0,0x00,0x00,0x00, 0x00,0x00,0x00,0x00],
    "big":        [0x40,0x40,0x00,0x00, 0x80,0x00,0x00,0x00, 0x00,0x00,0x00,0x00],
    "tiny":       [0x3F,0xC0,0x00,0x00, 0x80,0x00,0x00,0x00, 0x00,0x00,0x00,0x00],
    "pos_inf":    [0x7F,0xFF,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00],
    "neg_inf":    [0xFF,0xFF,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00],
    "qnan":       [0x7F,0xFF,0x00,0x00, 0xC0,0x00,0x00,0x00, 0x00,0x00,0x00,0x00],
}

# ---------------------------------------------------------------------------
# Instruction emitters (mirror of mame_fpu_capture.lua emit_* helpers).
# ---------------------------------------------------------------------------
def _be16(v):
    return [(v >> 8) & 0xFF, v & 0xFF]

def emit_fmove_x_imm_to_fp(fpn, op_bytes):
    """FMOVE.X #imm, FPn -- 4 opcode bytes + 12 immediate bytes."""
    opword = 0xF23C
    ext    = 0x4800 | ((fpn & 7) << 7)
    return _be16(opword) + _be16(ext) + list(op_bytes)

def emit_fop_x_reg_to_reg(opmode, src_fpn, dst_fpn):
    """Register-direct FP op: FPm -> FPn (R/M=0). 4 bytes."""
    opword = 0xF200
    ext    = ((src_fpn & 7) << 10) | ((dst_fpn & 7) << 7) | (opmode & 0x7F)
    return _be16(opword) + _be16(ext)

# ---------------------------------------------------------------------------
# Op catalogs (mirror of DYADIC_OPS / MONADIC_OPS / TRANSCENDENTAL_OPS).
# ---------------------------------------------------------------------------
DYADIC_OPS = [
    ("FADD",    0x22),
    ("FSUB",    0x28),
    ("FMUL",    0x23),
    ("FDIV",    0x20),
    ("FCMP",    0x38),
    ("FMOD",    0x21),
    ("FREM",    0x25),
    ("FSCALE",  0x26),
    ("FSGLDIV", 0x24),
    ("FSGLMUL", 0x27),
]

MONADIC_OPS = [
    ("FABS",    0x18),
    ("FNEG",    0x1A),
    ("FSQRT",   0x04),
    ("FINT",    0x01),
    ("FINTRZ",  0x03),
    ("FGETEXP", 0x1E),
    ("FGETMAN", 0x1F),
    ("FTST",    0x3A),
]

TRANSCENDENTAL_OPS = [
    ("FSIN",    0x0E),
    ("FCOS",    0x1D),
    ("FTAN",    0x0F),
    ("FATAN",   0x0A),
    ("FETOX",   0x10),
    ("FETOXM1", 0x08),
    ("FLOGN",   0x14),
    ("FLOG10",  0x15),
    ("FLOG2",   0x16),
    ("FLOGNP1", 0x06),
    ("FTENTOX", 0x12),
    ("FTWOTOX", 0x11),
]

DYADIC_PAIRS = [
    ("pos_one",  "pos_one"),
    ("pos_one",  "pos_two"),
    ("pos_two",  "pos_one"),
    ("pos_one",  "neg_one"),
    ("pi",       "e"),
    ("pos_one",  "pos_zero"),
    ("pos_zero", "pos_one"),
    ("pos_inf",  "pos_one"),
    ("pos_inf",  "pos_inf"),
    ("pos_one",  "qnan"),
    ("big",      "tiny"),
    ("ten",      "pos_three"),
]

MONADIC_VALUES = [
    "pos_zero", "neg_zero", "pos_one", "neg_one", "pos_two", "pos_half",
    "pi", "e", "pos_inf", "neg_inf", "qnan",
]

TRANS_VALUES = ["pos_zero", "pos_half", "pos_one", "pi_quarter", "pi"]

# ---------------------------------------------------------------------------
# Test builders.
# ---------------------------------------------------------------------------
# 68040 on-chip FPU: opmodes implemented in HARDWARE (these execute).
# Everything else (transcendentals, FMOD/FREM/FSCALE, FSGLMUL/FSGLDIV,
# FGETEXP/FGETMAN) takes the unimplemented-FP exception (vector 11) so
# FPSP040 can emulate it. On a Quadra 800 FPGA core in MC68040-lite mode
# without FPSP loaded, the observable is the trap, not a result.
HW_OPMODES = {
    0x00,  # FMOVE
    0x01,  # FINT
    0x03,  # FINTRZ
    0x04,  # FSQRT
    0x18,  # FABS
    0x1A,  # FNEG
    0x20,  # FDIV
    0x22,  # FADD
    0x23,  # FMUL
    0x28,  # FSUB
    0x38,  # FCMP
    0x3A,  # FTST
}
FP_UNIMP_VECTOR = 11

def op_traps(opmode):
    return 0 if opmode in HW_OPMODES else 1

def make_dyadic(name, opmode, a, b):
    traps = op_traps(opmode)
    return {
        "name": f"{name}.X FP1,FP0 ({a},{b})"
                + (" [040-unimpl->vec11]" if traps else ""),
        "preload": emit_fmove_x_imm_to_fp(0, OPERANDS[a])
                 + emit_fmove_x_imm_to_fp(1, OPERANDS[b]),
        "test": emit_fop_x_reg_to_reg(opmode, 1, 0),
        "traps": traps,
        "exc_vec": FP_UNIMP_VECTOR if traps else 0,
    }

def make_monadic(name, opmode, a):
    traps = op_traps(opmode)
    return {
        "name": f"{name}.X FP0 ({a})"
                + (" [040-unimpl->vec11]" if traps else ""),
        "preload": emit_fmove_x_imm_to_fp(0, OPERANDS[a]),
        "test": emit_fop_x_reg_to_reg(opmode, 0, 0),
        "traps": traps,
        "exc_vec": FP_UNIMP_VECTOR if traps else 0,
    }

def build_tests():
    tests = [
        # Smoke tests kept from the bring-up phase.
        {"name": "DBG: MOVEQ #5,D0 (no FPU)",
         "preload": [], "test": [0x70, 0x05], "traps": 0, "exc_vec": 0},
        {"name": "FMOVE.L #1,FP0 (sanity)",
         "preload": [], "test": [0x70, 0x01, 0xF2, 0x00, 0x40, 0x00],
         "traps": 0, "exc_vec": 0},
    ]
    for name, opmode in DYADIC_OPS:
        for a, b in DYADIC_PAIRS:
            tests.append(make_dyadic(name, opmode, a, b))
    for name, opmode in MONADIC_OPS:
        for v in MONADIC_VALUES:
            tests.append(make_monadic(name, opmode, v))
    for name, opmode in TRANSCENDENTAL_OPS:
        for v in TRANS_VALUES:
            tests.append(make_monadic(name, opmode, v))
    return tests

# ---------------------------------------------------------------------------
# Header emitter -- matches mame_fpu_capture.lua emit_tests_h output so the
# Mac bench can consume either source.
# ---------------------------------------------------------------------------
def emit_header(tests, out_path):
    max_pre = max((len(t["preload"]) for t in tests), default=0)
    max_tst = max((len(t["test"])    for t in tests), default=0)
    pre_cap = max(max_pre, 40)
    tst_cap = max(max_tst,  8)

    with open(out_path, "w") as f:
        f.write("/* Auto-generated by SingleStepTests/macos_bench/gen_fpu_header.py.\n")
        f.write(" * Do not edit by hand -- regenerate by re-running the script.\n")
        f.write(" *\n")
        f.write(" * Mirrors the test corpus produced by\n")
        f.write(" * SingleStepTests/gen/mame_fpu_capture.lua so the two stay in lockstep;\n")
        f.write(" * names + byte streams are identical, only the MAME oracle is missing. */\n")
        f.write("#ifndef FPU_TESTS_H\n")
        f.write("#define FPU_TESTS_H\n\n")
        f.write(f"#define FPU_TEST_MAX_PRELOAD {pre_cap}  /* widest preload observed: {max_pre} */\n")
        f.write(f"#define FPU_TEST_MAX_TEST    {tst_cap}  /* widest test bytes observed: {max_tst} */\n\n")
        f.write("typedef struct {\n")
        f.write("    const char *name;\n")
        f.write("    unsigned char preload[FPU_TEST_MAX_PRELOAD];\n")
        f.write("    unsigned short preload_len;\n")
        f.write("    unsigned char test[FPU_TEST_MAX_TEST];\n")
        f.write("    unsigned short test_len;\n")
        f.write("    unsigned char traps;    /* 1 = 68040 unimplemented-FP trap */\n")
        f.write("    unsigned char exc_vec;  /* expected vector when traps=1 (11) */\n")
        f.write("} FpuTestSpec;\n\n")
        f.write("static const FpuTestSpec g_fpu_tests[] = {\n")
        for t in tests:
            pre = t["preload"]
            tst = t["test"]
            pre_str = "{0}" if not pre else "{" + ",".join(f"0x{b:02X}" for b in pre) + "}"
            tst_str = "{" + ",".join(f"0x{b:02X}" for b in tst) + "}"
            # Escape backslashes and quotes for C string literal.
            cname = t["name"].replace("\\", "\\\\").replace("\"", "\\\"")
            f.write(f"    {{\"{cname}\",\n")
            f.write(f"      {pre_str}, {len(pre)},\n")
            f.write(f"      {tst_str}, {len(tst)}, {t.get('traps',0)}, {t.get('exc_vec',0)}}},\n")
        f.write("};\n\n")
        f.write("#define FPU_N_TESTS ((unsigned short)(sizeof(g_fpu_tests)/sizeof(g_fpu_tests[0])))\n\n")
        f.write("#endif /* FPU_TESTS_H */\n")

def main():
    here = os.path.dirname(os.path.abspath(__file__))
    out_path = os.path.join(here, "fpu_tests.h")
    tests = build_tests()
    emit_header(tests, out_path)
    print(f"Wrote {out_path}: {len(tests)} tests "
          f"({len(DYADIC_OPS)*len(DYADIC_PAIRS)} dyadic, "
          f"{len(MONADIC_OPS)*len(MONADIC_VALUES)} monadic, "
          f"{len(TRANSCENDENTAL_OPS)*len(TRANS_VALUES)} transcendental, 2 smoke).")

if __name__ == "__main__":
    main()
