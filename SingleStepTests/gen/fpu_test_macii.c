/*
 * fpu_test_macii.c -- FPU oracle test bench for real Mac II hardware.
 *
 * Builds with THINK C 5.0+ (or MPW C) on a 68020+68881 Mac. Runs the same
 * test sequence as SingleStepTests/gen/mame_fpu_capture.lua and writes
 * results to "FPU Results.txt" in the application's directory. Compare
 * against the MAME oracle (/tmp/fpu_corpus.json from the Lua script) to
 * find divergence in MAME's m68kfpu emulation.
 *
 * Approach: assemble each test's 68k machine code into a buffer at runtime
 * (identical encodings to the Lua script), then JSR into it. The buffered
 * code dumps register state to two global Snapshot structs that C then
 * formats to text.
 *
 * Build notes
 * -----------
 * - THINK C: New project, ANSI library, set "68000 code" OFF and
 *   "Generate 68881 code" — actually it doesn't matter, since all FPU
 *   instructions go through hand-emitted machine code, not the compiler.
 * - The CACR write is supervisor-only; we call _HwPriv (trap $A198,
 *   selector 1) which Mac OS routes into supervisor land. Works on
 *   System 6.0.4+ and System 7. If your Mac II is on an older System,
 *   delete the call to flush_icache() and just relaunch the app between
 *   runs if results look stale.
 */

#include <stdio.h>
#include <string.h>

typedef unsigned char  u8;
typedef unsigned short u16;
typedef unsigned long  u32;

/* Snapshot layout. Offsets are referenced by the hand-emitted machine
 * code below, so the struct MUST be tightly packed in this order.
 * Mac68k struct alignment leaves no padding here (all fields are 1- or
 * 4-byte aligned to their natural boundary). */
typedef struct {
    u8  fp[8][12];   /* offset 0x00 -- FP0..FP7 in extended-precision (96b)   */
    u32 d[8];        /* offset 0x60 -- D0..D7                                 */
    u32 a[8];        /* offset 0x80 -- A0..A7 (A7 captured post-jsr; see end) */
    u32 fpcr;        /* offset 0xA0                                           */
    u32 fpsr;        /* offset 0xA4                                           */
    u32 fpiar;       /* offset 0xA8                                           */
} Snapshot;

static Snapshot init_snap;
static Snapshot final_snap;

/* One 512-byte slot per test so each test executes from its own
 * address range -- avoids stale 68020 instruction-cache entries from
 * the previous test polluting the next one. */
#define MAX_TESTS    16
#define PROG_SLOT    512
static u8 prog_buffer[MAX_TESTS * PROG_SLOT];

/* --------------------------------------------------------------------
 * Machine-code emitters. Each writes 68k bytes into *p and returns the
 * new write pointer. Encodings exactly mirror mame_fpu_capture.lua.
 * -------------------------------------------------------------------- */

static u8 *put_w(u8 *p, u16 v)
{
    *p++ = (u8)(v >> 8);
    *p++ = (u8)(v & 0xFF);
    return p;
}

static u8 *put_l(u8 *p, u32 v)
{
    *p++ = (u8)(v >> 24);
    *p++ = (u8)(v >> 16);
    *p++ = (u8)(v >>  8);
    *p++ = (u8)(v & 0xFF);
    return p;
}

/* MOVE.L Dn, (abs.L addr)  -- 6 bytes */
static u8 *emit_move_l_dn_to_abs(u8 *p, int dn, u32 addr)
{
    p = put_w(p, (u16)(0x23C0 | (dn & 7)));
    return put_l(p, addr);
}

/* MOVE.L An, (abs.L addr)  -- 6 bytes */
static u8 *emit_move_l_an_to_abs(u8 *p, int an, u32 addr)
{
    p = put_w(p, (u16)(0x23C8 | (an & 7)));
    return put_l(p, addr);
}

/* MOVEA.L #imm32, An       -- 6 bytes */
static u8 *emit_movea_l_imm_to_an(u8 *p, int an, u32 imm)
{
    p = put_w(p, (u16)(0x207C | ((an & 7) << 9)));
    return put_l(p, imm);
}

/* FMOVE.X FPn, (An)+       -- 4 bytes, writes 12 bytes of FP data.
 * MAME's m68kfpu can't handle FMOVE.X to abs.L; postincrement works on
 * both MAME and real 68881. Encoding:
 *   opword  1111 001 000 011 nnn  (mode=011 postinc, reg=An)
 *   extword 011 010 sss 0 0000000 (size=X, src FP reg=sss, k-factor=0) */
