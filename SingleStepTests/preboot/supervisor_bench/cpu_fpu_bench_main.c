/* cpu_fpu_bench_main.c — supervisor-mode CPU+FPU integration bench.
 *
 * The pre-OS sibling of macos_bench/cpu_fpu_bench.c. Runs the CPU+FPU
 * integration corpus (cpu_fpu/fpu_corpus_baseline.json, converted to
 * cpu_fpu_tests.h by macos_bench/gen_cpu_fpu_header.py) straight out of
 * the boot block in supervisor mode, writing results via the raw-sector
 * jsonl_writer instead of stdio.
 *
 * The corpus header is generated into macos_bench/ (its only home), so
 * we reach it by relative path — there is no gen/ copy. Keep the include
 * pointed at the canonical file rather than duplicating 190 KB of data.
 *
 * For each test the harness:
 *   1. clears D1..D7 and A0..A5, sets A6 = scratch base,
 *   2. loads op_a into D0,
 *   3. jsrs into the program byte sequence (with recovery installed),
 *   4. reads D[result_reg] from the post-program snapshot,
 *   5. compares it to expected and emits a JSONL line:
 *        {"name","op_a","result_reg","expected","actual","pass","vec"}
 *
 * STOP #$2700 handling: the baseline corpus terminates each program
 * with STOP #$2700. We ARE in supervisor mode (so STOP isn't a
 * privilege violation like it is for the Mac OS app), but STOP #$2700
 * sets IPL=7 and parks the CPU until a level-7 interrupt that never
 * comes — it would hang the bench. So we neutralize it exactly as the
 * macos bench does (strip a tail STOP, or replace an embedded STOP with
 * BRA.W over the trailing inline data so PC-relative refs stay valid).
 *
 * Separate artifact: its own bench_main / payload (payload_cpu_fpu_scsi
 * .bin) / disk image. Shares payload_entry_cpu.s and variant_cpu_scsi.s
 * with the other supervisor benches. */

#include "bench_types.h"
#include "eject.h"
#include "freestanding.h"
#include "jsonl_writer.h"
/* Corpus header is overridable at build time so the same runner drives
 * either the full integration corpus (default) or a focused sub-corpus
 * such as the FSAVE/FRESTORE set — both emit identical CpuFpuTestSpec /
 * g_cpu_fpu_tests / CPU_FPU_N_TESTS symbols (see gen_cpu_fpu_header.py).
 * Override with -DCPU_FPU_CORPUS_HEADER='"../../macos_bench/save_restore_tests.h"'. */
#ifndef CPU_FPU_CORPUS_HEADER
#define CPU_FPU_CORPUS_HEADER "../../macos_bench/cpu_fpu_tests.h"
#endif
#include CPU_FPU_CORPUS_HEADER

/* Provided by payload_entry_cpu.s — handoff slot at $00041000 */
extern volatile i16 g_handoff_refnum;
extern volatile i16 g_handoff_drive;
extern u32  g_results_offset;     /* patched per variant (variant_cpu_scsi.s) */
extern u32  g_results_max_bytes;

/* recovery.s — VBR + longjmp-style exception escape. */
extern void install_vbr(void);
extern int invoke_test_with_recovery(u8 *entry);   /* 0 = OK, !=0 = vector */

/* Provided by display_1bpp.c (font_ascii.o). */
extern void paint_string(u32 row, u32 col_byte, const char *s, u32 max_chars);

typedef struct { u32 d[8]; u32 a[8]; } IntSnapshot;

static IntSnapshot final_snap;
static u8 scratch_ram[64];
static u8 prog_buffer[256];

/* ---- emitters (mirror macos_bench/cpu_fpu_bench.c) ---- */
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
    p = put_w(p, (u16)(0x203C | ((dn & 7) << 9))); return put_l(p, imm);
}

