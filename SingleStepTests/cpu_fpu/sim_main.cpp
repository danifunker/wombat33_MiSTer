// Integrated TG68K + mc68881_top bench. Uses the tg68k.v bus wrapper, so
// DTACK handshaking is real and the FPU's multi-cycle DSACK response is
// honored.
//
// Modes:
//   ./Vcpu_fpu_tests                # smoke: MOVEQ #1; FMOVE.L D0,FP0;
//                                   #        FMOVE.L FP0,D1; STOP. Expect D1=1.
//   ./Vcpu_fpu_tests --trace        # smoke + per-cycle FPU dialog trace.
//   ./Vcpu_fpu_tests <corpus.json>  # JSON corpus runner (gen_fpu output).
//
// Corpus entry shape (one per test):
//   {
//     "name":"FNEG.X #5",
//     "op_a": 5,  ["op_b": <int>,]
//     "program":[<byte>,...],   // full program from MOVEQ #op_a,D0 to STOP
//     "result_reg": 1,           // Dn that holds the FMOVE.L FP0,Dn result
//     "expected": -5             // expected signed-int32 value of D{result_reg}
//   }
// The harness plants the program bytes at $1000, points reset vectors at it,
// runs until STOP, then checks D{result_reg} against expected.

#include <verilated.h>
#include "Vcpu_fpu_tests.h"
#include "Vcpu_fpu_tests__Syms.h"

#include <cstdint>
#include <cstdio>
#include <iostream>
#include <iomanip>
#include <fstream>
#include <vector>
#include <string>

#include "../json.hpp"
using json = nlohmann::json;

#define VERILATOR_MAJOR_VERSION (VERILATOR_VERSION_INTEGER / 1000000)
#if VERILATOR_MAJOR_VERSION >= 5
  #define VERTOPINTERN top->rootp
#else
  #define VERTOPINTERN top
#endif

vluint64_t main_time = 0;
double sc_time_stamp() { return main_time; }

static Vcpu_fpu_tests* top = nullptr;
static std::vector<uint8_t> ram;

static inline uint16_t ram_read16(uint32_t a) {
    a &= 0x00FFFFFE;
    return (uint16_t(ram[a]) << 8) | ram[a + 1];
}
static inline void ram_write16(uint32_t a, uint16_t v, bool uds, bool lds) {
    a &= 0x00FFFFFE;
    if (uds) ram[a]     = uint8_t(v >> 8);
    if (lds) ram[a + 1] = uint8_t(v & 0xFF);
}

static void service_ram() {
    if (top->as_n) return;
    if (top->fpu_select) return;
    const uint32_t a = top->addr_out;
    if (top->rw_n) top->data_in = ram_read16(a);
    else           ram_write16(a, top->data_write, !top->uds_n, !top->lds_n);
}

static int phase = 0;
static void tick() {
    top->phi1 = (phase == 0) ? 1 : 0;
    top->phi2 = (phase == 1) ? 1 : 0;
    top->clk = 0; top->eval();
    main_time++;
    top->clk = 1; top->eval();
    service_ram();
    main_time++;
    phase ^= 1;
}

static void finish() { top->final(); delete top; top = nullptr; }

static uint32_t get_reg(int i) {
    uint32_t n1 = VERTOPINTERN->cpu_fpu_tests__DOT__cpu__DOT__tg68k__DOT__regfile_n1[i];
    uint32_t n2 = VERTOPINTERN->cpu_fpu_tests__DOT__cpu__DOT__tg68k__DOT__regfile_n2[i];
    return (n2 << 8) | n1;
}

// Plant reset vectors + a program byte string at PROG_BASE.
static constexpr uint32_t PROG_BASE   = 0x00001000;
static constexpr uint32_t RESET_SSP   = 0x00FFFFF8;
static void plant_program(const uint8_t* bytes, size_t n) {
    std::fill(ram.begin(), ram.end(), 0);
    // Reset vectors: SSP at $0, PC at $4.
    ram[0] = (RESET_SSP >> 24) & 0xFF;
    ram[1] = (RESET_SSP >> 16) & 0xFF;
    ram[2] = (RESET_SSP >>  8) & 0xFF;
    ram[3] =  RESET_SSP        & 0xFF;
    ram[4] = (PROG_BASE >> 24) & 0xFF;
    ram[5] = (PROG_BASE >> 16) & 0xFF;
    ram[6] = (PROG_BASE >>  8) & 0xFF;
    ram[7] =  PROG_BASE        & 0xFF;
    for (size_t i = 0; i < n; ++i) ram[PROG_BASE + i] = bytes[i];
}

