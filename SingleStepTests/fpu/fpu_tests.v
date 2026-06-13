// SingleStep bench wrapper for mc68881_top (Verilog `fpu_lite` build).
//
// The MC68881 is a coprocessor, not a CPU — it has no instruction stream of
// its own. The harness drives the CIR register interface (a_in is the
// 5-bit register offset into the 32-byte CIR space) with operand writes,
// then polls Response/Status to advance through each m68020 coprocessor
// instruction (cpGEN / cpSAVE / cpRESTORE).
//
// Bus protocol (from mc68881_top entity):
//   - size_n[1:0]: active-low transfer size encoding
//   - as_n / ds_n: bus strobes
//   - cs_n:        chip select
//   - rw:          1=read, 0=write
//   - dsack0_n/dsack1_n: returned port size acknowledge

module fpu_tests
  (
   input          clk,
   input          reset,           // active high
   input  [4:0]   a_in,
   input  [31:0]  d_in,
   output [31:0]  d_out,
   input  [1:0]   size_n,
   input          as_n,
   input          cs_n,
   input          rw,
   input          ds_n,
   output         dsack0_n,
   output         dsack1_n,
   output         status_valid
   );

   // sense_n is the FPU's presence-detect inout. We don't drive it from
   // outside (no master pulls it low here); tie observed value to 'Z' via
   // a tri-state stub so verilator doesn't complain about the bidir port.
   wire sense_n;
   assign sense_n = 1'bz;

   // CIR address remap — mirrors LBMacTwo.sv. C++ driver passes the
   // standard MC68881 reg index; remap the three that collide with
   // peripheral-mode registers (0/2/3 → 13/12/28).
   wire [4:0] a_in_remapped = (a_in == 5'd0) ? 5'd13 :
                              (a_in == 5'd2) ? 5'd12 :
                              (a_in == 5'd3) ? 5'd28 : a_in;

   mc68881_top fpu
     (
      .a_in         (a_in_remapped),
      .d_in         (d_in),
      .d_out        (d_out),
      .size_n       (size_n),
      .as_n         (as_n),
      .cs_n         (cs_n),
      .rw           (rw),
      .ds_n         (ds_n),
      .dsack0_n     (dsack0_n),
      .dsack1_n     (dsack1_n),
      .reset_n      (~reset),
      .clk          (clk),
      .sense_n      (sense_n),
      .status_valid (status_valid)
      );
endmodule