static u8 *emit_fmove_x_to_an_postinc(u8 *p, int fpn, int an)
{
    p = put_w(p, (u16)(0xF218 | (an & 7)));
    return put_w(p, (u16)(0x6800 | (fpn << 7)));
}

/* FMOVE.L FPcr, (abs.L addr)  -- 8 bytes. reg_mask selects which one:
 *   0x1000 = FPCR, 0x0800 = FPSR, 0x0400 = FPIAR. */
static u8 *emit_fmove_l_ctrl_to_abs(u8 *p, u16 reg_mask, u32 addr)
{
    p = put_w(p, 0xF239);
    p = put_w(p, (u16)(0xA000 | reg_mask));
    return put_l(p, addr);
}

/* Reset D0..D7 and A0..A6 to zero. A7 is left alone (it's our C
 * stack). 16 bytes (8 moveq + 7 sub.l An,An). */
static u8 *emit_register_reset(u8 *p)
{
    int n;
    for (n = 0; n < 8; n++) {
        /* MOVEQ #0, Dn -- opword 0x7000 | (Dn<<9) */
        p = put_w(p, (u16)(0x7000 | (n << 9)));
    }
    for (n = 0; n < 7; n++) {
        /* SUBA.L An, An -- opword 0x91C8 | (An<<9) | An */
        p = put_w(p, (u16)(0x91C8 | (n << 9) | n));
    }
    return p;
}

/* Build the full state-dump sequence: A regs first (so A0 is still
 * original), then FP via (A0)+, then D regs, then control regs. */
static u8 *emit_state_dump(u8 *p, Snapshot *snap)
{
    u32 base = (u32) snap;
    int i;
    for (i = 0; i < 8; i++)
        p = emit_move_l_an_to_abs(p, i, base + 0x80 + i * 4);
    p = emit_movea_l_imm_to_an(p, 0, base);
    for (i = 0; i < 8; i++)
        p = emit_fmove_x_to_an_postinc(p, i, 0);
    for (i = 0; i < 8; i++)
        p = emit_move_l_dn_to_abs(p, i, base + 0x60 + i * 4);
    p = emit_fmove_l_ctrl_to_abs(p, 0x1000, base + 0xA0);
    p = emit_fmove_l_ctrl_to_abs(p, 0x0800, base + 0xA4);
    p = emit_fmove_l_ctrl_to_abs(p, 0x0400, base + 0xA8);
    return p;
}

/* --------------------------------------------------------------------
 * Test catalog. Bytes here are EXACTLY the same as in mame_fpu_capture.lua
 * so the two oracles can be byte-diffed against each other.
 * -------------------------------------------------------------------- */

typedef struct {
    const char *name;
    u8 preload[16];
    int preload_len;
    u8 test[16];
    int test_len;
} TestSpec;

static TestSpec tests[] = {
    { "DBG: MOVEQ #5,D0 (no FPU)",
      { 0 }, 0,
      { 0x70, 0x05 }, 2 },
    { "FMOVE.L #1,FP0",
      { 0 }, 0,
      { 0x70, 0x01, 0xF2, 0x00, 0x40, 0x00 }, 6 },
    { "FADD.X FP0,FP0 (1+1=2)",
      { 0x70, 0x01, 0xF2, 0x00, 0x40, 0x00 }, 6,
      { 0xF2, 0x00, 0x00, 0x22 }, 4 },
    { "FMUL.X FP0,FP0 (2*2=4)",
      { 0x70, 0x02, 0xF2, 0x00, 0x40, 0x00 }, 6,
      { 0xF2, 0x00, 0x00, 0x23 }, 4 },
    { "FSQRT.X FP0,FP0 (sqrt(4)=2)",
      { 0x70, 0x04, 0xF2, 0x00, 0x40, 0x00 }, 6,
      { 0xF2, 0x00, 0x00, 0x04 }, 4 },
    { "FNEG.X FP0,FP0 (1 -> -1)",
      { 0x70, 0x01, 0xF2, 0x00, 0x40, 0x00 }, 6,
      { 0xF2, 0x00, 0x00, 0x1A }, 4 },
    { "FABS.X FP0,FP0 (-1 -> 1)",
      { 0x70, 0xFF, 0xF2, 0x00, 0x40, 0x00 }, 6,
      { 0xF2, 0x00, 0x00, 0x18 }, 4 },
    { "FTST.X FP0",
      { 0x70, 0x00, 0xF2, 0x00, 0x40, 0x00 }, 6,
      { 0xF2, 0x00, 0x00, 0x3A }, 4 },
    { "FMOVE.X FP0,FP1",
      { 0x70, 0x05, 0xF2, 0x00, 0x40, 0x00 }, 6,
      { 0xF2, 0x00, 0x00, 0x80 }, 4 }
};
#define N_TESTS (sizeof(tests) / sizeof(tests[0]))