// Reset the kernel + run the planted program for at most max_cycles.
// Detects STOP by watching the kernel halt (busstate idle for many cycles).
static void reset_and_run(int max_cycles) {
    top->reset = 1;
    top->data_in = 0;
    phase = 0;
    for (int i = 0; i < 32; ++i) tick();
    top->reset = 0;
    for (int i = 0; i < max_cycles; ++i) tick();
}

// ---- Smoke test (no-arg / --trace mode) --------------------------------
static int run_smoke(bool trace) {
    static const uint8_t prog[] = {
        0x70, 0x01,                  // MOVEQ #1,D0
        0xF2, 0x00, 0x40, 0x00,      // FMOVE.L D0,FP0
        0xF2, 0x01, 0x60, 0x00,      // FMOVE.L FP0,D1
        0x4E, 0x72, 0x27, 0x00,      // STOP #$2700
    };
    plant_program(prog, sizeof(prog));

    top->reset = 1;
    top->data_in = 0;
    phase = 0;
    for (int i = 0; i < 32; ++i) tick();
    top->reset = 0;

    uint8_t prev_as = 1;
    uint8_t prev_micro = 0xFF;
    int max_cycles = 20000;
    for (int cyc = 0; cyc < max_cycles; ++cyc) {
        tick();
        if (trace) {
            static uint32_t prev_state_sig = 0xFFFFFFFFu;
            uint8_t cur_micro = top->dbg_micro_state;
            uint32_t cur_state_sig = (uint32_t(cur_micro) << 16)
                | (uint32_t(top->dbg_cir_state) << 8)
                | (uint32_t(top->dbg_cir_xfer_word_idx) << 4)
                | (uint32_t(top->dbg_fpu_bus_write) << 1)
                | uint32_t(top->dbg_cir_move_pending);
            if (cur_state_sig != prev_state_sig) {
                uint32_t fp0_0 = top->dbg_fp0[0];
                uint32_t fp0_1 = top->dbg_fp0[1];
                uint32_t fp0_2 = top->dbg_fp0[2] & 0xFFFFu;
                uint32_t op1_0 = top->dbg_operand_reg_1[0];
                uint32_t op1_1 = top->dbg_operand_reg_1[1];
                uint32_t op1_2 = top->dbg_operand_reg_1[2] & 0xFFFFu;
                std::cerr << "    [cyc " << std::setw(5) << cyc
                          << "] ms=" << std::dec << int(cur_micro)
                          << " cir=" << int(top->dbg_cir_state)
                          << " idx=" << int(top->dbg_cir_xfer_word_idx)
                          << " bw=" << int(top->dbg_fpu_bus_write)
                          << " mpend=" << int(top->dbg_cir_move_pending)
                          << " launch=" << int(top->dbg_cir_launch_alu)
                          << " a_in=" << int(top->dbg_fpu_addr)
                          << " stg=0x" << std::hex << std::setw(8) << std::setfill('0')
                          << top->dbg_cir_operand_staging[1]
                          << "_" << std::setw(8) << top->dbg_cir_operand_staging[0]
                          << std::dec << std::setfill(' ') << "\n";
                prev_state_sig = cur_state_sig;
                prev_micro = cur_micro;
            }
            uint8_t cur_as = top->as_n;
            if (prev_as && !cur_as) {
                std::cerr << "  cyc " << std::setw(5) << cyc
                          << " fc=" << int(top->fc)
                          << " rw=" << int(top->rw_n)
                          << " addr=0x" << std::hex << std::setw(8)
                          << std::setfill('0') << top->addr_out
                          << (top->rw_n ? " rd" : " wr")
                          << " data=0x" << std::setw(4)
                          << (top->rw_n
                                ? (top->fpu_select ? (top->fpu_d_out_obs & 0xFFFF)
                                                   : ram_read16(top->addr_out))
                                : top->data_write)
                          << std::dec << std::setfill(' ')
                          << (top->fpu_select ? " [FPU]" : "") << "\n";
            }
            prev_as = cur_as;
        }
    }

    uint32_t d0 = get_reg(0);
    uint32_t d1 = get_reg(1);
    std::cerr << "D0 = 0x" << std::hex << std::setw(8) << std::setfill('0') << d0
              << "  (MOVEQ #1 -> expect 0x00000001)\n"
              << "D1 = 0x" << std::setw(8) << d1
              << "  (FMOVE.L D0,FP0; FMOVE.L FP0,D1 round-trip -> expect 0x00000001)\n"
              << std::dec << std::setfill(' ');
    bool pass = (d0 == 1) && (d1 == 1);
    std::cerr << (pass ? "PASS — FMOVE.L D0,FP0,D1 round-trip works\n"
                       : "FAIL — FMOVE round-trip did not produce expected value\n");
    return pass ? 0 : 1;
}

