// SingleStep harness for mc68881_top (fpu_lite Verilog build).
//
// The 68881 talks to its host CPU through a 32-byte CIR register file.
// A real test sequence per FPU instruction is:
//   - write the F-line opcode and source operands at the appropriate CIR
//     offsets (with size_n / cs_n / as_n / ds_n strobes), waiting for
//     dsack0/1 each transfer
//   - poll the Response CIR until the FPU signals "come get result"
//   - read the result CIR(s) back
//
// This file currently scaffolds the bus driver (reset + idle handshake) and
// is the place where the JSON-driven test loop will live once the test
// corpus format is decided.

#include <verilated.h>
#include "Vfpu_tests.h"
#include "Vfpu_tests__Syms.h"

#include <cstdio>
#include <cstdint>
#include <iostream>
#include <fstream>
#include <string>

#include "../json.hpp"
#include "fline_disasm.h"
using json = nlohmann::json;

// Pretty-print a 68881 F-line instruction. Musashi's stock 68020
// disassembler can't decode FPU coprocessor opcodes without full state, so
// we use a small purpose-built decoder (fline_disasm.h).
static const char* disasm_fline(unsigned int /*pc*/, unsigned short opword,
                                unsigned short ext_word = 0) {
    return fline::disasm(opword, ext_word);
}

#define VERILATOR_MAJOR_VERSION (VERILATOR_VERSION_INTEGER / 1000000)
#if VERILATOR_MAJOR_VERSION >= 5
  #define VERTOPINTERN top->rootp
#else
  #define VERTOPINTERN top
#endif

vluint64_t main_time = 0;
double sc_time_stamp() { return main_time; }

static Vfpu_tests* top = nullptr;

static void tick() {
    top->clk = 0;
    top->eval();
    main_time++;
    top->clk = 1;
    top->eval();
    main_time++;
}

// Drive a single CIR access. Asserts as_n+ds_n+cs_n, waits for dsack, then
// releases strobes. Caller must set rw and (for writes) d_in before calling.
static uint32_t bus_cycle(uint8_t offset, bool write, uint8_t size_code,
                         uint32_t wdata = 0) {
    top->a_in   = offset & 0x1F;
    top->size_n = size_code & 0x3;
    top->rw     = write ? 0 : 1;
    top->d_in   = wdata;

    top->cs_n   = 0;
    top->as_n   = 0;
    top->ds_n   = 0;

    // Wait for ack with a watchdog (FPU may need many cycles for long ops).
    int watchdog = 1000;
    while (top->dsack0_n && top->dsack1_n && watchdog--) tick();
    uint32_t result = top->d_out;

    top->cs_n = 1;
    top->as_n = 1;
    top->ds_n = 1;
    tick();
    return result;
}

static void finish() {
    top->final();
    delete top;
    top = nullptr;
}

int main(int argc, char** argv, char** env) {
    top = new Vfpu_tests();
    Verilated::commandArgs(argc, argv);
    Verilated::traceEverOn(true);

    // Idle bus state, then reset for several cycles.
    top->a_in   = 0;
    top->d_in   = 0;
    top->size_n = 0x3;          // idle (size_n is active-low)
    top->as_n   = 1;
    top->cs_n   = 1;
    top->rw     = 1;
    top->ds_n   = 1;

    top->reset = 1;
    for (int i = 0; i < 32; ++i) tick();
    top->reset = 0;
    for (int i = 0; i < 8; ++i) tick();

    if (argc < 2) {
        std::cerr << "fpu bench: reset OK ("
                  << main_time << " sim units). status_valid="
                  << int(top->status_valid) << "\n";
        struct { uint16_t op, ext; const char* label; } cases[] = {
            { 0xF200, 0x0080, "FMOVE.X FP0,FP1     " },
            { 0xF200, 0x0022, "FADD.X  FP0,FP0     " },
            { 0xF210, 0x8423, "FMUL.S  (A0),FP0    " },
            { 0xF200, 0x0038, "FCMP.X  FP0,FP0     " },
            { 0xF248, 0x0001, "FDBEQ   D0,disp     " },
            { 0xF28E, 0x1234, "FBNE.W  disp        " },
            { 0xF327, 0x0000, "FSAVE   -(A7)       " },
            { 0xF35F, 0x0000, "FRESTORE (A7)+      " },
        };
        for (auto& c : cases) {
            std::cerr << "  " << c.label << " => "
                      << disasm_fline(0, c.op, c.ext) << "\n";
        }
        finish();
        return 0;
    }

    // ---- WIRE-UP NOTES ---------------------------------------------------
    // Test corpus format still TBD. Likely shape per entry:
    //   { name, opword, operand_a, operand_b?, expected_result, expected_fpsr }
    // The harness will:
    //   1. write opword + operands to the CIR (using bus_cycle)
    //   2. poll Response CIR for "result ready"
    //   3. read result CIR(s), compare to expected
    // Probable internal regfile path: fpu_tests__DOT__fpu__DOT__... — to be
    // confirmed against the ghdl-synth'd verilog once it builds.
    // ---------------------------------------------------------------------

    const std::string fname(argv[1]);
    std::ifstream f(fname);
    if (!f) {
        std::cerr << "Cannot open " << fname << "\n";
        finish();
        return 1;
    }
    std::cerr << "fpu bench: JSON test loop not yet implemented "
                 "(corpus format pending). File: "
              << fname << "\n";
    finish();
    return 0;
}
