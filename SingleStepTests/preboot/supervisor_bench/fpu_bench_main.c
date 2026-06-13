/* fpu_bench_main.c — supervisor-mode FPU bench.
 *
 * The pre-OS sibling of macos_bench/fpu_bench.c. Same test corpus
 * (gen/fpu_tests.h, kept in lockstep with gen/mame_fpu_capture.lua) and
 * same hand-emitted machine code, but runs in supervisor mode straight
 * out of the boot block instead of as a Mac OS APPL, and writes results
 * via the raw-sector jsonl_writer instead of stdio.
 *
 * Each test:
 *   1. resets D0..D7 / A0..A6 (A7 is our C stack),
 *   2. runs the preload (loads FP0..FP7 etc.),
 *   3. dumps an "initial" snapshot,
 *   4. runs the test instruction,
 *   5. dumps a "final" snapshot,
 * then emits one JSONL line. If the test instruction faults, the
 * recovery path (recovery.s) longjmps back with the vector number and
 * the final dump never runs — we emit the pre-trap snapshot as
 * "trap_state" instead, exactly like the CPU bench (bench_main.c).
 *
 * This is a SEPARATE artifact from the CPU bench: its own bench_main,
 * its own payload (payload_fpu_scsi.bin), its own disk image. It links
 * against the same payload_entry_cpu.s entry shim (the momentary "CPU
 * BENCH" banner it paints is wiped immediately below) and the same
 * variant_cpu_scsi.s results-offset markers. */

#include "bench_types.h"
#include "eject.h"
#include "freestanding.h"
#include "jsonl_writer.h"
#include "../../gen/fpu_tests.h"

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

/* FPU snapshot. Field offsets are baked into the machine code emitted
 * below, so the struct MUST stay tightly packed in this order (mirrors
 * macos_bench/fpu_bench.c so diff tooling reads identical fields). */
typedef struct {
    u8  fp[8][12];   /* 0x00 — FP0..FP7 in extended precision (96 bits) */
    u32 d[8];        /* 0x60 — D0..D7                                   */
    u32 a[8];        /* 0x80 — A0..A7                                   */
    u32 fpcr;        /* 0xA0                                            */
    u32 fpsr;        /* 0xA4                                            */
    u32 fpiar;       /* 0xA8                                            */
} FpuSnapshot;

static FpuSnapshot init_snap;
static FpuSnapshot final_snap;
static u8 prog_buffer[1024];

/* ---- Machine-code emitters (mirror macos_bench/fpu_bench.c) ---- */
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
/* FMOVE.X FPn,(An)+ — 4 bytes, writes 12 bytes of extended FP data.
 * MAME's m68kfpu can't store FMOVE.X to abs.L; postincrement works on
 * both MAME and a real 68881. */
static u8 *emit_fmove_x_to_an_postinc(u8 *p, int fpn, int an) {
    p = put_w(p, (u16)(0xF218 | (an & 7)));
    return put_w(p, (u16)(0x6800 | (fpn << 7)));
}
/* FMOVE.L FPcr,(abs.L) — 8 bytes. reg_mask: 0x1000=FPCR, 0x0800=FPSR,
 * 0x0400=FPIAR. */
static u8 *emit_fmove_l_ctrl_to_abs(u8 *p, u16 reg_mask, u32 addr) {
    p = put_w(p, 0xF239);
    p = put_w(p, (u16)(0xA000 | reg_mask));
    return put_l(p, addr);
}

/* Reset D0..D7 and A0..A6 (A7 = our C stack). 15 words. */
static u8 *emit_register_reset(u8 *p) {
    int n;
    for (n = 0; n < 8; n++) p = put_w(p, (u16)(0x7000 | (n << 9)));     /* MOVEQ #0,Dn */
    for (n = 0; n < 7; n++) p = put_w(p, (u16)(0x91C8 | (n << 9) | n)); /* SUBA.L An,An */
    return p;
}

/* A regs first (so A0 is still the test's value), then FP via (A0)+,
 * then D regs, then control regs. */
static u8 *emit_state_dump(u8 *p, FpuSnapshot *snap) {
    u32 base = (u32) snap;
    int i;
    for (i = 0; i < 8; i++) p = emit_move_l_an_to_abs(p, i, base + 0x80 + i * 4);
    p = emit_movea_l_imm_to_an(p, 0, base);
    for (i = 0; i < 8; i++) p = emit_fmove_x_to_an_postinc(p, i, 0);
    for (i = 0; i < 8; i++) p = emit_move_l_dn_to_abs(p, i, base + 0x60 + i * 4);
    p = emit_fmove_l_ctrl_to_abs(p, 0x1000, base + 0xA0);
    p = emit_fmove_l_ctrl_to_abs(p, 0x0800, base + 0xA4);
    p = emit_fmove_l_ctrl_to_abs(p, 0x0400, base + 0xA8);
    return p;
}