/* Assemble one test's program into slot N of prog_buffer. Returns the
 * entry-point address (= start of the slot). */
static u8 *build_program(int slot, TestSpec *t)
{
    u8 *entry = &prog_buffer[slot * PROG_SLOT];
    u8 *p     = entry;

    p = emit_register_reset(p);

    if (t->preload_len) {
        memcpy(p, t->preload, t->preload_len);
        p += t->preload_len;
    }
    p = emit_state_dump(p, &init_snap);

    memcpy(p, t->test, t->test_len);
    p += t->test_len;

    p = emit_state_dump(p, &final_snap);

    /* RTS to return to C */
    *p++ = 0x4E;
    *p++ = 0x75;

    return entry;
}

/* Flush the 68020 instruction cache so the freshly-built code in
 * prog_buffer isn't shadowed by stale cache lines. _HwPriv with
 * selector 1 = FlushInstructionCache. Trap-glued so we get supervisor
 * privilege for the underlying MOVEC. */
static void flush_icache(void)
{
    asm {
        moveq   #1, d0
        dc.w    0xA198          /* _HwPriv */
    }
}

/* Save all callee-saved C registers, JSR into the assembled test, then
 * restore. The test program freely clobbers D0-D7/A0-A6 by design. */
static void invoke_program(u8 *entry)
{
    asm {
        movem.l d2-d7/a2-a6, -(sp)
        move.l  entry, a0
        jsr     (a0)
        movem.l (sp)+, d2-d7/a2-a6
    }
}

/* --------------------------------------------------------------------
 * Output formatting -- one section per test, plain text, easy to diff
 * against the MAME oracle's JSON (which we'll convert in a small post-
 * processing step on the host side).
 * -------------------------------------------------------------------- */

static void print_fp(FILE *f, u8 *fp)
{
    int i;
    for (i = 0; i < 12; i++)
        fprintf(f, "%02x", fp[i]);
}

static void print_snap(FILE *f, const char *label, Snapshot *s)
{
    int i;
    fprintf(f, "  %s:\n", label);
    fprintf(f, "    d:");
    for (i = 0; i < 8; i++) fprintf(f, " %08lx", s->d[i]);
    fprintf(f, "\n    a:");
    for (i = 0; i < 8; i++) fprintf(f, " %08lx", s->a[i]);
    fprintf(f, "\n");
    for (i = 0; i < 8; i++) {
        fprintf(f, "    fp%d: ", i);
        print_fp(f, s->fp[i]);
        fprintf(f, "\n");
    }
    fprintf(f, "    fpcr=%08lx fpsr=%08lx fpiar=%08lx\n",
            s->fpcr, s->fpsr, s->fpiar);
}

int main(void)
{
    FILE *f;
    int i;

    f = fopen("FPU Results.txt", "w");
    if (f == NULL) {
        printf("Cannot open output file.\n");
        return 1;
    }

    fprintf(f, "Mac II 68881 FPU test results -- %d tests\n", (int)N_TESTS);
    fprintf(f, "Note: dumped a[7] is post-JSR; subtract 4 for caller-time A7.\n\n");

    for (i = 0; i < (int)N_TESTS; i++) {
        u8 *entry;

        memset(&init_snap,  0, sizeof(init_snap));
        memset(&final_snap, 0, sizeof(final_snap));

        entry = build_program(i, &tests[i]);
        flush_icache();
        printf("[%d/%d] %s\n", i + 1, (int)N_TESTS, tests[i].name);
        invoke_program(entry);

        fprintf(f, "== Test %d: %s\n", i, tests[i].name);
        print_snap(f, "initial", &init_snap);
        print_snap(f, "final",   &final_snap);
        fprintf(f, "\n");
        fflush(f);
    }

    fclose(f);
    printf("Done. Results written to \"FPU Results.txt\".\n");
    return 0;
}
