/*
 * cpu_fpu_bench.c -- Mac OS APPL that runs the CPU+FPU integration
 * test corpus (SingleStepTests/cpu_fpu/fpu_corpus_baseline.json,
 * converted to cpu_fpu_tests.h by gen_cpu_fpu_header.py).
 *
 * For each test the harness:
 *   1. Loads op_a into D0.
 *   2. Loads scratch_ram base into A6 (some programs use it).
 *   3. JSRs into the program byte sequence.
 *   4. Reads the result D-register from a snapshot taken at the
 *      end of the program (the program is responsible for storing
 *      its result into the requested D-register before returning).
 *   5. Compares to the expected value, emits a JSONL line:
 *        {"name":..., "op_a":N, "expected":N, "actual":N, "pass":0/1}
 *   6. Output file: "CPU FPU Results.jsonl"
 *
 * Builds with Retro68. Runs as a normal Mac OS app on a 68020+68881.
 */

#include <stdio.h>
#include <string.h>
#include <Files.h>
#include "cpu_fpu_tests.h"

typedef unsigned char  u8;
typedef unsigned short u16;
typedef unsigned long  u32;

typedef struct {
    u32 d[8];
    u32 a[8];
} Snapshot;

static Snapshot final_snap;
static u8 scratch_ram[64];
static u8 prog_buffer[256];        /* harness preamble + program + dump */

/* --- emitters --- */
static u8 *put_w(u8 *p, u16 v) { *p++=(u8)(v>>8); *p++=(u8)v; return p; }
static u8 *put_l(u8 *p, u32 v) {
    *p++=(u8)(v>>24); *p++=(u8)(v>>16);
    *p++=(u8)(v>>8);  *p++=(u8) v;       return p;
}
static u8 *emit_move_l_dn_to_abs(u8 *p, int dn, u32 addr) {
    p = put_w(p, (u16)(0x23C0 | (dn & 7))); return put_l(p, addr);
}
static u8 *emit_move_l_an_to_abs(u8 *p, int an, u32 addr) {
    p = put_w(p, (u16)(0x23C8 | (an & 7))); return put_l(p, addr);
}
static u8 *emit_movea_l_imm_to_an(u8 *p, int an, u32 imm) {
    p = put_w(p, (u16)(0x207C | ((an & 7) << 9))); return put_l(p, imm);
}
static u8 *emit_move_l_imm_to_dn(u8 *p, int dn, u32 imm) {
    /* MOVE.L #imm, Dn = 0x203C..0x2E3C */
    p = put_w(p, (u16)(0x203C | ((dn & 7) << 9))); return put_l(p, imm);
}

/* Build: D0=op_a, A6=scratch base, then program bytes, then dump regs. */
static u8 *build_program(const CpuFpuTestSpec *t)
{
    u8 *entry = prog_buffer;
    u8 *p = entry;
    int n;
    /* clear D1..D7 (D0 will be loaded with op_a next) */
    for (n = 1; n < 8; n++) p = put_w(p, (u16)(0x7000 | (n << 9)));
    /* clear A0..A5 (A6 = scratch, A7 = stack) */
    for (n = 0; n < 6; n++) p = put_w(p, (u16)(0x91C8 | (n << 9) | n));
    p = emit_movea_l_imm_to_an(p, 6, (u32) &scratch_ram[0]);
    p = emit_move_l_imm_to_dn(p, 0, (u32) t->op_a);

    /* Embed the program, but neutralize STOP #$2700 (4E 72 27 00).
     * The baseline corpus uses STOP as an "end of test" marker assuming
     * supervisor mode; in user mode it's privileged and traps.
     *
     *   Case A (1248/1328 tests): STOP is the LAST 4 bytes. Strip it; the
     *   harness's state-dump + RTS already terminate cleanly. Behavior
     *   identical to the original strip-tail logic (kept byte-for-byte so
     *   we don't perturb tests that already pass).
     *
     *   Case B (~80 tests): STOP appears mid-program, with PC-relative
     *   inline data after it (e.g. FMOVE.X (d16,PC),FP0 reads 12 bytes
     *   sitting past the STOP). Stripping would shift offsets and break
     *   the d16 reference, so we instead REPLACE the 4-byte STOP with
     *   BRA.W disp16, branching over the inline data into the dump.
     *   Position of the 4 bytes is preserved, so any PC-relative d16 in
     *   the test remains valid. Tail STOPs go through case A only. */
    {
        unsigned short n = t->program_len;
        memcpy(p, t->program, n);
        if (n >= 4 &&
            p[n-4] == 0x4E && p[n-3] == 0x72 &&
            p[n-2] == 0x27 && p[n-1] == 0x00) {
            n -= 4;
        } else {
            /* Look for an embedded STOP and swap it for BRA.W over the
             * remaining bytes. disp16 = (bytes_after_stop + 2): the
             * BRA's PC counts from the displacement word, which sits 2
             * bytes after the BRA opword, so adding the remainder lands
             * us exactly at the end of the embedded program. */
            unsigned short i;
            for (i = 0; i + 4 <= n; i++) {
                if (p[i] == 0x4E && p[i+1] == 0x72 &&
                    p[i+2] == 0x27 && p[i+3] == 0x00) {
                    unsigned short disp = (unsigned short)(n - i - 2);
                    p[i]   = 0x60; p[i+1] = 0x00;
                    p[i+2] = (u8)(disp >> 8);
                    p[i+3] = (u8) disp;
                    break;
                }
            }
        }
        p += n;
    }

    /* state dump (D0..D7, A0..A7) */
    {
        u32 base = (u32) &final_snap;
        for (n = 0; n < 8; n++) p = emit_move_l_an_to_abs(p, n, base + 0x20 + n*4);
        for (n = 0; n < 8; n++) p = emit_move_l_dn_to_abs(p, n, base + 0x00 + n*4);
    }
    *p++ = 0x4E; *p++ = 0x75;     /* RTS */
    return entry;
}

