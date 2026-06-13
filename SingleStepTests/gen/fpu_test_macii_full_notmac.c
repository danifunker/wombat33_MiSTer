/*
 * fpu_test_macii_full.c -- full 270-test FPU bench for real Mac II hardware.
 *
 * Builds with THINK C 5+ / Symantec C++ on a 68020+68881 Mac.
 *
 * Companion to gen/mame_fpu_capture.lua: that script produces both
 *   /tmp/fpu_corpus.json    -- MAME oracle results (JSON Lines)
 *   /tmp/fpu_tests.h        -- C header with the same 270 test specs
 *
 * Drop fpu_tests.h into the same THINK C project as this .c file (with
 * CR line endings -- see the .macc twin or run `tr '\n' '\r'` on the host)
 * and Build Application. Running the app writes
 *   "FPU Results Full.jsonl"
 * to the application's working directory in the same JSON-Lines format
 * MAME produces, so the two outputs can be diffed line-by-line.
 *
 * Design notes
 * ------------
 * - We assemble each test's machine code into a working buffer at
 *   runtime (rather than compile-time function pointers) because the
 *   test instruction stream needs hand-emitted state-dump epilogues
 *   bracketing the actual test instruction. The byte streams for the
 *   preload and the test itself come straight from fpu_tests.h --
 *   no encoding logic lives here.
 * - Each test gets its own 512-byte slot in prog_buffer[] so cached
 *   instructions from a previous test never pollute the next one
 *   (the 68020 I-cache is 256B per line and is mapped by address).
 * - _HwPriv trap ($A198, selector 1) flushes the instruction cache
 *   before each invocation. Works on System 6.0.4 and later.
 *
 * Extending the corpus
 * --------------------
 * Add new test cases to mame_fpu_capture.lua (OPERANDS / DYADIC_OPS /
 * MONADIC_OPS / TRANSCENDENTAL_OPS / *_PAIRS / *_VALUES tables, or by
 * adding ad-hoc entries to the smoke section). Re-run MAME with the
 * Lua script to regenerate /tmp/fpu_tests.h AND the matching MAME
 * oracle. Recompile this app -- it picks up the new tests
 * automatically via FPU_N_TESTS.
 */

#include <stdio.h>
#include <string.h>

#include "fpu_tests.h"

typedef unsigned char  u8;
typedef unsigned short u16;
typedef unsigned long  u32;

typedef struct {
    u8  fp[8][12];   /* offset 0x00 -- FP0..FP7 in extended-precision  */
    u32 d[8];        /* offset 0x60 -- D0..D7                          */
    u32 a[8];        /* offset 0x80 -- A0..A7 (A7 captured post-jsr)   */
    u32 fpcr;        /* offset 0xA0                                    */
    u32 fpsr;        /* offset 0xA4                                    */
    u32 fpiar;       /* offset 0xA8                                    */
} Snapshot;

static Snapshot init_snap;
static Snapshot final_snap;

/* Single 512-byte buffer reused across all tests. We rely on the
 * explicit flush_icache() before each invocation to keep stale I-cache
 * lines from the previous test out of the way -- a per-test slot
 * array would scale to ~150KB at 270 tests and blow past THINK C's
 * default 32KB data-segment limit. */
static u8 prog_buffer[512];

/* --------------------------------------------------------------------
 * Machine-code emitters. Encodings exactly match those in the Lua
 * script's emit_state_dump path -- they MUST stay in lockstep with
 * mame_fpu_capture.lua so the Mac dumps land at the same Snapshot
 * offsets MAME's read_snap() reads back.
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

static u8 *emit_move_l_dn_to_abs(u8 *p, int dn, u32 addr)
{
    p = put_w(p, (u16)(0x23C0 | (dn & 7)));
    return put_l(p, addr);
}

static u8 *emit_move_l_an_to_abs(u8 *p, int an, u32 addr)
{
    p = put_w(p, (u16)(0x23C8 | (an & 7)));
    return put_l(p, addr);
}

static u8 *emit_movea_l_imm_to_an(u8 *p, int an, u32 imm)
{
    p = put_w(p, (u16)(0x207C | ((an & 7) << 9)));
    return put_l(p, imm);
}

/* FMOVE.X FPn,(An)+ : 4-byte opcode/ext, writes 12 bytes of FP data. */
static u8 *emit_fmove_x_to_an_postinc(u8 *p, int fpn, int an)
{
    p = put_w(p, (u16)(0xF218 | (an & 7)));
    return put_w(p, (u16)(0x6800 | (fpn << 7)));
}

