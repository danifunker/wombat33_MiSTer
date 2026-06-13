/*
 * FPU test corpus generator for the Macintosh Quadra 800 (MC68040).
 *
 * The 68040 has an on-chip FPU that is itself the device under test, so
 * gen_fpu.c is a SELF-CONTAINED oracle: it computes IEEE results on the
 * host for the ops the 68040 implements in hardware, and tags the ops the
 * 68040 does NOT implement so the bench can verify they trap.
 *
 * TWO CLASSES OF TEST (the FPU bench's execute-vs-trap discriminator):
 *   1. EXECUTE (traps=0): the 68040 hardware arithmetic subset -- FADD,
 *      FSUB, FMUL, FDIV, FSQRT, FNEG, FABS, FINT, FINTRZ, FCMP, FMOVE,
 *      FMOVEM, FScc/FBcc/FDBcc/FTRAPcc/FNOP. Expected = computed IEEE.
 *   2. TRAP (traps=1, exc_vec=11): the transcendental / exponential /
 *      logarithmic / FMOD-FREM / FSGLMUL-FSGLDIV / FGETEXP-FGETMAN ops
 *      the 68040 leaves to FPSP040 software. Expected = the unimplemented-
 *      FP exception (vector 11). MAME wrongly EXECUTES these, so MAME is
 *      not the oracle for class 2 -- the 68040 manual is.
 *
 * Historical note (origin = lbmactwo Mac II project): each test exercised
 * one FPU instruction round-trip through a TG68K + mc68881_top Verilator
 * bench; that path is retained for the verilator FPU harness (fpu/,
 * cpu_fpu/) targeting the 68881-fpga lite-mode core, while the preboot
 * bench runs the same corpus on real Quadra 800 silicon. The program
 * template is unchanged:
 *
 * Test program template:
 *   MOVEQ #op_a,D0         ; load op_a into D0
 *   FMOVE.L D0,FP0         ; load FP0 from D0 (cp_xfer_to)
 *   [if dyadic:
 *     MOVEQ #op_b,D0       ; load op_b into D0
 *     FMOVE.L D0,FP1       ; load FP1 from D0
 *   ]
 *   <test_instruction>     ; FADD FP1,FP0 / FNEG FP0,FP0 / etc.
 *   FMOVE.L FP0,D{rreg}    ; store result back to Dn (cp_xfer_from)
 *   STOP #$2700            ; halt
 *
 * Bench checks D{rreg} == expected after halt.
 *
 * Operand range is MOVEQ's signed 8-bit (-128..127). FMUL operands further
 * restricted so the product fits int32.
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

/* ---------- Tiny seeded RNG (xorshift32) ----------------------------- */
static uint32_t g_rng = 0xBEEFC0DEu;
static uint32_t r32(void) {
    uint32_t x = g_rng;
    x ^= x << 13; x ^= x >> 17; x ^= x << 5;
    return g_rng = x;
}
/* Random signed byte in MOVEQ range. */
static int8_t r_moveq(void) { return (int8_t)(r32() & 0xFF); }
/* Random signed byte limited to ±limit. */
static int8_t r_moveq_lim(int limit) {
    int8_t v = (int8_t)(r32() % (2 * limit + 1));
    return v - (int8_t)limit;
}

/* ---------- M68881 op encodings ------------------------------------- */
/* Reg-to-reg ALU (opclass 000) ext word:
 *   bits 15-13 = 000
 *   bits 12-10 = src FP register
 *   bits  9-7  = dst FP register
 *   bits  6-0  = opmode (M68881 native cpGEN opmode)
 */
/* --- 68040 hardware-implemented arithmetic opmodes (these EXECUTE) --- */
#define OPMODE_FADD   0x22
#define OPMODE_FSUB   0x28
#define OPMODE_FMUL   0x23
#define OPMODE_FDIV   0x20
#define OPMODE_FSQRT  0x04
#define OPMODE_FNEG   0x1A
#define OPMODE_FABS   0x18
#define OPMODE_FINT   0x01
#define OPMODE_FINTRZ 0x03

/* --- 68040 UNIMPLEMENTED FP-instruction opmodes (these TRAP) ---------
 * The MC68040 on-chip FPU implements only the arithmetic subset above
 * (plus FCMP/FTST/FMOVE/control). Every transcendental, exponential,
 * logarithmic, modulo, and single-precision-rounded op below is decoded
 * but NOT executed in silicon: the 68040 takes an "Unimplemented
 * Floating-Point Instruction" exception through VECTOR 11 (the Line-F /
 * F-line emulator vector) with a format-$2 stack frame, where Apple's
 * FPSP040 software would emulate it. On a Quadra 800 FPGA core built in
 * MC68040-lite mode (no transcendental engine) and WITHOUT FPSP loaded,
 * the observable result is the vector-11 trap and an unmodified FPn.
 * MAME, by contrast, wrongly executes all of these -- so MAME is NOT the
 * oracle for these rows; the expected behavior here (trap) comes from
 * the 68040 manual. */
#define OPMODE_FMOD     0x21
#define OPMODE_FREM     0x25
#define OPMODE_FSCALE   0x26
#define OPMODE_FSGLMUL  0x27
#define OPMODE_FSGLDIV  0x24
#define OPMODE_FGETEXP  0x1E
#define OPMODE_FGETMAN  0x1F
#define OPMODE_FSINH    0x02
#define OPMODE_FLOGNP1  0x06
#define OPMODE_FETOXM1  0x08
#define OPMODE_FTANH    0x09
#define OPMODE_FATAN    0x0A
#define OPMODE_FASIN    0x0C
#define OPMODE_FATANH   0x0D
#define OPMODE_FSIN     0x0E
#define OPMODE_FTAN     0x0F
#define OPMODE_FETOX    0x10
#define OPMODE_FTWOTOX  0x11
#define OPMODE_FTENTOX  0x12
#define OPMODE_FLOGN    0x14
#define OPMODE_FLOG10   0x15
#define OPMODE_FLOG2    0x16
#define OPMODE_FCOSH    0x19
#define OPMODE_FACOS    0x1C
#define OPMODE_FCOS     0x1D
#define OPMODE_FSINCOS  0x30   /* FSINCOS FPc:FPs,FPx -> opmode 0x30|FPc */

/* 68040 unimplemented-FP-instruction exception vector. */
#define FP_UNIMP_VECTOR 11

/* ext for monadic op (FNEG/FABS/...): src and dst both = fp, opmode. */
static uint16_t ext_monadic_fp(int fp, uint8_t opmode) {
    return (uint16_t)(((fp & 7) << 10) | ((fp & 7) << 7) | opmode);
}
/* ext for dyadic reg-to-reg: dst = dst op src; src=FPm, dst=FPn. */
static uint16_t ext_dyadic(int fpm_src, int fpn_dst, uint8_t opmode) {
    return (uint16_t)(((fpm_src & 7) << 10) | ((fpn_dst & 7) << 7) | opmode);
}

/* MOVEQ #imm,D0: opcode 0x7000 | (D0<<9) | imm = 0x7000 | imm (D0=0). */
static uint16_t moveq_d0(int8_t imm) { return (uint16_t)(0x7000 | (uint8_t)imm); }
/* MOVE.L #imm,D0: opword 0x203C, then 4-byte big-endian immediate. Used to
 * load a full 32-bit value when MOVEQ's signed-8-bit range isn't enough
 * (e.g. an IEEE single bit pattern for FMOVE.S). */
#define MOVE_L_IMM_D0 ((uint16_t)0x203C)
/* IEEE 754 single-precision bit pattern for a small integer. Uses native
 * float→bits punning; portable enough for our test generator host. */
#include <string.h>
static uint32_t int_to_ieee_single(int n) {
    float f = (float)n;
    uint32_t bits;
    memcpy(&bits, &f, 4);
    return bits;
}
/* FMOVE.{size} D0,FPn: opword $F200 | EA(D0=0) = $F200; ext = opclass 010
 * (EA→FPn), src fmt in bits 12-10 (L=0, S=1, X=2, P=3, W=4, D=5, B=6),
 * dst FPn (n<<7), opmode FMOVE (0x00). */
#define FMT_L 0
#define FMT_S 1
#define FMT_X 2
#define FMT_W 4
#define FMT_B 6
static uint16_t fmove_size_d0_fpn(int n, int fmt) {
    return (uint16_t)(0x4000 | ((fmt & 7) << 10) | ((n & 7) << 7));
}
/* (Convenience helpers for individual sizes are inlined at call sites via
 * fmove_size_d0_fpn(n, FMT_*); no per-size wrappers needed.) */
/* (FMOVE.L FPn,Dx opword/ext are built in emit_program below using
 *  fmove_l_fpn_dn_opw and the dst_fp parameter.) */

/* ---------- JSON emission ------------------------------------------- */
typedef struct {
    const char* name;
    int      has_b;        /* 1 = dyadic (also load src_fp) */
    int      op_a;         /* op_a value -> dst_fp */
    int      op_b;         /* op_b value -> src_fp (dyadic only) */
    int      dst_fp;       /* FPn that holds op_a / receives result (0..7) */
    int      src_fp;       /* FPm that holds op_b (dyadic only) */
    uint8_t  opmode;       /* test instruction opmode */
    int      load_fmt;     /* FMT_L / FMT_W / FMT_B for the FMOVE EA→FPn load */
    int      result_reg;   /* Dn that receives FMOVE.L FP{dst_fp},Dn */
    int32_t  expected;     /* expected value of D{result_reg} (execute rows) */
    int      traps;        /* 1 = 68040 takes the unimplemented-FP trap */
    int      exc_vec;      /* expected exception vector when traps=1 (11) */
} test_t;

static uint16_t fmove_l_fpn_dn_opw(int n) {
    /* FMOVE.L FPn,Dx opword = $F200 | Dx-mode-reg = $F200 | n (mode 0). */
    return (uint16_t)(0xF200 | (n & 7));
}