// ---- Corpus runner (JSON-driven) ---------------------------------------
static int run_corpus(const std::string& fname, bool trace) {
    std::ifstream f(fname);
    if (!f) { std::cerr << "Cannot open " << fname << "\n"; return 1; }
    json corpus = json::parse(f);

    int passed = 0, failed = 0;
    for (auto& t : corpus) {
        const std::string name = t.value("name", "<unnamed>");
        auto& prog_arr = t["program"];
        std::vector<uint8_t> prog;
        prog.reserve(prog_arr.size());
        for (auto& b : prog_arr) prog.push_back(uint8_t(b.get<unsigned>()));
        const int  result_reg = t["result_reg"].get<int>();
        const int32_t expected = t["expected"].get<int32_t>();

        plant_program(prog.data(), prog.size());

        if (trace) std::cerr << "=== " << name << " ===\n";

        // Reset + run. 5000 ticks is more than enough for any single FPU op.
        if (trace) {
            top->reset = 1; top->data_in = 0; phase = 0;
            for (int i = 0; i < 32; ++i) tick();
            top->reset = 0;
            uint32_t prev_state_sig = 0xFFFFFFFFu;
            for (int cyc = 0; cyc < 5000; ++cyc) {
                tick();
                uint8_t cur_micro = top->dbg_micro_state;
                uint32_t cur_state_sig = (uint32_t(cur_micro) << 16)
                    | (uint32_t(top->dbg_cir_state) << 8)
                    | (uint32_t(top->dbg_fpu_xfer_phase) << 6)
                    | (uint32_t(top->dbg_cir_move_pending) << 4)
                    | uint32_t(top->dbg_cir_launch_alu);
                if (cur_state_sig != prev_state_sig) {
                    uint32_t fp0_0 = top->dbg_fp0[0];
                    uint32_t fp0_1 = top->dbg_fp0[1];
                    uint32_t fp0_2 = top->dbg_fp0[2] & 0xFFFFu;
                    uint32_t stg0  = top->dbg_cir_operand_staging[0];
                    std::cerr << "    [cyc " << std::setw(5) << cyc
                              << "] ms=" << std::dec << int(cur_micro)
                              << " cir=" << int(top->dbg_cir_state)
                              << " op=0x" << std::hex << std::setw(4) << std::setfill('0')
                              << top->dbg_opcode
                              << " cond=0x" << std::setw(2)
                              << int(top->dbg_cir_cond_reg)
                              << " fpsr=0x" << std::setw(8) << top->dbg_fpsr
                              << " resp=0x" << std::setw(8) << top->dbg_cir_response_reg
                              << " din=0x" << std::setw(4) << top->dbg_data_in
                              << " t1111=" << std::dec << int(top->dbg_trap_1111)
                              << " br=" << int(top->dbg_cp_do_branch)
                              << " btgt=0x" << std::hex << std::setw(8) << top->dbg_cp_branch_target
                              << " pc=0x" << std::setw(8) << top->dbg_pc
                              << std::dec << std::setfill(' ') << "\n";
                    prev_state_sig = cur_state_sig;
                }
            }
        } else {
            reset_and_run(5000);
        }

        uint32_t got = get_reg(result_reg);
        int32_t got_s = int32_t(got);
        bool ok = (got_s == expected);
        if (ok) {
            ++passed;
        } else {
            ++failed;
            std::cerr << "FAIL " << name
                      << ": D" << result_reg << " got " << got_s
                      << " (0x" << std::hex << got << std::dec
                      << "), expected " << expected
                      << " (0x" << std::hex << uint32_t(expected) << std::dec
                      << ")\n";
        }
    }

    std::cerr << passed << " passed, " << failed << " failed in "
              << fname << "\n";
    return failed ? 1 : 0;
}

int main(int argc, char** argv, char** env) {
    top = new Vcpu_fpu_tests();
    Verilated::commandArgs(argc, argv);
    Verilated::traceEverOn(true);
    ram.assign(0x01000000, 0x00);

    int rc;
    bool trace = false;
    int argi = 1;
    if (argi < argc && std::string(argv[argi]) == "--trace") {
        trace = true; ++argi;
    }
    if (argi >= argc)          rc = run_smoke(trace);
    else                       rc = run_corpus(argv[argi], trace);
    finish();
    return rc;
}