/* FMOVE.L FPcr,(abs.L). reg_mask: 0x1000 FPCR, 0x0800 FPSR, 0x0400 FPIAR */
static u8 *emit_fmove_l_ctrl_to_abs(u8 *p, u16 reg_mask, u32 addr)
{
    p = put_w(p, 0xF239);
    p = put_w(p, (u16)(0xA000 | reg_mask));
    return put_l(p, addr);
}

/* Reset D0..D7 and A0..A6 to zero. A7 stays as the C stack pointer.
 * 30 bytes (8 moveq + 7 sub.l An,An). */
static u8 *emit_register_reset(u8 *p)
{
    int n;
    for (n = 0; n < 8; n++) {
        p = put_w(p, (u16)(0x7000 | (n << 9)));        /* MOVEQ #0,Dn  */
    }
    for (n = 0; n < 7; n++) {
        p = put_w(p, (u16)(0x91C8 | (n << 9) | n));    /* SUBA.L An,An */
    }
    return p;
}

/* State-dump epilogue: dumps A regs first (so A0 is original), then
 * FP via (A0)+, then D regs and control regs. Mirrors the Lua
 * emit_state_dump() byte-for-byte. */
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

/* Assemble the test's program into prog_buffer. */
static u8 *build_program(const FpuTestSpec *t)
{
    u8 *entry = prog_buffer;
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

    *p++ = 0x4E;  *p++ = 0x75;  /* RTS */
    return entry;
}

/* _HwPriv selector 1 = FlushInstructionCache. Mac-OS-glued so we get
 * supervisor privilege for the underlying MOVEC. System 6.0.4+. */
static void flush_icache(void)
{
    asm {
        moveq   #1, d0
        dc.w    0xA198          /* _HwPriv */
    }
}

/* Save C's callee-saved regs, JSR into the assembled test, restore.
 * The test program freely clobbers D0-D7/A0-A6. */
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
 * Output: JSON Lines (one object per line), matching MAME's
 * /tmp/fpu_corpus.json schema exactly so diffing is trivial.
 * -------------------------------------------------------------------- */

static void write_snap_obj(FILE *f, Snapshot *s)
{
    int i, j;
    fprintf(f, "{\"d\":[");
    for (i = 0; i < 8; i++) fprintf(f, "%s%lu", i ? "," : "", s->d[i]);
    fprintf(f, "],\"a\":[");
    for (i = 0; i < 8; i++) fprintf(f, "%s%lu", i ? "," : "", s->a[i]);
    fprintf(f, "],\"fp\":[");
    for (i = 0; i < 8; i++) {
        fprintf(f, "%s\"", i ? "," : "");
        for (j = 0; j < 12; j++) fprintf(f, "%02x", s->fp[i][j]);
        fprintf(f, "\"");
    }
    fprintf(f, "],\"fpcr\":%lu,\"fpsr\":%lu,\"fpiar\":%lu}",
            s->fpcr, s->fpsr, s->fpiar);
}

/* Escape a JSON string. We don't try to be fully RFC-compliant -- just
 * handle the characters that actually appear in test names: '"' and '\\'.
 * Test names from the generator don't have control chars. */
static void write_json_name(FILE *f, const char *name)
{
    const char *p = name;
    fputc('"', f);
    while (*p) {
        if (*p == '"' || *p == '\\') fputc('\\', f);
        fputc(*p, f);
        p++;
    }
    fputc('"', f);
}

int main(void)
{
    FILE *f;
    int i;

    f = fopen("FPU Results Full.jsonl", "w");
    if (f == NULL) {
        printf("Cannot open output file.\n");
        return 1;
    }

    printf("Running %u FPU tests against real 68881...\n", FPU_N_TESTS);

    for (i = 0; i < FPU_N_TESTS; i++) {
        u8 *entry;
        const FpuTestSpec *t = &g_fpu_tests[i];

        memset(&init_snap,  0, sizeof(init_snap));
        memset(&final_snap, 0, sizeof(final_snap));

        entry = build_program(t);
        flush_icache();
        printf("[%d/%u] %s\n", i + 1, FPU_N_TESTS, t->name);
        invoke_program(entry);

        fputc('{', f);
        fprintf(f, "\"name\":");
        write_json_name(f, t->name);
        fprintf(f, ",\"initial\":");
        write_snap_obj(f, &init_snap);
        fprintf(f, ",\"final\":");
        write_snap_obj(f, &final_snap);
        fputs("}\n", f);
        fflush(f);
    }

    fclose(f);
    printf("Done. %u tests written to \"FPU Results Full.jsonl\".\n",
        FPU_N_TESTS);
    return 0;
}