static void emit_program(FILE* f, const test_t* t) {
    fprintf(f, "[");
    int first = 1;
    #define BW(w) do { \
        if (!first) fprintf(f, ","); \
        fprintf(f, "%u,%u", ((unsigned)(w) >> 8) & 0xFF, (unsigned)(w) & 0xFF); \
        first = 0; \
    } while (0)

    /* Load op_a into FP{dst_fp} using configured size. For FMT_S the
     * operand is the IEEE-single bit pattern of op_a, which needs
     * MOVE.L #imm,D0 (6 bytes) instead of MOVEQ. */
    if (t->load_fmt == FMT_S) {
        uint32_t bits_a = int_to_ieee_single(t->op_a);
        BW(MOVE_L_IMM_D0);
        BW((uint16_t)(bits_a >> 16));
        BW((uint16_t)(bits_a & 0xFFFF));
    } else {
        BW(moveq_d0((int8_t)t->op_a));
    }
    BW(0xF200);
    BW(fmove_size_d0_fpn(t->dst_fp, t->load_fmt));
    /* If dyadic, load op_b into FP{src_fp} (same size). */
    if (t->has_b) {
        if (t->load_fmt == FMT_S) {
            uint32_t bits_b = int_to_ieee_single(t->op_b);
            BW(MOVE_L_IMM_D0);
            BW((uint16_t)(bits_b >> 16));
            BW((uint16_t)(bits_b & 0xFFFF));
        } else {
            BW(moveq_d0((int8_t)t->op_b));
        }
        BW(0xF200);
        BW(fmove_size_d0_fpn(t->src_fp, t->load_fmt));
    }
    /* Test instruction. */
    BW(0xF200);
    BW(t->has_b
       ? ext_dyadic(t->src_fp, t->dst_fp, t->opmode)
       : ext_monadic_fp(t->dst_fp, t->opmode));
    /* FMOVE.L FP{dst_fp},D{result_reg} */
    BW(fmove_l_fpn_dn_opw(t->result_reg));
    BW((uint16_t)(0x6000 | ((t->dst_fp & 7) << 7)));
    /* STOP #$2700 */
    BW(0x4E72);
    BW(0x2700);
    #undef BW
    fprintf(f, "]");
}

static void emit_test_clean(FILE* f, int is_first, const test_t* t) {
    if (!is_first) fprintf(f, ",\n");
    fprintf(f, "  {\n");
    fprintf(f, "    \"name\":\"%s\",\n", t->name);
    fprintf(f, "    \"op_a\":%d,", t->op_a);
    if (t->has_b) fprintf(f, "\"op_b\":%d,", t->op_b);
    fprintf(f, "\n    \"program\":");
    emit_program(f, t);
    fprintf(f, ",\n    \"result_reg\":%d,\n", t->result_reg);
    fprintf(f, "    \"expected\":%d", t->expected);
    if (t->traps)
        fprintf(f, ",\n    \"traps\":1,\n    \"exc_vec\":%d\n", t->exc_vec);
    else
        fprintf(f, ",\n    \"traps\":0\n");
    fprintf(f, "  }");
}

/* Pick a random FP register 0..7. */
static int pick_fp(void) { return (int)(r32() & 7); }
/* Pick a random Dn 1..7 (avoid D0, used as temp during FMOVE loads). */
static int pick_result_reg(void) { return 1 + (int)(r32() % 7); }
/* Pick two distinct FP registers 0..7. */
static void pick_two_fp(int* a, int* b) {
    *a = pick_fp();
    do { *b = pick_fp(); } while (*b == *a);
}

/* ---------- Per-op generators --------------------------------------- */
static const char* fmt_str(int fmt) {
    switch (fmt) { case FMT_L: return "L"; case FMT_W: return "W";
                   case FMT_B: return "B"; case FMT_S: return "S";
                   default: return "?"; }
}

static int gen_monadic_sized(FILE* f, int is_first, const char* op_name,
                             uint8_t opmode, int (*compute)(int),
                             int load_fmt, int count) {
    for (int i = 0; i < count; ++i) {
        int8_t a = r_moveq();
        int    fp = pick_fp();
        int    rr = pick_result_reg();
        test_t t = {
            .name = NULL, .has_b = 0, .op_a = a, .op_b = 0,
            .dst_fp = fp, .src_fp = fp,
            .opmode = opmode, .load_fmt = load_fmt,
            .result_reg = rr, .expected = compute(a),
        };
        char nm[100];
        snprintf(nm, sizeof(nm), "%s.X (load.%s) FP%d (#%d) -> D%d #%03d",
                 op_name, fmt_str(load_fmt), fp, a, rr, i);
        t.name = nm;
        emit_test_clean(f, is_first && i == 0, &t);
    }
    return count;
}

static int gen_dyadic_sized(FILE* f, int is_first, const char* op_name,
                            uint8_t opmode, int (*compute)(int, int),
                            int limit_a, int limit_b, int load_fmt, int count) {
    for (int i = 0; i < count; ++i) {
        int8_t a = r_moveq_lim(limit_a);
        int8_t b = r_moveq_lim(limit_b);
        int    dst, src;
        pick_two_fp(&dst, &src);
        int    rr = pick_result_reg();
        test_t t = {
            .name = NULL, .has_b = 1, .op_a = a, .op_b = b,
            .dst_fp = dst, .src_fp = src,
            .opmode = opmode, .load_fmt = load_fmt,
            .result_reg = rr, .expected = compute(a, b),
        };
        char nm[120];
        snprintf(nm, sizeof(nm),
                 "%s (load.%s) FP%d,FP%d (%d,%d) -> D%d #%03d",
                 op_name, fmt_str(load_fmt), src, dst, a, b, rr, i);
        t.name = nm;
        emit_test_clean(f, is_first && i == 0, &t);
    }
    return count;
}

/* Default-size (.L) wrappers for compatibility with existing call sites. */
static int gen_monadic(FILE* f, int is_first, const char* op_name,
                       uint8_t opmode, int (*compute)(int), int count) {
    return gen_monadic_sized(f, is_first, op_name, opmode, compute, FMT_L, count);
}
static int gen_dyadic(FILE* f, int is_first, const char* op_name,
                      uint8_t opmode, int (*compute)(int, int),
                      int limit_a, int limit_b, int count) {
    return gen_dyadic_sized(f, is_first, op_name, opmode, compute,
                            limit_a, limit_b, FMT_L, count);
}

/* 68040 unimplemented-FP-instruction generators. The op is emitted with
 * the SAME program template as an execute row (load FP, do op, FMOVE.L
 * FP,Dn, STOP), but tagged traps=1 / exc_vec=11: on a real 68040 (and on
 * an MC68040-lite FPGA core without FPSP) the op faults to vector 11
 * before the FMOVE/STOP can run, so the bench checks the TAKEN VECTOR,
 * not a result value. `expected` is recorded only as a what-MAME-or-FPSP-
 * would-compute reference; it is not the pass/fail criterion. */
static int gen_unimpl_monadic(FILE* f, int is_first, const char* op_name,
                              uint8_t opmode, int count) {
    for (int i = 0; i < count; ++i) {
        int8_t a = r_moveq();
        int fp = pick_fp();
        int rr = pick_result_reg();
        test_t t = {
            .name = NULL, .has_b = 0, .op_a = a, .op_b = 0,
            .dst_fp = fp, .src_fp = fp, .opmode = opmode,
            .load_fmt = FMT_L, .result_reg = rr, .expected = 0,
            .traps = 1, .exc_vec = FP_UNIMP_VECTOR,
        };
        char nm[120];
        snprintf(nm, sizeof(nm),
                 "%s.X FP%d (#%d) -> vec11 (040 unimplemented) #%03d",
                 op_name, fp, a, i);
        t.name = nm;
        emit_test_clean(f, is_first && i == 0, &t);
    }
    return count;
}
static int gen_unimpl_dyadic(FILE* f, int is_first, const char* op_name,
                             uint8_t opmode, int count) {
    for (int i = 0; i < count; ++i) {
        int8_t a = r_moveq_lim(64), b = r_moveq_lim(64);
        int dst, src; pick_two_fp(&dst, &src);
        int rr = pick_result_reg();
        test_t t = {
            .name = NULL, .has_b = 1, .op_a = a, .op_b = b,
            .dst_fp = dst, .src_fp = src, .opmode = opmode,
            .load_fmt = FMT_L, .result_reg = rr, .expected = 0,
            .traps = 1, .exc_vec = FP_UNIMP_VECTOR,
        };
        char nm[120];
        snprintf(nm, sizeof(nm),
                 "%s FP%d,FP%d (%d,%d) -> vec11 (040 unimplemented) #%03d",
                 op_name, src, dst, a, b, i);
        t.name = nm;
        emit_test_clean(f, is_first && i == 0, &t);
    }
    return count;
}

/* Generator for FSQRT with perfect-square inputs only (so result fits int). */
static int gen_fsqrt(FILE* f, int is_first, int count) {
    /* Perfect squares 0..121: 0, 1, 4, 9, 16, 25, 36, 49, 64, 81, 100, 121 */
    static const int squares[] = {0, 1, 4, 9, 16, 25, 36, 49, 64, 81, 100, 121};
    const int N = (int)(sizeof(squares) / sizeof(squares[0]));
    for (int i = 0; i < count; ++i) {
        int a = squares[i % N];
        int fp = pick_fp();
        int rr = pick_result_reg();
        int expected;
        switch (a) {
            case 0:   expected = 0;  break;
            case 1:   expected = 1;  break;
            case 4:   expected = 2;  break;
            case 9:   expected = 3;  break;
            case 16:  expected = 4;  break;
            case 25:  expected = 5;  break;
            case 36:  expected = 6;  break;
            case 49:  expected = 7;  break;
            case 64:  expected = 8;  break;
            case 81:  expected = 9;  break;
            case 100: expected = 10; break;
            case 121: expected = 11; break;
            default:  expected = 0;  break;
        }
        test_t t = {
            .name = NULL, .has_b = 0, .op_a = a, .op_b = 0,
            .dst_fp = fp, .src_fp = fp,
            .opmode = OPMODE_FSQRT, .load_fmt = FMT_L,
            .result_reg = rr, .expected = expected,
        };
        char nm[80];
        snprintf(nm, sizeof(nm), "FSQRT.X FP%d (#%d -> %d) -> D%d #%03d",
                 fp, a, expected, rr, i);
        t.name = nm;
        emit_test_clean(f, is_first && i == 0, &t);
    }
    return count;
}