static u8 *build_program(const FpuTestSpec *t) {
    u8 *entry = prog_buffer;
    u8 *p = entry;

    p = emit_register_reset(p);
    if (t->preload_len) { f_memcpy(p, t->preload, t->preload_len); p += t->preload_len; }
    p = emit_state_dump(p, &init_snap);
    f_memcpy(p, t->test, t->test_len);
    p += t->test_len;
    p = emit_state_dump(p, &final_snap);
    *p++ = 0x4E; *p++ = 0x75;     /* RTS */
    return entry;
}

/* 68040 cache flush — the 040 has no CACR cache-control bits, so we
 * CPUSHA BC ($F4F8): push dirty data lines (the freshly written
 * prog_buffer) to memory AND invalidate both caches so the CPU fetches
 * the new test bytes. Required between tests since we keep rewriting
 * prog_buffer. Privileged — we're in supervisor mode. */
static void flush_icache(void) {
    asm volatile (
        ".short 0xF4F8           \n"   /* cpusha bc (push+invalidate both) */
        : : : "memory"
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

static void write_snap(JsonlWriter *w, const FpuSnapshot *s) {
    int i, j;
    jw_puts(w, "{\"d\":[");
    for (i = 0; i < 8; i++) { if (i) jw_putc(w, ','); jw_putul(w, s->d[i]); }
    jw_puts(w, "],\"a\":[");
    for (i = 0; i < 8; i++) { if (i) jw_putc(w, ','); jw_putul(w, s->a[i]); }
    jw_puts(w, "],\"fp\":[");
    for (i = 0; i < 8; i++) {
        if (i) jw_putc(w, ',');
        jw_putc(w, '[');
        for (j = 0; j < 12; j++) { if (j) jw_putc(w, ','); jw_putul(w, s->fp[i][j]); }
        jw_putc(w, ']');
    }
    jw_puts(w, "],\"fpcr\":"); jw_putul(w, s->fpcr);
    jw_puts(w, ",\"fpsr\":");  jw_putul(w, s->fpsr);
    jw_puts(w, ",\"fpiar\":"); jw_putul(w, s->fpiar);
    jw_putc(w, '}');
}

/* Decimal into width-padded buffer (>=11 bytes) for status display. */
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

/* Full corpus, inclusive range. Narrow only for targeted debugging. */
#define FIRST_TEST_INDEX 0
#define LAST_TEST_INDEX  (FPU_N_TESTS - 1)

static JwCtx g_jw_ctx;
static JsonlWriter g_jw;

void bench_main(void) {
    u8 *entry;
    char buf[16];
    int idx;
    u32 n_run = 0, n_ok = 0, n_trap = 0;
    JsonlWriter *w = &g_jw;

    install_vbr();

    g_jw_ctx.refnum      = g_handoff_refnum;
    g_jw_ctx.drive       = g_handoff_drive;
    g_jw_ctx.base_offset = g_results_offset;
    g_jw_ctx.max_bytes   = g_results_max_bytes;
    jw_init(w, &g_jw_ctx);

    wipe_screen();
    paint_string(4, 4, "SUPERVISOR FPU BENCH - full corpus", 40);
    paint_string(16, 4, "Test ", 5);
    paint_string(16, 14, ": ", 2);

    for (idx = FIRST_TEST_INDEX; idx <= LAST_TEST_INDEX; idx++) {
        const FpuTestSpec *t = &g_fpu_tests[idx];
        u32 crashed_vec;

        n_run++;
        format_decimal(buf, idx + 1, 4);
        paint_string(16, 9, buf, 4);
        paint_string(16, 16, t->name, 60);

        f_memset(&init_snap,  0, sizeof(init_snap));
        f_memset(&final_snap, 0, sizeof(final_snap));

        entry = build_program(t);
        flush_icache();
        crashed_vec = (u32)invoke_test_with_recovery(entry);
        asm volatile ("move.w #0x2700, %%sr" : : : "memory");

        /* On a trap the final dump didn't run; init_snap holds the
         * pre-trap state (it was dumped right before the test). */
        const FpuSnapshot *display_snap = crashed_vec ? &init_snap : &final_snap;
        if (crashed_vec) n_trap++; else n_ok++;

        paint_string(28, 4, "run=", 4);   format_decimal(buf, n_run, 4);  paint_string(28, 8,  buf, 4);
        paint_string(28, 14, "ok=", 3);   format_decimal(buf, n_ok, 4);   paint_string(28, 17, buf, 4);
        paint_string(28, 24, "trap=", 5); format_decimal(buf, n_trap, 4); paint_string(28, 29, buf, 4);
        format_hex32(buf, crashed_vec);
        paint_string(28, 36, "lastvec=", 8); paint_string(28, 44, buf + 6, 2);

        jw_putc(w, '{');
        jw_puts(w, "\"name\":"); write_name(w, t->name);
        jw_puts(w, ",\"vec\":"); jw_putul(w, crashed_vec);
        jw_puts(w, crashed_vec ? ",\"trap_state\":" : ",\"final\":");
        write_snap(w, display_snap);
        jw_puts(w, "}\n");
    }

    wipe_screen();
    paint_string(4, 4, "ALL FPU TESTS DONE - writing results...", 45);
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
