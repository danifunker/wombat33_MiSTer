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
#include <Files.h>
#include "fpu_tests.h"

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

/* Single buffer reused across tests. flush_icache() before each JSR
 * evicts stale 68020 cache lines so the freshly-assembled program is
 * what actually runs. (The legacy per-slot layout would need ~140 KB
 * for 270 tests; not viable for a Mac OS APPL's static footprint.) */
static u8 prog_buffer[512];

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
 * Test catalog comes from fpu_tests.h, generated by
 * gen_fpu_header.py and kept in lockstep with the Lua MAME capture
 * (SingleStepTests/gen/mame_fpu_capture.lua).
 * -------------------------------------------------------------------- */

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
    asm volatile (
        "moveq #1, %%d0          \n"
        ".short 0xA198           \n"   /* _HwPriv */
        :
        :
        : "d0", "cc"
    );
}

/* Save all callee-saved C registers, JSR into the assembled test, then
 * restore. The test program freely clobbers D0-D7/A0-A6 by design.
 * SP is saved/restored explicitly to survive tests that leave SP at
 * an unexpected offset (e.g. RTD with non-zero stack adjustment). */
static unsigned long g_saved_sp;

static void invoke_program(u8 *entry)
{
    asm volatile (
        "moveml %%d2-%%d7/%%a2-%%a6, -(%%sp)   \n"
        "movel  %%sp, %0                       \n"
        "movel  %1, %%a0                       \n"
        "jsr    (%%a0)                         \n"
        "movel  %0, %%sp                       \n"
        "moveml (%%sp)+, %%d2-%%d7/%%a2-%%a6   \n"
        : "+m" (g_saved_sp)
        : "g" (entry)
        : "a0", "a1", "d0", "d1", "cc", "memory"
    );
}

/* --------------------------------------------------------------------
 * Output formatting -- JSONL, one line per test (matches CPU bench).
 * FP registers are 12-byte extended-precision values, emitted as
 * arrays of byte integers so they round-trip without precision loss
 * and can be diffed exactly against the MAME oracle.
 * -------------------------------------------------------------------- */

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

static void write_snap_obj(FILE *f, Snapshot *s)
{
    int i, j;
    fprintf(f, "{\"d\":[");
    for (i = 0; i < 8; i++) fprintf(f, "%s%lu", i ? "," : "", s->d[i]);
    fprintf(f, "],\"a\":[");
    for (i = 0; i < 8; i++) fprintf(f, "%s%lu", i ? "," : "", s->a[i]);
    fprintf(f, "],\"fp\":[");
    for (i = 0; i < 8; i++) {
        fprintf(f, "%s[", i ? "," : "");
        for (j = 0; j < 12; j++) fprintf(f, "%s%u", j ? "," : "", s->fp[i][j]);
        fputc(']', f);
    }
    fprintf(f, "],\"fpcr\":%lu,\"fpsr\":%lu,\"fpiar\":%lu}",
            s->fpcr, s->fpsr, s->fpiar);
}

#ifndef FPU_OUTPUT_DIR
#define FPU_OUTPUT_DIR "FPU Results"
#endif

/* See cpu_bench.c for bucket-folder rationale and the PBDirCreateSync
 * detour around Retro68's stubbed POSIX mkdir. */
static void mac_mkdir(const char *path)
{
    HParamBlockRec pb;
    Str255 pname;
    size_t n = strlen(path);
    if (n > 255) return;
    pname[0] = (unsigned char)n;
    memcpy(&pname[1], path, n);
    memset(&pb, 0, sizeof(pb));
    pb.fileParam.ioNamePtr = pname;
    pb.fileParam.ioVRefNum = 0;
    pb.fileParam.ioDirID = 0;
    PBDirCreateSync(&pb);
}

static void test_output_path(char *buf, int i)
{
    static int last_bucket_lo = -2;
    int test_num = i + 1;
    int lo;
    char dir[80];

    if (test_num <= 99) lo = 1;
    else lo = (test_num / 100) * 100;

    /* Leading ':' makes the partial pathname relative to the working
     * directory; see cpu_bench.c for the rationale. */
    if (lo == 1) sprintf(dir, ":%s:1-99", FPU_OUTPUT_DIR);
    else         sprintf(dir, ":%s:%d-%d", FPU_OUTPUT_DIR, lo, lo + 99);
    sprintf(buf, "%s:%04d.jsonl", dir, test_num);

    if (lo != last_bucket_lo) {
        mac_mkdir(FPU_OUTPUT_DIR);
        mac_mkdir(dir);
        last_bucket_lo = lo;
    }
}

int main(void)
{
    FILE *f;
    int i;
    char path[128];

    /* Xterm-style OSC sequence sets the Retro68 console window title. */
    printf("\033]0;FPU Bench lbmactwo_MiSTer\007");

    printf("Running %u FPU tests against real 68881...\n",
           (unsigned)FPU_N_TESTS);

    for (i = 0; i < (int)FPU_N_TESTS; i++) {
        const FpuTestSpec *t = &g_fpu_tests[i];
        u8 *entry;

        memset(&init_snap,  0, sizeof(init_snap));
        memset(&final_snap, 0, sizeof(final_snap));

        entry = build_program(t);
        flush_icache();
        /* Per-test line so a freeze names the offending test. Clear the
         * screen every 50 tests to bound the console buffer; clear runs
         * BEFORE the new line so the screen is never blank. */
        if (i > 0 && (i % 50) == 0)
            printf("\033[H\033[2J");
        printf("[%d/%u] %s\n", i + 1, (unsigned)FPU_N_TESTS, t->name);
        invoke_program(entry);

        /* One file per test under FPU_OUTPUT_DIR/<bucket>/. */
        test_output_path(path, i);
        f = fopen(path, "w");
        if (f == NULL) {
            printf("Cannot open \"%s\" at test %d.\n", path, i);
            return 1;
        }
        fputc('{', f);
        fprintf(f, "\"name\":"); write_json_name(f, t->name);
        fprintf(f, ",\"initial\":"); write_snap_obj(f, &init_snap);
        fprintf(f, ",\"final\":");   write_snap_obj(f, &final_snap);
        fputs("}\n", f);
        fclose(f);
    }

    printf("Done. %u tests written under \"%s\".\n",
           (unsigned)FPU_N_TESTS, FPU_OUTPUT_DIR);
    return 0;
}