/* FDIV with arbitrary integer operands, result truncated to int via
 * FINTRZ before readback. Expected = trunc(a / b) (C99 integer division
 * truncates toward zero for both signs, matching FINTRZ).            */
static int gen_fdiv_trunc(FILE* f, int is_first, int count) {
    int emitted = 0;
    while (emitted < count) {
        int8_t b = r_moveq_lim(20);
        if (b == 0) continue;
        int8_t a = r_moveq_lim(127);
        int    quot = (int)a / (int)b;
        if (quot > 127 || quot < -128) continue;  /* keep room for safety */
        int    dst, src;
        pick_two_fp(&dst, &src);
        int    rr = pick_result_reg();
        /* Program: load a→FPdst, load b→FPsrc, FDIV FPsrc,FPdst,
         *          FINTRZ FPdst,FPdst, FMOVE.L FPdst,Dn, STOP.
         * We can't express FINTRZ as a separate test entry through emit_test_clean
         * (it builds a single test instruction). So we emit a custom JSON entry. */
        char nm[120];
        snprintf(nm, sizeof(nm),
                 "FDIV+FINTRZ FP%d,FP%d (%d/%d=%d) -> D%d #%03d",
                 src, dst, (int)a, (int)b, quot, rr, emitted);
        if (!(is_first && emitted == 0)) fprintf(f, ",\n");
        fprintf(f, "  {\n");
        fprintf(f, "    \"name\":\"%s\",\n", nm);
        fprintf(f, "    \"op_a\":%d,\"op_b\":%d,\n", (int)a, (int)b);
        fprintf(f, "    \"program\":[");
        int first = 1;
        #define BW2(w) do { \
            if (!first) fprintf(f, ","); \
            fprintf(f, "%u,%u", ((unsigned)(w) >> 8) & 0xFF, (unsigned)(w) & 0xFF); \
            first = 0; \
        } while (0)
        BW2(moveq_d0(a));
        BW2(0xF200); BW2(fmove_size_d0_fpn(dst, FMT_L));
        BW2(moveq_d0(b));
        BW2(0xF200); BW2(fmove_size_d0_fpn(src, FMT_L));
        BW2(0xF200); BW2(ext_dyadic(src, dst, OPMODE_FDIV));
        BW2(0xF200); BW2(ext_monadic_fp(dst, OPMODE_FINTRZ));
        BW2((uint16_t)(0xF200 | (rr & 7)));
        BW2((uint16_t)(0x6000 | ((dst & 7) << 7)));
        BW2(0x4E72); BW2(0x2700);
        #undef BW2
        fprintf(f, "],\n");
        fprintf(f, "    \"result_reg\":%d,\n", rr);
        fprintf(f, "    \"expected\":%d\n", quot);
        fprintf(f, "  }");
        emitted++;
    }
    return emitted;
}

/* FSQRT with non-perfect-square integer inputs; truncate result via FINTRZ. */
static int gen_fsqrt_trunc(FILE* f, int is_first, int count) {
    int emitted = 0;
    while (emitted < count) {
        int  a = (int)(r32() % 128);   /* 0..127 to fit MOVEQ */
        if (a == 0) continue;
        /* trunc(sqrt(a)) via integer Newton iteration / search */
        int  s = 0;
        while ((s + 1) * (s + 1) <= a) s++;
        int  expected_trunc = s;
        int    fp = pick_fp();
        int    rr = pick_result_reg();
        char nm[120];
        snprintf(nm, sizeof(nm),
                 "FSQRT+FINTRZ FP%d (sqrt(%d)=%d) -> D%d #%03d",
                 fp, a, expected_trunc, rr, emitted);
        if (!(is_first && emitted == 0)) fprintf(f, ",\n");
        fprintf(f, "  {\n");
        fprintf(f, "    \"name\":\"%s\",\n", nm);
        fprintf(f, "    \"op_a\":%d,\n", a);
        fprintf(f, "    \"program\":[");
        int first = 1;
        #define BW3(w) do { \
            if (!first) fprintf(f, ","); \
            fprintf(f, "%u,%u", ((unsigned)(w) >> 8) & 0xFF, (unsigned)(w) & 0xFF); \
            first = 0; \
        } while (0)
        BW3(moveq_d0((int8_t)a));
        BW3(0xF200); BW3(fmove_size_d0_fpn(fp, FMT_L));
        BW3(0xF200); BW3(ext_monadic_fp(fp, OPMODE_FSQRT));
        BW3(0xF200); BW3(ext_monadic_fp(fp, OPMODE_FINTRZ));
        BW3((uint16_t)(0xF200 | (rr & 7)));
        BW3((uint16_t)(0x6000 | ((fp & 7) << 7)));
        BW3(0x4E72); BW3(0x2700);
        #undef BW3
        fprintf(f, "],\n");
        fprintf(f, "    \"result_reg\":%d,\n", rr);
        fprintf(f, "    \"expected\":%d\n", expected_trunc);
        fprintf(f, "  }");
        emitted++;
    }
    return emitted;
}

/* FDIV restricted to exact-integer divisions (op_a % op_b == 0). */
static int gen_fdiv(FILE* f, int is_first, int count) {
    int emitted = 0;
    while (emitted < count) {
        int8_t b = r_moveq_lim(10);
        if (b == 0) continue;          /* skip divide-by-zero */
        int    quot = r_moveq_lim(10);
        if (quot == 0) continue;        /* skip zero quotients (trivial) */
        int    a = (int)b * (int)quot;
        if (a < -128 || a > 127) continue;
        int    dst, src;
        pick_two_fp(&dst, &src);
        int    rr = pick_result_reg();
        test_t t = {
            .name = NULL, .has_b = 1, .op_a = a, .op_b = b,
            .dst_fp = dst, .src_fp = src,
            .opmode = OPMODE_FDIV, .load_fmt = FMT_L,
            .result_reg = rr, .expected = quot,
        };
        char nm[100];
        snprintf(nm, sizeof(nm), "FDIV FP%d,FP%d (%d/%d=%d) -> D%d #%03d",
                 src, dst, a, b, quot, rr, emitted);
        t.name = nm;
        emit_test_clean(f, is_first && emitted == 0, &t);
        emitted++;
    }
    return emitted;
}

/* Result computation helpers — int-preserving since we round-trip via .L. */
static int fneg_compute(int a)        { return -a; }
static int fabs_compute(int a)        { return a < 0 ? -a : a; }
static int fint_compute(int a)        { return a; }    /* already int */
static int fintrz_compute(int a)      { return a; }    /* truncate toward zero, already int */
static int fadd_compute(int a, int b) { return a + b; }
static int fsub_compute(int a, int b) { return a - b; }  /* FSUB FP1,FP0 = FP0 - FP1 */
static int fmul_compute(int a, int b) { return a * b; }

/* M68881 FPcc condition selector codes (6-bit). Per Table 4-8 of the
 * MC68881 User's Manual: low 16 codes are IEEE-aware (don't raise BSUN
 * on unordered input); high 16 codes are signaling (raise BSUN). For
 * ordered comparisons the truth value of a paired ordered/signaling code
 * (e.g. OGT/$02 and GT/$12) is identical. */
#define COND_F    0x00
#define COND_EQ   0x01
#define COND_OGT  0x02
#define COND_OGE  0x03
#define COND_OLT  0x04
#define COND_OLE  0x05
#define COND_OGL  0x06
#define COND_OR   0x07
#define COND_UN   0x08
#define COND_UEQ  0x09
#define COND_UGT  0x0A
#define COND_UGE  0x0B
#define COND_ULT  0x0C
#define COND_ULE  0x0D
#define COND_NE   0x0E
#define COND_T    0x0F
#define COND_SF   0x10
#define COND_SEQ  0x11
#define COND_GT   0x12
#define COND_GE   0x13
#define COND_LT   0x14
#define COND_LE   0x15
#define COND_GL   0x16
#define COND_GLE  0x17
#define COND_NGLE 0x18
#define COND_NGL  0x19
#define COND_NLE  0x1A
#define COND_NLT  0x1B
#define COND_NGE  0x1C
#define COND_NGT  0x1D
#define COND_SNE  0x1E
#define COND_ST   0x1F

/* Evaluate condition for integer operand pair (assuming ordered result of
 * FCMP fpm,fpn = FPn - FPm; FPCC bits reflect that). All inputs are
 * integers so NaN is always false. */
static int eval_cond_int(uint8_t cond, int n, int m) {
    int Z = (n == m), N = (n < m), NaN = 0;
    switch (cond) {
        case COND_F:    case COND_SF:   return 0;
        case COND_T:    case COND_ST:   return 1;
        case COND_EQ:   case COND_SEQ:  return Z;
        case COND_NE:   case COND_SNE:  return !Z;
        case COND_OGT:  case COND_GT:   return !(NaN || Z || N);
        case COND_OGE:  case COND_GE:   return Z || !(NaN || N);
        case COND_OLT:  case COND_LT:   return N && !(NaN || Z);
        case COND_OLE:  case COND_LE:   return Z || (N && !NaN);
        case COND_OGL:  case COND_GL:   return !(NaN || Z);
        case COND_OR:                   return !NaN;
        case COND_UN:                   return NaN;
        case COND_UEQ:                  return NaN || Z;
        case COND_UGT:                  return NaN || !(Z || N);
        case COND_UGE:                  return NaN || !N;
        case COND_ULT:                  return NaN || (N && !Z);
        case COND_ULE:                  return NaN || Z || N;
        case COND_GLE:                  return !NaN;
        case COND_NGLE:                 return NaN;
        case COND_NGL:                  return NaN || Z;
        case COND_NLE:                  return NaN || !(N || Z);
        case COND_NLT:                  return NaN || Z || !N;
        case COND_NGE:                  return NaN || (N && !Z);
        case COND_NGT:                  return NaN || Z || N;
        default:                        return 0;
    }
}