static void flush_icache(void)
{
    asm volatile (
        "moveq #1, %%d0          \n"
        ".short 0xA198           \n"   /* _HwPriv FlushInstructionCache */
        :
        :
        : "d0", "cc"
    );
}

/* Save SP before the test runs so we can recover even if the test
 * leaves SP shifted (e.g. RTD with non-zero stack adjustment). */
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

#ifndef CPU_FPU_OUTPUT_DIR
#define CPU_FPU_OUTPUT_DIR "CPU FPU Results"
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
    if (lo == 1) sprintf(dir, ":%s:1-99", CPU_FPU_OUTPUT_DIR);
    else         sprintf(dir, ":%s:%d-%d", CPU_FPU_OUTPUT_DIR, lo, lo + 99);
    sprintf(buf, "%s:%04d.jsonl", dir, test_num);

    if (lo != last_bucket_lo) {
        mac_mkdir(CPU_FPU_OUTPUT_DIR);
        mac_mkdir(dir);
        last_bucket_lo = lo;
    }
}

int main(void)
{
    FILE *f;
    int i, passed = 0;
    char path[128];

    /* Set the Retro68 console window title. */
    printf("\033]0;MacII CPU/FPU Bench lbmactwo_MiSTer\007");

    printf("Running %d CPU+FPU integration tests...\n", CPU_FPU_N_TESTS);

    for (i = 0; i < CPU_FPU_N_TESTS; i++) {
        const CpuFpuTestSpec *t = &g_cpu_fpu_tests[i];
        u8 *entry;
        long actual;
        int pass;

        memset(&final_snap, 0, sizeof(final_snap));
        memset(scratch_ram, 0, sizeof(scratch_ram));

        entry = build_program(t);
        flush_icache();
        /* Per-test line — needed to diagnose freezes. Clear the screen
         * every 50 tests to keep the buffer bounded (unbounded growth
         * historically crashed the Toolbox). Clear runs BEFORE the new
         * line so the screen is never left blank. */
        if (i > 0 && (i % 50) == 0)
            printf("\033[H\033[2J");
        printf("[%d/%d] %s\n", i + 1, CPU_FPU_N_TESTS, t->name);
        invoke_program(entry);

        actual = (long) final_snap.d[t->result_reg];
        pass = (actual == t->expected) ? 1 : 0;
        if (pass) passed++;

        /* One file per test under CPU_FPU_OUTPUT_DIR/<bucket>/. */
        test_output_path(path, i);
        f = fopen(path, "w");
        if (f == NULL) {
            printf("Cannot open \"%s\" at test %d.\n", path, i);
            return 1;
        }
        fputc('{', f);
        fprintf(f, "\"name\":"); write_json_name(f, t->name);
        fprintf(f, ",\"op_a\":%ld", t->op_a);
        fprintf(f, ",\"result_reg\":%u", t->result_reg);
        fprintf(f, ",\"expected\":%ld", t->expected);
        fprintf(f, ",\"actual\":%ld", actual);
        fprintf(f, ",\"pass\":%d", pass);
        fputs("}\n", f);
        fclose(f);
    }

    printf("Done. %d/%d passed. Results under \"%s\".\n",
           passed, CPU_FPU_N_TESTS, CPU_FPU_OUTPUT_DIR);
    return 0;
}