static u8 *build_program(const CpuFpuTestSpec *t) {
    u8 *entry = prog_buffer;
    u8 *p = entry;
    int n;

    for (n = 1; n < 8; n++) p = put_w(p, (u16)(0x7000 | (n << 9)));     /* MOVEQ #0,Dn (D1..D7) */
    for (n = 0; n < 6; n++) p = put_w(p, (u16)(0x91C8 | (n << 9) | n)); /* SUBA.L An,An (A0..A5) */
    p = emit_movea_l_imm_to_an(p, 6, (u32) &scratch_ram[0]);
    p = emit_move_l_imm_to_dn(p, 0, (u32) t->op_a);

    /* Embed the program, neutralizing STOP #$2700 (4E 72 27 00). See the
     * file header for the full rationale; logic is byte-for-byte the
     * same as macos_bench/cpu_fpu_bench.c so passing tests stay stable. */
    {
        unsigned short len = t->program_len;
        f_memcpy(p, t->program, len);
        if (len >= 4 &&
            p[len-4] == 0x4E && p[len-3] == 0x72 &&
            p[len-2] == 0x27 && p[len-1] == 0x00) {
            len -= 4;                         /* tail STOP: drop it */
        } else {
            unsigned short i;
            for (i = 0; i + 4 <= len; i++) {
                if (p[i] == 0x4E && p[i+1] == 0x72 &&
                    p[i+2] == 0x27 && p[i+3] == 0x00) {
                    unsigned short disp = (unsigned short)(len - i - 2);
                    p[i]   = 0x60; p[i+1] = 0x00;     /* BRA.W disp */
                    p[i+2] = (u8)(disp >> 8);
                    p[i+3] = (u8) disp;
                    break;
                }
            }
        }
        p += len;
    }

    {
        u32 base = (u32) &final_snap;
        for (n = 0; n < 8; n++) p = emit_move_l_an_to_abs(p, n, base + 0x20 + n*4);
        for (n = 0; n < 8; n++) p = emit_move_l_dn_to_abs(p, n, base + 0x00 + n*4);
    }
    *p++ = 0x4E; *p++ = 0x75;     /* RTS */
    return entry;
}

static void flush_icache(void) {
    asm volatile (
        "moveq #9, %%d0          \n"   /* CI | EI = 0x09 */
        ".long 0x4E7B0002        \n"   /* movec d0, cacr */
        : : : "d0"
    );
}

static void write_name(JsonlWriter *w, const char *name) {
    jw_putc(w, '"');
    while (*name) {
        if (*name == '"' || *name == '\\') jw_putc(w, '\\');
        jw_putc(w, *name);
        name++;
    }
    jw_putc(w, '"');
}

/* jsonl_writer only has unsigned output; corpus op_a/expected/actual are
 * signed longs. Emit a leading '-' then the magnitude. The unsigned
 * negate is correct even for LONG_MIN. */
static void write_long(JsonlWriter *w, i32 v) {
    if (v < 0) { jw_putc(w, '-'); jw_putul(w, (u32)(0u - (u32)v)); }
    else       { jw_putul(w, (u32)v); }
}

static void format_decimal(char *out, u32 v, int width) {
    char tmp[11];
    int n = 0, i;
    if (v == 0) tmp[n++] = '0';
    while (v) { tmp[n++] = (char)('0' + (v % 10)); v /= 10; }
    for (i = 0; i < width - n; i++) *out++ = ' ';
    while (n--) *out++ = tmp[n];
    *out = '\0';
}

static void format_hex32(char *out, u32 v) {
    const char *digits = "0123456789ABCDEF";
    int i;
    for (i = 7; i >= 0; i--) { out[i] = digits[v & 0xF]; v >>= 4; }
    out[8] = '\0';
}

static void wipe_screen(void) {
    u32 fb = *(u32 *)0x0824;
    u32 *p = (u32 *)fb;
    u32 i;
    if (fb < 0x00100000) return;
    for (i = 0; i < 9600; i++) *p++ = 0xFFFFFFFF;   /* 640x480 1bpp */
}

#define FIRST_TEST_INDEX 0
#define LAST_TEST_INDEX  (CPU_FPU_N_TESTS - 1)

static JwCtx g_jw_ctx;
static JsonlWriter g_jw;