/* Full 32-element condition table; used by FScc/FBcc/FBcc.L generators. */
static const struct cond_entry { uint8_t code; const char* name; } CONDS_ALL[32] = {
    {COND_F,"F"},     {COND_EQ,"EQ"},     {COND_OGT,"OGT"},   {COND_OGE,"OGE"},
    {COND_OLT,"OLT"}, {COND_OLE,"OLE"},   {COND_OGL,"OGL"},   {COND_OR,"OR"},
    {COND_UN,"UN"},   {COND_UEQ,"UEQ"},   {COND_UGT,"UGT"},   {COND_UGE,"UGE"},
    {COND_ULT,"ULT"}, {COND_ULE,"ULE"},   {COND_NE,"NE"},     {COND_T,"T"},
    {COND_SF,"SF"},   {COND_SEQ,"SEQ"},   {COND_GT,"GT"},     {COND_GE,"GE"},
    {COND_LT,"LT"},   {COND_LE,"LE"},     {COND_GL,"GL"},     {COND_GLE,"GLE"},
    {COND_NGLE,"NGLE"},{COND_NGL,"NGL"},  {COND_NLE,"NLE"},   {COND_NLT,"NLT"},
    {COND_NGE,"NGE"}, {COND_NGT,"NGT"},   {COND_SNE,"SNE"},   {COND_ST,"ST"},
};

/* FCMP FPm,FPn  +  FScc.B Dx tests. Loads FPm and FPn, runs FCMP
 * (sets FPCC), then FScc.B Dx with the chosen condition. Verifies
 * Dx low byte is 0xFF or 0x00 per the condition. */
static int gen_fcmp_fscc(FILE* f, int is_first, int count) {
    const struct cond_entry* conds = CONDS_ALL;
    const int NC = 32;
    for (int i = 0; i < count; ++i) {
        int8_t a = r_moveq_lim(50);
        int8_t b = r_moveq_lim(50);
        int    dst, src;
        pick_two_fp(&dst, &src);
        int    rr = pick_result_reg();
        const int     ci = (int)(r32() % NC);
        const uint8_t cond = conds[ci].code;
        const char*   cname = conds[ci].name;
        const int expected = eval_cond_int(cond, a, b);

        char nm[120];
        snprintf(nm, sizeof(nm), "FCMP+FS%s FP%d,FP%d (%d,%d) -> D%d #%03d",
                 cname, src, dst, (int)a, (int)b, rr, i);
        if (!(is_first && i == 0)) fprintf(f, ",\n");
        fprintf(f, "  {\n");
        fprintf(f, "    \"name\":\"%s\",\n", nm);
        fprintf(f, "    \"op_a\":%d,\"op_b\":%d,\n", (int)a, (int)b);
        fprintf(f, "    \"program\":[");
        int first = 1;
        #define BWf(w) do { \
            if (!first) fprintf(f, ","); \
            fprintf(f, "%u,%u", ((unsigned)(w) >> 8) & 0xFF, (unsigned)(w) & 0xFF); \
            first = 0; \
        } while (0)
        /* MOVEQ #0,Drr — clear Drr high bits so FScc.B leaves a clean byte. */
        BWf((uint16_t)(0x7000 | ((rr & 7) << 9) | 0));
        /* Load FP{dst} = a */
        BWf(moveq_d0(a));
        BWf(0xF200); BWf(fmove_size_d0_fpn(dst, FMT_L));
        /* Load FP{src} = b */
        BWf(moveq_d0(b));
        BWf(0xF200); BWf(fmove_size_d0_fpn(src, FMT_L));
        /* FCMP FP{src},FP{dst}: ext = src<<10 | dst<<7 | opmode FCMP (0x38). */
        BWf(0xF200);
        BWf((uint16_t)(((src & 7) << 10) | ((dst & 7) << 7) | 0x38));
        /* FScc.B D{rr}: opword F240 | rr; ext = condition selector. */
        BWf((uint16_t)(0xF240 | (rr & 7)));
        BWf((uint16_t)cond);
        /* STOP #$2700 */
        BWf(0x4E72); BWf(0x2700);
        #undef BWf
        fprintf(f, "],\n");
        fprintf(f, "    \"result_reg\":%d,\n", rr);
        fprintf(f, "    \"expected\":%d\n", expected ? 0xFF : 0x00);
        fprintf(f, "  }");
    }
    return count;
}

/* FTST + FScc: unary version of FCMP+FScc. FTST FPn sets FPCC by
 * comparing FPn against zero, then FScc reads back the predicate.        */
static int gen_ftst_fscc(FILE* f, int is_first, int count) {
    const struct cond_entry* conds = CONDS_ALL;
    const int NC = 32;
    for (int i = 0; i < count; ++i) {
        int8_t a = r_moveq_lim(50);
        int    src = (int)(r32() & 7);
        int    rr  = pick_result_reg();
        const int     ci = (int)(r32() % NC);
        const uint8_t cond  = conds[ci].code;
        const char*   cname = conds[ci].name;
        /* FTST FPn vs zero: compare a against 0 for predicate evaluation. */
        const int expected = eval_cond_int(cond, a, 0);

        char nm[120];
        snprintf(nm, sizeof(nm), "FTST+FS%s FP%d (%d) -> D%d #%03d",
                 cname, src, (int)a, rr, i);
        if (!(is_first && i == 0)) fprintf(f, ",\n");
        fprintf(f, "  {\n");
        fprintf(f, "    \"name\":\"%s\",\n", nm);
        fprintf(f, "    \"op_a\":%d,\n", (int)a);
        fprintf(f, "    \"program\":[");
        int first = 1;
        #define BWf(w) do { \
            if (!first) fprintf(f, ","); \
            fprintf(f, "%u,%u", ((unsigned)(w) >> 8) & 0xFF, (unsigned)(w) & 0xFF); \
            first = 0; \
        } while (0)
        BWf((uint16_t)(0x7000 | ((rr & 7) << 9) | 0));        /* MOVEQ #0,Drr */
        BWf(moveq_d0(a));
        BWf(0xF200); BWf(fmove_size_d0_fpn(src, FMT_L));      /* FMOVE.L D0,FP{src} */
        /* FTST.X FPn: ext = (src<<10) | 0x3A (opclass 000 monadic, opmode FTST). */
        BWf(0xF200);
        BWf((uint16_t)(((src & 7) << 10) | 0x3A));
        /* FScc.B D{rr} */
        BWf((uint16_t)(0xF240 | (rr & 7)));
        BWf((uint16_t)cond);
        BWf(0x4E72); BWf(0x2700);
        #undef BWf
        fprintf(f, "],\n");
        fprintf(f, "    \"result_reg\":%d,\n", rr);
        fprintf(f, "    \"expected\":%d\n", expected ? 0xFF : 0x00);
        fprintf(f, "  }");
    }
    return count;
}

/* FCMP + FBcc.W: branch on condition. If taken, marker reg keeps its
 * initial value (1); if not taken, the MOVEQ #0 between FBcc and STOP
 * runs and zeros it.                                                       */
static int gen_fcmp_fbcc(FILE* f, int is_first, int count) {
    const struct cond_entry* conds = CONDS_ALL;
    const int NC = 32;
    for (int i = 0; i < count; ++i) {
        int8_t a = r_moveq_lim(50);
        int8_t b = r_moveq_lim(50);
        int    dst, src;
        pick_two_fp(&dst, &src);
        int    rr = pick_result_reg();
        const int     ci    = (int)(r32() % NC);
        const uint8_t cond  = conds[ci].code;
        const char*   cname = conds[ci].name;
        const int taken = eval_cond_int(cond, a, b);
        const int expected = taken ? 1 : 0;

        char nm[120];
        snprintf(nm, sizeof(nm), "FCMP+FB%s FP%d,FP%d (%d,%d) -> D%d #%03d",
                 cname, src, dst, (int)a, (int)b, rr, i);
        if (!(is_first && i == 0)) fprintf(f, ",\n");
        fprintf(f, "  {\n");
        fprintf(f, "    \"name\":\"%s\",\n", nm);
        fprintf(f, "    \"op_a\":%d,\"op_b\":%d,\n", (int)a, (int)b);
        fprintf(f, "    \"program\":[");
        int first = 1;
        #define BWf(w) do { \
            if (!first) fprintf(f, ","); \
            fprintf(f, "%u,%u", ((unsigned)(w) >> 8) & 0xFF, (unsigned)(w) & 0xFF); \
            first = 0; \
        } while (0)
        BWf((uint16_t)(0x7001 | ((rr & 7) << 9)));   /* MOVEQ #1,Drr (initial) */
        BWf(moveq_d0(a));
        BWf(0xF200); BWf(fmove_size_d0_fpn(dst, FMT_L));
        BWf(moveq_d0(b));
        BWf(0xF200); BWf(fmove_size_d0_fpn(src, FMT_L));
        BWf(0xF200);
        BWf((uint16_t)(((src & 7) << 10) | ((dst & 7) << 7) | 0x38));   /* FCMP */
        /* FBcc.W disp=+4 skips the 2-byte MOVEQ #0,Drr that follows. */
        BWf((uint16_t)(0xF280 | cond));
        BWf((uint16_t)0x0004);
        BWf((uint16_t)(0x7000 | ((rr & 7) << 9) | 0));   /* MOVEQ #0,Drr (skipped if branch) */
        BWf(0x4E72); BWf(0x2700);
        #undef BWf
        fprintf(f, "],\n");
        fprintf(f, "    \"result_reg\":%d,\n", rr);
        fprintf(f, "    \"expected\":%d\n", expected);
        fprintf(f, "  }");
    }
    return count;
}

/* FCMP + FBcc.L: 32-bit-displacement branch variant.                     */
static int gen_fcmp_fbcc_l(FILE* f, int is_first, int count) {
    const struct cond_entry* conds = CONDS_ALL;
    const int NC = 32;
    for (int i = 0; i < count; ++i) {
        int8_t a = r_moveq_lim(50);
        int8_t b = r_moveq_lim(50);
        int    dst, src;
        pick_two_fp(&dst, &src);
        int    rr = pick_result_reg();
        const int     ci    = (int)(r32() % NC);
        const uint8_t cond  = conds[ci].code;
        const char*   cname = conds[ci].name;
        const int taken = eval_cond_int(cond, a, b);
        const int expected = taken ? 1 : 0;

        char nm[120];
        snprintf(nm, sizeof(nm), "FCMP+FB%s.L FP%d,FP%d (%d,%d) -> D%d #%03d",
                 cname, src, dst, (int)a, (int)b, rr, i);
        if (!(is_first && i == 0)) fprintf(f, ",\n");
        fprintf(f, "  {\n");
        fprintf(f, "    \"name\":\"%s\",\n", nm);
        fprintf(f, "    \"op_a\":%d,\"op_b\":%d,\n", (int)a, (int)b);
        fprintf(f, "    \"program\":[");
        int first = 1;
        #define BWf(w) do { \
            if (!first) fprintf(f, ","); \
            fprintf(f, "%u,%u", ((unsigned)(w) >> 8) & 0xFF, (unsigned)(w) & 0xFF); \
            first = 0; \
        } while (0)
        BWf((uint16_t)(0x7001 | ((rr & 7) << 9)));
        BWf(moveq_d0(a));
        BWf(0xF200); BWf(fmove_size_d0_fpn(dst, FMT_L));
        BWf(moveq_d0(b));
        BWf(0xF200); BWf(fmove_size_d0_fpn(src, FMT_L));
        BWf(0xF200);
        BWf((uint16_t)(((src & 7) << 10) | ((dst & 7) << 7) | 0x38));
        /* FBcc.L disp=+6 skips the 2-byte MOVEQ #0 that follows. Target =
         * (addr_of_disp + 0) + disp = (opword+2) + 6 = opword+8 = STOP. */
        BWf((uint16_t)(0xF2C0 | cond));
        BWf((uint16_t)0x0000); BWf((uint16_t)0x0006);
        BWf((uint16_t)(0x7000 | ((rr & 7) << 9) | 0));
        BWf(0x4E72); BWf(0x2700);
        #undef BWf
        fprintf(f, "],\n");
        fprintf(f, "    \"result_reg\":%d,\n", rr);
        fprintf(f, "    \"expected\":%d\n", expected);
        fprintf(f, "  }");
    }
    return count;
}

/* FMOVE.X FPm,FPn chain: register-to-register copies across FP file.
 * Validates that the cpGEN reg-reg FMOVE path preserves operands when
 * routing through intermediate FP registers.                              */
static int gen_fmove_x_chain(FILE* f, int is_first, int count) {
    for (int i = 0; i < count; ++i) {
        int8_t a = r_moveq_lim(127);
        int    via1 = (int)(r32() & 7);
        int    via2 = (int)(r32() & 7);
        while (via2 == via1) via2 = (int)(r32() & 7);
        int    via3 = (int)(r32() & 7);
        while (via3 == via1 || via3 == via2) via3 = (int)(r32() & 7);
        int    rr = pick_result_reg();

        char nm[120];
        snprintf(nm, sizeof(nm),
                 "FMOVE.X FP%d->FP%d->FP%d (%d) -> D%d #%03d",
                 via1, via2, via3, (int)a, rr, i);
        if (!(is_first && i == 0)) fprintf(f, ",\n");
        fprintf(f, "  {\n");
        fprintf(f, "    \"name\":\"%s\",\n", nm);
        fprintf(f, "    \"op_a\":%d,\n", (int)a);
        fprintf(f, "    \"program\":[");
        int first = 1;
        #define BWf(w) do { \
            if (!first) fprintf(f, ","); \
            fprintf(f, "%u,%u", ((unsigned)(w) >> 8) & 0xFF, (unsigned)(w) & 0xFF); \
            first = 0; \
        } while (0)
        /* Load FP{via1} = a via .L int. */
        BWf(moveq_d0(a));
        BWf(0xF200); BWf(fmove_size_d0_fpn(via1, FMT_L));
        /* FMOVE.X FP{via1},FP{via2}: opclass=000, src<<10|dst<<7|opmode=0 */
        BWf(0xF200);
        BWf((uint16_t)(((via1 & 7) << 10) | ((via2 & 7) << 7) | 0x00));
        BWf(0xF200);
        BWf((uint16_t)(((via2 & 7) << 10) | ((via3 & 7) << 7) | 0x00));
        /* Read back FP{via3} via .L into D{rr}: opword $F200|rr, ext
         * opclass=011 fmt=L src=via3. */
        BWf((uint16_t)(0xF200 | (rr & 7)));
        BWf((uint16_t)((3 << 13) | (0 << 10) | ((via3 & 7) << 7) | 0));
        BWf(0x4E72); BWf(0x2700);
        #undef BWf
        fprintf(f, "],\n");
        fprintf(f, "    \"result_reg\":%d,\n", rr);
        fprintf(f, "    \"expected\":%d\n", (int)a);
        fprintf(f, "  }");
    }
    return count;
}

/* FMOVE.{B,W,S} FPn->Dm: verifies cp_xfer_from handles all sizes correctly
 * (FPU does the format conversion; CPU sees same 32-bit Transfer Single).  */
static int gen_fmove_sized_fp_to_d(FILE* f, int is_first, int fmt,
                                   const char* fmt_name, int count) {
    for (int i = 0; i < count; ++i) {
        int range = (fmt == FMT_B) ? 100 : 1000;
        int8_t a = r_moveq_lim(range > 127 ? 127 : range);
        int    src_fp = (int)(r32() & 7);
        int    rr     = pick_result_reg();
        /* Expected: integer value matches signed-byte input for .B/.W/.L
         * since we loaded via .L and the FPU does the size conversion.
         * For .S, expected is the IEEE single-precision bit pattern of a. */
        int32_t expected;
        if (fmt == FMT_S) {
            float fv = (float)a;
            uint32_t u; memcpy(&u, &fv, 4);
            expected = (int32_t)u;
        } else if (fmt == FMT_W) {
            /* FMOVE.W preserves high 16 bits of Dn (MOVEQ #0 cleared them). */
            expected = (int32_t)((uint32_t)a & 0xFFFF);
        } else if (fmt == FMT_B) {
            /* FMOVE.B preserves high 24 bits of Dn (MOVEQ #0 cleared them). */
            expected = (int32_t)((uint32_t)a & 0xFF);
        } else {
            expected = a;
        }

        char nm[120];
        snprintf(nm, sizeof(nm), "FMOVE.%s FP%d->D%d (%d) #%03d",
                 fmt_name, src_fp, rr, (int)a, i);
        if (!(is_first && i == 0)) fprintf(f, ",\n");
        fprintf(f, "  {\n");
        fprintf(f, "    \"name\":\"%s\",\n", nm);
        fprintf(f, "    \"op_a\":%d,\n", (int)a);
        fprintf(f, "    \"program\":[");
        int first = 1;
        #define BWf(w) do { \
            if (!first) fprintf(f, ","); \
            fprintf(f, "%u,%u", ((unsigned)(w) >> 8) & 0xFF, (unsigned)(w) & 0xFF); \
            first = 0; \
        } while (0)
        /* Initialize Drr=0 so partial-size writes have clean upper bits. */
        BWf((uint16_t)(0x7000 | ((rr & 7) << 9) | 0));
        /* Load FP{src} = a via .L int. */
        BWf(moveq_d0(a));
        BWf(0xF200); BWf(fmove_size_d0_fpn(src_fp, FMT_L));
        /* FMOVE.{fmt} FP{src}, D{rr}: opword $F200|rr (mode=000 reg=rr);
         * ext = opclass 011 | fmt | src<<7. */
        BWf((uint16_t)(0xF200 | (rr & 7)));
        BWf((uint16_t)((3 << 13) | (fmt << 10) | ((src_fp & 7) << 7) | 0));
        BWf(0x4E72); BWf(0x2700);
        #undef BWf
        fprintf(f, "],\n");
        fprintf(f, "    \"result_reg\":%d,\n", rr);
        fprintf(f, "    \"expected\":%d\n", (int)expected);
        fprintf(f, "  }");
    }
    return count;
}

/* FNOP — encoded as FBF.W with disp=0. Per the M68881 manual, this is
 * a synchronization barrier that falls through to the next instruction.
 * Verifies the no-op path through cp_cond_eval doesn't disturb register
 * state and PC advances correctly past the 4-byte FNOP encoding.        */
/* FMOVEM.X round-trip via the SSP: push FP0, pop into FP1, then read FP1
 * back into D{rr} via FMOVE.L.
 *
 *   MOVEQ #a,D0; FMOVE.L D0,FP0    ; load FP0 = a
 *   FMOVEM.X FP0,-(A7)             ; push 96 bits of FP0 to SSP
 *   FMOVEM.X (A7)+,FP1             ; pop them into FP1
 *   FMOVE.L FP1,D{rr}              ; verify
 *   STOP #$2700
 *
 * FMOVEM encoding (PRM 6-23):
 *   opword: $F200 | EA (mode+reg)
 *   ext:    opclass 110 (M->R) or 111 (R->M)
 *           bit 14 = list type (0 = static)
 *           bit 13 = direction-encoded predec flag (0 = postinc/control, 1 = predec)
 *           bits 10..8 = dynamic Dn (unused for static)
 *           bits 7..0  = register select mask
 *
 * Register select-bit conventions:
 *   Predecrement source:    bit 7 = FP7, bit 0 = FP0   (reversed)
 *   Postinc / control dest: bit 7 = FP0, bit 0 = FP7   (normal)
 *
 * NOTE: FMOVEM requires multi-word coprocessor transfers (96 bits per reg)
 * that may not be supported yet by TG68K's microcode. These tests are
 * diagnostic; failures surface microcode gaps in cp_xfer_{to,from}.
 */