void bench_main(void) {
    u8 *entry;
    char buf[16];
    int idx;
    u32 n_run = 0, n_pass = 0, n_fail = 0, n_trap = 0;
    JsonlWriter *w = &g_jw;

    install_vbr();

    g_jw_ctx.refnum      = g_handoff_refnum;
    g_jw_ctx.drive       = g_handoff_drive;
    g_jw_ctx.base_offset = g_results_offset;
    g_jw_ctx.max_bytes   = g_results_max_bytes;
    jw_init(w, &g_jw_ctx);

    wipe_screen();
    paint_string(4, 4, "SUPERVISOR CPU/FPU BENCH - full corpus", 45);
    paint_string(16, 4, "Test ", 5);
    paint_string(16, 14, ": ", 2);

    for (idx = FIRST_TEST_INDEX; idx <= LAST_TEST_INDEX; idx++) {
        const CpuFpuTestSpec *t = &g_cpu_fpu_tests[idx];
        u32 crashed_vec;
        i32 actual;
        int pass;

        n_run++;
        format_decimal(buf, idx + 1, 4);
        paint_string(16, 9, buf, 4);
        paint_string(16, 16, t->name, 60);

        f_memset(&final_snap, 0, sizeof(final_snap));
        f_memset(scratch_ram, 0, sizeof(scratch_ram));

        entry = build_program(t);
        flush_icache();
        crashed_vec = (u32)invoke_test_with_recovery(entry);
        asm volatile ("move.w #0x2700, %%sr" : : : "memory");

        actual = (i32) final_snap.d[t->result_reg];
        /* A faulted test has no meaningful result; never count it pass. */
        pass = (!crashed_vec && actual == t->expected) ? 1 : 0;
        if (crashed_vec) n_trap++;
        if (pass) n_pass++; else if (!crashed_vec) n_fail++;

        paint_string(28, 4, "run=", 4);   format_decimal(buf, n_run, 4);  paint_string(28, 8,  buf, 4);
        paint_string(28, 14, "ok=", 3);   format_decimal(buf, n_pass, 4); paint_string(28, 17, buf, 4);
        paint_string(28, 24, "bad=", 4);  format_decimal(buf, n_fail, 4); paint_string(28, 28, buf, 4);
        paint_string(28, 35, "trap=", 5); format_decimal(buf, n_trap, 4); paint_string(28, 40, buf, 4);

        jw_putc(w, '{');
        jw_puts(w, "\"name\":"); write_name(w, t->name);
        jw_puts(w, ",\"op_a\":");      write_long(w, t->op_a);
        jw_puts(w, ",\"result_reg\":"); jw_putul(w, t->result_reg);
        jw_puts(w, ",\"expected\":");  write_long(w, t->expected);
        jw_puts(w, ",\"actual\":");    write_long(w, actual);
        jw_puts(w, ",\"vec\":");       jw_putul(w, crashed_vec);
        jw_puts(w, ",\"pass\":");      jw_putul(w, (u32)pass);
        jw_puts(w, "}\n");
    }

    wipe_screen();
    paint_string(4, 4, "ALL CPU/FPU TESTS DONE - writing results...", 50);
    paint_string(16, 4, "passed=", 7); format_decimal(buf, n_pass, 4); paint_string(16, 11, buf, 4);
    paint_string(16, 18, "of ", 3);    format_decimal(buf, n_run, 4);  paint_string(16, 21, buf, 4);
    jw_flush(w);

    format_hex32(buf, (u32)(u16)w->last_err);
    paint_string(28, 4, "ioResult=", 9);
    paint_string(28, 13, buf + 4, 4);
    paint_string(52, 4, "Power off and extract /Results.jsonl", 40);

    if (g_handoff_drive == 1 || g_handoff_drive == 2) {
        i16 ej = eject_floppy(g_handoff_drive);
        paint_string(76, 4, "EJECT drv=", 10);
        format_decimal(buf, (u32)g_handoff_drive, 1);
        paint_string(76, 14, buf, 1);
        paint_string(76, 16, "res=", 4);
        format_hex32(buf, (u32)(u16)ej);
        paint_string(76, 20, buf + 4, 4);
    }

    for (;;) { asm volatile (""); }
}