static int gen_fmovem_x_roundtrip(FILE* f, int is_first, int count) {
    for (int i = 0; i < count; ++i) {
        int8_t a = r_moveq_lim(50);
        int    rr = pick_result_reg();
        char nm[120];
        snprintf(nm, sizeof(nm), "FMOVEM.X FP0,-(A7); (A7)+,FP1 a=%d -> D%d #%03d",
                 (int)a, rr, i);
        if (!(is_first && i == 0)) fprintf(f, ",\n");
        fprintf(f, "  {\n");
        fprintf(f, "    \"name\":\"%s\",\n", nm);
        fprintf(f, "    \"op_a\":%d,\n", (int)a);
        fprintf(f, "    \"program\":[");
        int first = 1;
        #define BWf(w) do { \
            if (!first) fprintf(f, ","); \
            fprintf(f, "%u,%u", ((unsigned)(w) >> 8) & 0xFF, (unsigned)(w) & 0xFF); \
            first = 0; \
        } while (0)
        BWf(moveq_d0(a));
        BWf(0xF200); BWf(fmove_size_d0_fpn(0, FMT_L));   /* FP0 = a */
        /* FMOVEM.X FP0,-(A7): opword $F227 (mode=4 predec, reg=7);
         * ext: bits 15-13 = 111 (R->M), bit 11 = static = 0, predec mask
         * with bit 0 = FP0 = 0x01.   $E000 | 0x01 = $E001 (wait, includes
         * bit 13 = 1 which signals predec list-mode? PRM ext: opclass=111
         * is the high 3 bits 15-13 = 111, so $E000. Predec list-mode is
         * encoded by the opcode EA being predec; the ext bit-13 difference
         * is for postinc-vs-control orientation which doesn't apply when
         * the EA mode is predecrement.)                                     */
        BWf(0xF227);
        BWf(0xE001);
        /* FMOVEM.X (A7)+,FP1: opword $F21F (mode=3 postinc, reg=7=A7);
         * ext: opclass 110 (M->R) = $C000; static (bit 14=0); list mask
         * with bit 6 = FP1 (for postinc, bit 7 = FP0): mask = 0x40.        */
        BWf(0xF21F);
        BWf(0xC040);
        /* FMOVE.L FP1,D{rr} */
        BWf((uint16_t)(0xF200 | (rr & 7)));
        BWf((uint16_t)((0x3 << 13) | (0 << 10) | (1 << 7)));
        BWf(0x4E72); BWf(0x2700);
        #undef BWf
        fprintf(f, "],\n");
        fprintf(f, "    \"result_reg\":%d,\n", rr);
        fprintf(f, "    \"expected\":%d\n", (int)a);
        fprintf(f, "  }");
    }
    return count;
}

/* FMOVE.{X,D,P} from PC-relative memory into FPn, then FMOVE.L FPn,D{rr}.
 *
 * Layout:
 *    $00: FMOVE.{fmt} (d16,PC),FPn   (4 bytes: opword + ext)
 *    $04: disp word                   (2 bytes; PC base = this address)
 *    $06: FMOVE.L FPn,D{rr}           (4 bytes: opword + ext)
 *    $0A: STOP #$2700                 (4 bytes)
 *    $0E: FP_data bytes               (4/8/12 bytes depending on fmt)
 *
 * disp from PC ($04) to data ($0E) = $0A. EA = (PC + d16) = (PC + $0A) = $0E.
 *
 * Format codes (ext bits 12-10): 2 = .X (12B), 3 = .P (12B), 5 = .D (8B).
 * We emit integer-valued data so the FMOVE.L readback can compare to an
 * int32 expected. .P (packed BCD) is intentionally skipped: the M68881 lite
 * FPU treats it as unsupported and traps F-line.
 */

/* Build M68881 extended bytes (12) for an integer value v in [-127,127]. */
static void m68881_extended_int(int v, uint8_t out[12]) {
    /* zero -> all-zero extended encoding (sign=0, exp=0, mantissa=0). */
    memset(out, 0, 12);
    if (v == 0) return;
    int sign = (v < 0) ? 1 : 0;
    uint32_t mag = (uint32_t)(v < 0 ? -v : v);
    /* Find top bit position. */
    int e = 31;
    while (e > 0 && !(mag & (1u << e))) --e;
    /* mantissa = 1.<...> with implicit J bit. Shift left to put bit `e`
     * at position 63 (top of 64-bit mantissa). */
    uint64_t mant64 = ((uint64_t)mag) << (63 - e);
    int exp_biased = 16383 + e;
    out[0] = (sign << 7) | ((exp_biased >> 8) & 0x7F);
    out[1] = exp_biased & 0xFF;
    /* out[2..3] = 0 (reserved/padding) */
    for (int i = 0; i < 8; ++i)
        out[4 + i] = (uint8_t)(mant64 >> (56 - i * 8));
}

/* Build IEEE 754 binary64 (double, 8 bytes) for an integer value. */
static void ieee_double_int(int v, uint8_t out[8]) {
    memset(out, 0, 8);
    if (v == 0) return;
    int sign = (v < 0) ? 1 : 0;
    uint32_t mag = (uint32_t)(v < 0 ? -v : v);
    int e = 31; while (e > 0 && !(mag & (1u << e))) --e;
    /* mantissa = top bit dropped (implicit J), then 52 frac bits. */
    uint64_t frac = ((uint64_t)mag - ((uint64_t)1 << e)) << (52 - e);
    int exp_biased = 1023 + e;
    uint64_t bits = ((uint64_t)sign << 63)
                  | ((uint64_t)(exp_biased & 0x7FF) << 52)
                  | (frac & 0x000FFFFFFFFFFFFFULL);
    for (int i = 0; i < 8; ++i)
        out[i] = (uint8_t)(bits >> (56 - i * 8));
}

static int gen_fmove_pcrel_load(FILE* f, int is_first, int fmt, const char* fmt_name,
                                int data_bytes,
                                void (*pack)(int, uint8_t*), int count) {
    for (int i = 0; i < count; ++i) {
        int v = (int)((int8_t)r_moveq_lim(50));
        int dst = (int)(r32() & 7);
        int rr  = pick_result_reg();
        uint8_t fpdata[12]; memset(fpdata, 0, sizeof(fpdata));
        pack(v, fpdata);

        char nm[120];
        snprintf(nm, sizeof(nm), "FMOVE.%s (d16,PC),FP%d v=%d -> D%d #%03d",
                 fmt_name, dst, v, rr, i);
        if (!(is_first && i == 0)) fprintf(f, ",\n");
        fprintf(f, "  {\n");
        fprintf(f, "    \"name\":\"%s\",\n", nm);
        fprintf(f, "    \"op_a\":%d,\n", v);
        fprintf(f, "    \"program\":[");
        int first = 1;
        #define BWf(w) do { \
            if (!first) fprintf(f, ","); \
            fprintf(f, "%u,%u", ((unsigned)(w) >> 8) & 0xFF, (unsigned)(w) & 0xFF); \
            first = 0; \
        } while (0)
        #define BBf(b) do { \
            if (!first) fprintf(f, ","); \
            fprintf(f, "%u", (unsigned)(b) & 0xFFu); \
            first = 0; \
        } while (0)
        /* FMOVE.{fmt} (d16,PC),FP{dst}
         *   opword: $F200 | mode=111 reg=010 = $F200 | 0x3A = $F23A
         *   ext:    opclass 010 (load EA->FPn) | fmt<<10 | dst<<7
         */
        BWf(0xF23A);
        BWf((uint16_t)((0x2 << 13) | ((fmt & 7) << 10) | ((dst & 7) << 7)));
        BWf(0x000A);    /* disp = +10 (PC base = this word at offset $04) */
        /* FMOVE.L FP{dst},D{rr}: opclass 011 -> L from FPn to EA(D{rr}). */
        BWf((uint16_t)(0xF200 | (rr & 7)));
        BWf((uint16_t)((0x3 << 13) | (0 << 10) | ((dst & 7) << 7)));
        /* STOP */
        BWf(0x4E72); BWf(0x2700);
        /* FP data payload */
        for (int j = 0; j < data_bytes; ++j) BBf(fpdata[j]);
        #undef BWf
        #undef BBf
        fprintf(f, "],\n");
        fprintf(f, "    \"result_reg\":%d,\n", rr);
        fprintf(f, "    \"expected\":%d\n", v);
        fprintf(f, "  }");
    }
    return count;
}

/* FMOVE.L Dn,FPcr round-trip. The FPU has three control registers
 * (selected by ext word bits 12-10):
 *    bit 12: FPIAR   (instruction-address register)
 *    bit 11: FPSR    (status register)
 *    bit 10: FPCR    (control register)
 * Multiple bits can be set for FMOVEM.L, but for FMOVE.L exactly one
 * register is selected.
 *
 * Test: write Drr=src_val to the control reg; read it back to D{rr+1}.
 * Verify D{rr+1} matches what we wrote (modulo any reserved-bit zeroing
 * the FPU does to that particular register).
 *
 * FPCR: bits 15-4 reserved (read as zero), bits 3-0 = mode + precision.
 *   Use a value with bits in the valid range so the round-trip is clean.
 * FPSR: writable bits depend on implementation; use 0 for a safe value
 *   that round-trips on any FPU.
 * FPIAR: full 32-bit writable.
 *
 * ext word: opclass 100 (move to FPcr), bits 12-10 = register select,
 *           bits 6-0 = 0. Direction is opclass 100 (load FPcr from EA);
 *           opclass 101 reads FPcr into EA.
 */
struct fpcr_def { uint16_t sel_bit; const char* name; int32_t test_val; };
static const struct fpcr_def FPCRS[3] = {
    /* sel_bit is bits 12-10 of ext (FPIAR=4, FPSR=2, FPCR=1). */
    { 0x1000, "FPIAR", 0x12345678 },  /* full 32-bit. */
    { 0x0800, "FPSR",  0x00000000 },  /* zero is universally safe. */
    { 0x0400, "FPCR",  0x00000030 },  /* mode bits only (RN, X precision). */
};

static int gen_fmove_l_fpcr_roundtrip(FILE* f, int is_first, int count) {
    for (int i = 0; i < count; ++i) {
        const struct fpcr_def* fc = &FPCRS[i % 3];
        int rr_w = pick_result_reg();          /* Dn used for the write */
        int rr_r;                              /* Dn used for the readback */
        do { rr_r = pick_result_reg(); } while (rr_r == rr_w);
        const int32_t v = fc->test_val;

        char nm[120];
        snprintf(nm, sizeof(nm), "FMOVE.L D%d->%s; %s->D%d #%03d",
                 rr_w, fc->name, fc->name, rr_r, i);
        if (!(is_first && i == 0)) fprintf(f, ",\n");
        fprintf(f, "  {\n");
        fprintf(f, "    \"name\":\"%s\",\n", nm);
        fprintf(f, "    \"op_a\":%d,\n", v);
        fprintf(f, "    \"program\":[");
        int first = 1;
        #define BWf(w) do { \
            if (!first) fprintf(f, ","); \
            fprintf(f, "%u,%u", ((unsigned)(w) >> 8) & 0xFF, (unsigned)(w) & 0xFF); \
            first = 0; \
        } while (0)
        /* MOVE.L #v,D{rr_w} */
        BWf((uint16_t)(0x203C | ((rr_w & 7) << 9)));
        BWf((uint16_t)((v >> 16) & 0xFFFF));
        BWf((uint16_t)(v & 0xFFFF));
        /* FMOVE.L D{rr_w},FPcr: opword $F200 | mode=000 reg=rr_w
         *                       ext = opclass 100 (10000) | sel_bit  */
        BWf((uint16_t)(0xF200 | (rr_w & 7)));
        BWf((uint16_t)(0x8000 | fc->sel_bit));
        /* FMOVE.L FPcr,D{rr_r}: opword $F200 | mode=000 reg=rr_r
         *                       ext = opclass 101 (10100) | sel_bit  */
        BWf((uint16_t)(0xF200 | (rr_r & 7)));
        BWf((uint16_t)(0xA000 | fc->sel_bit));
        /* STOP */
        BWf(0x4E72); BWf(0x2700);
        #undef BWf
        fprintf(f, "],\n");
        fprintf(f, "    \"result_reg\":%d,\n", rr_r);
        fprintf(f, "    \"expected\":%d\n", v);
        fprintf(f, "  }");
    }
    return count;
}

/* FCMP + FDBcc.W: floating-point decrement-and-branch. Counter Dn=1;
 * after exactly one decrement Dn=0 (not -1), so a "branch taken" path
 * runs once. Test layout (similar to FBcc):
 *
 *   MOVEQ #42,Drr            ; initial marker
 *   MOVEQ #1,Dctr            ; loop counter
 *   MOVEQ #a,D0; FMOVE.L D0,FP{src}    ; load FP{src} = a
 *   MOVEQ #b,D0; FMOVE.L D0,FP{dst}    ; load FP{dst} = b
 *   FCMP FP{src},FP{dst}     ; set FPCC
 *   FDBcc Dctr, disp=+4      ; if cond false: Dctr--, Dctr != -1 -> branch over MOVEQ
 *                            ; if cond true:  fall through to MOVEQ #99
 *   MOVEQ #99,Drr            ; (2 bytes)
 *   STOP #$2700
 *
 * Expected:
 *   cond true:  Drr = 99 (FDBcc fell through, MOVEQ ran)
 *   cond false: Drr = 42 (FDBcc decremented + branched over MOVEQ)
 */
static int gen_fcmp_fdbcc(FILE* f, int is_first, int count) {
    const struct cond_entry* conds = CONDS_ALL;
    const int NC = 32;
    for (int i = 0; i < count; ++i) {
        int8_t a = r_moveq_lim(50);
        int8_t b = r_moveq_lim(50);
        int    dst, src;
        pick_two_fp(&dst, &src);
        int    rr  = pick_result_reg();
        /* Dctr must differ from rr and from D0 (used for loads). */
        int    ctr;
        do { ctr = 1 + (int)(r32() % 7); } while (ctr == rr);

        const int ci = (int)(r32() % NC);
        const uint8_t cond = conds[ci].code;
        const char*   cname = conds[ci].name;
        const int cond_true = eval_cond_int(cond, a, b);
        const int expected = cond_true ? 99 : 42;

        char nm[120];
        snprintf(nm, sizeof(nm), "FCMP+FDB%s FP%d,FP%d (%d,%d) ctr=D%d -> D%d #%03d",
                 cname, src, dst, (int)a, (int)b, ctr, rr, i);
        if (!(is_first && i == 0)) fprintf(f, ",\n");
        fprintf(f, "  {\n");
        fprintf(f, "    \"name\":\"%s\",\n", nm);
        fprintf(f, "    \"op_a\":%d,\"op_b\":%d,\n", (int)a, (int)b);
        fprintf(f, "    \"program\":[");
        int first = 1;
        #define BWf(w) do { \
            if (!first) fprintf(f, ","); \
            fprintf(f, "%u,%u", ((unsigned)(w) >> 8) & 0xFF, (unsigned)(w) & 0xFF); \
            first = 0; \
        } while (0)
        BWf((uint16_t)(0x7000 | ((rr  & 7) << 9) | 42));  /* MOVEQ #42,Drr */
        BWf((uint16_t)(0x7000 | ((ctr & 7) << 9) | 1));   /* MOVEQ #1,Dctr */
        BWf(moveq_d0(a));
        BWf(0xF200); BWf(fmove_size_d0_fpn(src, FMT_L));
        BWf(moveq_d0(b));
        BWf(0xF200); BWf(fmove_size_d0_fpn(dst, FMT_L));
        /* FCMP FP{src},FP{dst} */
        BWf(0xF200);
        BWf((uint16_t)(((src & 7) << 10) | ((dst & 7) << 7) | 0x38));
        /* FDBcc Dctr: opword $F248 | reg; ext = cond; disp word follows.
         * disp = +4 -- after FDBcc (which is 6 bytes), PC sits at disp
         * base; +4 skips the MOVEQ (2 bytes) and lands on STOP (4 bytes). */
        BWf((uint16_t)(0xF248 | (ctr & 7)));
        BWf((uint16_t)cond);
        BWf(0x0004);                                /* disp = +4 (.W) */
        BWf((uint16_t)(0x7000 | ((rr & 7) << 9) | 99));  /* MOVEQ #99,Drr */
        BWf(0x4E72); BWf(0x2700);                   /* STOP #$2700 */
        #undef BWf
        fprintf(f, "],\n");
        fprintf(f, "    \"result_reg\":%d,\n", rr);
        fprintf(f, "    \"expected\":%d\n", expected);
        fprintf(f, "  }");
    }
    return count;
}

/* FTRAPcc.F (always-false condition): the instruction must not trap.
 * Verifies the F-line decode handles FTRAPcc + early-out on false cc.
 * We don't test true conditions here because handling the trap would
 * need a vector handler the bench doesn't currently set up. */
static int gen_ftrapcc_false(FILE* f, int is_first, int count) {
    for (int i = 0; i < count; ++i) {
        int8_t a = r_moveq_lim(127);
        int    rr = pick_result_reg();
        char nm[120];
        snprintf(nm, sizeof(nm), "FTRAPcc.F (no operand) preserves D%d=%d #%03d",
                 rr, (int)a, i);
        if (!(is_first && i == 0)) fprintf(f, ",\n");
        fprintf(f, "  {\n");
        fprintf(f, "    \"name\":\"%s\",\n", nm);
        fprintf(f, "    \"op_a\":%d,\n", (int)a);
        fprintf(f, "    \"program\":[");
        int first = 1;
        #define BWf(w) do { \
            if (!first) fprintf(f, ","); \
            fprintf(f, "%u,%u", ((unsigned)(w) >> 8) & 0xFF, (unsigned)(w) & 0xFF); \
            first = 0; \
        } while (0)
        /* MOVEQ #a,Drr; FTRAPcc.F (no operand); STOP. */
        BWf((uint16_t)(0x7000 | ((rr & 7) << 9) | (uint8_t)a));
        BWf(0xF27C); BWf(0x0000);   /* FTRAPcc no-operand variant + cond F */
        BWf(0x4E72); BWf(0x2700);
        #undef BWf
        fprintf(f, "],\n");
        fprintf(f, "    \"result_reg\":%d,\n", rr);
        fprintf(f, "    \"expected\":%d\n", (int)a);
        fprintf(f, "  }");
    }
    return count;
}

static int gen_fnop(FILE* f, int is_first, int count) {
    for (int i = 0; i < count; ++i) {
        int8_t a = r_moveq_lim(127);
        int    rr = pick_result_reg();
        char nm[120];
        snprintf(nm, sizeof(nm), "FNOP preserves D%d=%d #%03d", rr, (int)a, i);
        if (!(is_first && i == 0)) fprintf(f, ",\n");
        fprintf(f, "  {\n");
        fprintf(f, "    \"name\":\"%s\",\n", nm);
        fprintf(f, "    \"op_a\":%d,\n", (int)a);
        fprintf(f, "    \"program\":[");
        int first = 1;
        #define BWf(w) do { \
            if (!first) fprintf(f, ","); \
            fprintf(f, "%u,%u", ((unsigned)(w) >> 8) & 0xFF, (unsigned)(w) & 0xFF); \
            first = 0; \
        } while (0)
        /* MOVEQ #a,Drr; FNOP ($F280 + $0000); STOP. Verify Drr untouched. */
        BWf((uint16_t)(0x7000 | ((rr & 7) << 9) | ((uint8_t)a)));
        BWf(0xF280); BWf(0x0000);
        BWf(0x4E72); BWf(0x2700);
        #undef BWf
        fprintf(f, "],\n");
        fprintf(f, "    \"result_reg\":%d,\n", rr);
        fprintf(f, "    \"expected\":%d\n", (int)a);
        fprintf(f, "  }");
    }
    return count;
}

/* ---------------------------------------------------------------------- */
int main(int argc, char** argv) {
    const char* outpath = (argc > 1) ? argv[1] : "fpu_corpus.json";
    if (argc > 2) g_rng = (uint32_t)strtoul(argv[2], NULL, 0);

    FILE* f = fopen(outpath, "w");
    if (!f) { perror(outpath); return 1; }
    fprintf(f, "[\n");

    int total = 0;
    int first = 1;
    const int N = 40;

    total += gen_monadic(f, first, "FNEG",   OPMODE_FNEG,   fneg_compute,   N); first = 0;
    total += gen_monadic(f, first, "FABS",   OPMODE_FABS,   fabs_compute,   N);
    total += gen_monadic(f, first, "FINT",   OPMODE_FINT,   fint_compute,   N);
    total += gen_monadic(f, first, "FINTRZ", OPMODE_FINTRZ, fintrz_compute, N);
    /* Dyadic with bounded operands so int32 result fits.
     * FADD/FSUB: ±127 each, sum ±254. FMUL: ±10 each, product ±100. */
    total += gen_dyadic (f, first, "FADD",   OPMODE_FADD, fadd_compute, 127, 127, N);
    total += gen_dyadic (f, first, "FSUB",   OPMODE_FSUB, fsub_compute, 127, 127, N);
    total += gen_dyadic (f, first, "FMUL",   OPMODE_FMUL, fmul_compute,  10,  10, N);
    /* FSQRT: perfect squares only (so result fits int). */
    total += gen_fsqrt  (f, first, N);
    /* FDIV: exact integer divisions only (a % b == 0). */
    total += gen_fdiv   (f, first, N);

    /* ---- Size-variant load tests --------------------------------------
     * Same ops loaded via FMOVE.W and FMOVE.B (instead of FMOVE.L) to
     * exercise the FPU's sign-extension paths from short integers. For
     * MOVEQ-range operands (-128..127), the FP value after a sized load
     * should match the .L round-trip, so the same compute() functions
     * are valid. Fewer tests per op since coverage focus is on the load
     * path, not the ALU.                                                 */
    const int M = 16;
    total += gen_monadic_sized(f, first, "FNEG",   OPMODE_FNEG,   fneg_compute,   FMT_W, M);
    total += gen_monadic_sized(f, first, "FNEG",   OPMODE_FNEG,   fneg_compute,   FMT_B, M);
    total += gen_monadic_sized(f, first, "FABS",   OPMODE_FABS,   fabs_compute,   FMT_W, M);
    total += gen_monadic_sized(f, first, "FABS",   OPMODE_FABS,   fabs_compute,   FMT_B, M);
    total += gen_dyadic_sized (f, first, "FADD",   OPMODE_FADD, fadd_compute, 127, 127, FMT_W, M);
    total += gen_dyadic_sized (f, first, "FADD",   OPMODE_FADD, fadd_compute, 127, 127, FMT_B, M);
    total += gen_dyadic_sized (f, first, "FMUL",   OPMODE_FMUL, fmul_compute,  10,  10, FMT_W, M);
    total += gen_dyadic_sized (f, first, "FMUL",   OPMODE_FMUL, fmul_compute,  10,  10, FMT_B, M);

    /* FMOVE.S variants: load via MOVE.L #ieee_single(op),D0; FMOVE.S D0,FPn.
     * Operand range still bounded so the integer round-trip works. */
    total += gen_monadic_sized(f, first, "FNEG",   OPMODE_FNEG,   fneg_compute,   FMT_S, M);
    total += gen_monadic_sized(f, first, "FABS",   OPMODE_FABS,   fabs_compute,   FMT_S, M);
    total += gen_monadic_sized(f, first, "FINT",   OPMODE_FINT,   fint_compute,   FMT_S, M);
    total += gen_dyadic_sized (f, first, "FADD",   OPMODE_FADD, fadd_compute, 127, 127, FMT_S, M);
    total += gen_dyadic_sized (f, first, "FSUB",   OPMODE_FSUB, fsub_compute, 127, 127, FMT_S, M);
    total += gen_dyadic_sized (f, first, "FMUL",   OPMODE_FMUL, fmul_compute,  10,  10, FMT_S, M);

    /* Multi-instruction tests: FDIV with arbitrary operands + FINTRZ to
     * truncate the (possibly non-integer) result, then read back as .L.
     * Verifies the FPU rounds-toward-zero correctly. */
    total += gen_fdiv_trunc (f, first, N);
    /* Same for FSQRT with arbitrary 0..127 inputs. */
    total += gen_fsqrt_trunc(f, first, N);

    /* FCMP+FScc / FTST+FScc / FCMP+FBcc.W / FBcc.L: each draws random
     * conditions from the full 32-entry CONDS_ALL table — bumped to 2N
     * so each of the 32 predicates gets exercised on average ~2.5 times. */
    total += gen_fcmp_fscc  (f, first, 2 * N);
    total += gen_ftst_fscc  (f, first, 2 * N);
    total += gen_fcmp_fbcc  (f, first, 2 * N);
    total += gen_fcmp_fbcc_l(f, first, 2 * N);
    /* FMOVE.X reg-reg chain: stress register-file routing. */
    total += gen_fmove_x_chain(f, first, N);
    /* FMOVE.{B,W,S} FPn->Dm size-variant readback. */
    total += gen_fmove_sized_fp_to_d(f, first, FMT_S, "S", M);
    total += gen_fmove_sized_fp_to_d(f, first, FMT_W, "W", M);
    total += gen_fmove_sized_fp_to_d(f, first, FMT_B, "B", M);
    /* FNOP synchronization barrier. */
    total += gen_fnop(f, first, M);
    /* FDBcc decrement-and-branch (single-iteration test pattern). */
    total += gen_fcmp_fdbcc(f, first, 2 * N);
    /* FTRAPcc with always-false condition (must not trap). */
    total += gen_ftrapcc_false(f, first, M);
    /* FMOVE.L Dn<->FPcr round-trips for FPIAR/FPSR/FPCR. */
    total += gen_fmove_l_fpcr_roundtrip(f, first, 3 * M);
    /* FMOVE memory loads via PC-relative addressing for .X (12B) and .D (8B).
     * .P (packed BCD) intentionally omitted -- unsupported on fpu_lite. */
    total += gen_fmove_pcrel_load(f, first, /*fmt=*/2, "X", 12,
                                  m68881_extended_int, N);
    total += gen_fmove_pcrel_load(f, first, /*fmt=*/5, "D",  8,
                                  ieee_double_int,    N);
    /* FMOVEM.X round-trip via the SSP. Stresses multi-word coprocessor
     * transfers; may surface TG68K microcode gaps. */
    total += gen_fmovem_x_roundtrip(f, first, M);

    /* ---- 68040 UNIMPLEMENTED FP INSTRUCTIONS (must trap to vector 11) ----
     * On the Quadra 800's MC68040, these ops are decoded but not executed
     * in silicon: they take the unimplemented-FP exception (vector 11) so
     * Apple's FPSP040 can emulate them. An MC68040-lite FPGA core (no
     * transcendental/sglops/modrem engines -- see the fpu_lite_g generate
     * blocks in 68881-fpga/src) WITHOUT FPSP loaded must take the same
     * trap. These rows are the FPU bench's execute-vs-trap discriminator:
     * a core that EXECUTES any of them (full-68882 behaviour) FAILS the
     * row, which is the correct signal. MAME wrongly executes them, so it
     * is NOT the oracle here -- the expectation (trap) is from the 040 UM. */
    total += gen_unimpl_dyadic (f, first, "FMOD",    OPMODE_FMOD,    M);
    total += gen_unimpl_dyadic (f, first, "FREM",    OPMODE_FREM,    M);
    total += gen_unimpl_dyadic (f, first, "FSCALE",  OPMODE_FSCALE,  M);
    total += gen_unimpl_dyadic (f, first, "FSGLMUL", OPMODE_FSGLMUL, M);
    total += gen_unimpl_dyadic (f, first, "FSGLDIV", OPMODE_FSGLDIV, M);
    total += gen_unimpl_monadic(f, first, "FGETEXP", OPMODE_FGETEXP, M);
    total += gen_unimpl_monadic(f, first, "FGETMAN", OPMODE_FGETMAN, M);
    total += gen_unimpl_monadic(f, first, "FSIN",    OPMODE_FSIN,    M);
    total += gen_unimpl_monadic(f, first, "FCOS",    OPMODE_FCOS,    M);
    total += gen_unimpl_monadic(f, first, "FTAN",    OPMODE_FTAN,    M);
    total += gen_unimpl_monadic(f, first, "FATAN",   OPMODE_FATAN,   M);
    total += gen_unimpl_monadic(f, first, "FASIN",   OPMODE_FASIN,   M);
    total += gen_unimpl_monadic(f, first, "FACOS",   OPMODE_FACOS,   M);
    total += gen_unimpl_monadic(f, first, "FETOX",   OPMODE_FETOX,   M);
    total += gen_unimpl_monadic(f, first, "FETOXM1", OPMODE_FETOXM1, M);
    total += gen_unimpl_monadic(f, first, "FTWOTOX", OPMODE_FTWOTOX, M);
    total += gen_unimpl_monadic(f, first, "FTENTOX", OPMODE_FTENTOX, M);
    total += gen_unimpl_monadic(f, first, "FLOGN",   OPMODE_FLOGN,   M);
    total += gen_unimpl_monadic(f, first, "FLOGNP1", OPMODE_FLOGNP1, M);
    total += gen_unimpl_monadic(f, first, "FLOG10",  OPMODE_FLOG10,  M);
    total += gen_unimpl_monadic(f, first, "FLOG2",   OPMODE_FLOG2,   M);
    total += gen_unimpl_monadic(f, first, "FSINH",   OPMODE_FSINH,   M);
    total += gen_unimpl_monadic(f, first, "FCOSH",   OPMODE_FCOSH,   M);
    total += gen_unimpl_monadic(f, first, "FTANH",   OPMODE_FTANH,   M);
    total += gen_unimpl_monadic(f, first, "FATANH",  OPMODE_FATANH,  M);

    fprintf(f, "\n]\n");
    fclose(f);
    printf("Wrote %s (%d tests, seed=0x%08X)\n", outpath, total, g_rng);
    return 0;
}
