// Integrated TG68K + mc68881_top bench for FPU instruction testing.
//
// Uses the bus wrapper `tg68k.v` (not raw kernel) so DTACK handshaking
// works correctly for the multi-cycle FPU response. Address decode +
// DTACK arbitration mirrors verilator/sim.v.

module cpu_fpu_tests
  (
   input         clk,             // single clock; bus wrapper uses phi1/phi2 enables
   input         reset,           // active high
   input         phi1,
   input         phi2,

   // Bus visible to host C harness for RAM-backed accesses.
   input  [15:0] data_in,
   output [15:0] data_write,
   output [31:0] addr_out,
   output        as_n,
   output        uds_n,
   output        lds_n,
   output        rw_n,
   output        longword,
   output [2:0]  fc,
   output        fpu_select,      // active when CPU is talking to FPU

   // FPU debug visibility.
   output        fpu_status_valid,
   output [31:0] fpu_d_out_obs,
   output        fpu_dsack0_n_obs,
   output        fpu_dsack1_n_obs,

   // Architectural CPU taps (mirror of tg68k_tests.v). The CPU here is
   // wrapped in tg68k.v, so the kernel sits one hierarchy level deeper:
   // cpu_fpu_tests.cpu.tg68k.<wire>.
   output [31:0] pc_out,
   output [15:0] sr_out,
   output [31:0] usp_out,

   // CPU internal taps for FPU dispatch debugging.
   output [7:0]  dbg_micro_state,
   output [31:0] dbg_cp_xfer_data,
   output [31:0] dbg_data_write_tmp,
   output [2:0]  dbg_cp_xfer_cnt,
   output [31:0] dbg_d0,
   output [31:0] dbg_d1,
   output [31:0] dbg_data_write_muxin,
   output [15:0] dbg_data_in,
   output [31:0] dbg_last_data_read,
   output [31:0] dbg_data_read,
   output [1:0]  dbg_state,
   output [79:0] dbg_fp0,
   // FPU-side internal taps for FMOVE-write-to-FP debugging.
   output        dbg_cir_move_pending,
   output        dbg_cir_launch_alu,
   output [4:0]  dbg_cir_state,
   output [2:0]  dbg_cir_dst_reg_idx,
   output [79:0] dbg_operand_reg_1,
   output        dbg_fpu_bus_write,
   output [4:0]  dbg_fpu_addr,
   output [95:0] dbg_cir_operand_staging,
   output [5:0]  dbg_cir_xfer_word_idx,
   output [31:0] dbg_fpu_rd_latch,
   output        dbg_fpu_xfer_phase,
   output [31:0] dbg_fpu_d_out,
   output [15:0] dbg_opcode,
   output [15:0] dbg_exe_opcode,
   output        dbg_trap_1111,
   output        dbg_trap_illegal,
   output        dbg_trapmake,
   output [5:0]  dbg_cir_cond_reg,
   output [31:0] dbg_fpsr,
   output [31:0] dbg_cir_response_reg,
   output        dbg_cp_do_branch,
   output [31:0] dbg_cp_branch_target,
   output [31:0] dbg_pc
   );

   // Hierarchical taps into the TG68K kernel inside the bus wrapper.
   // Path: cpu_fpu_tests → cpu (tg68k.v) → tg68k (TG68KdotC_Kernel).
   // micro_state is an enum; ghdl-synth lowers it to a small int.
   assign dbg_micro_state    = cpu.tg68k.micro_state;
   assign dbg_cp_xfer_data   = cpu.tg68k.cp_xfer_data;
   assign dbg_data_write_tmp = cpu.tg68k.data_write_tmp;
   assign dbg_cp_xfer_cnt    = 3'b000;  // cnt removed (per-word states now)
   // Regfile is split high/low per the TG68K split-array convention.
   assign dbg_d0 = ({cpu.tg68k.regfile_n2[0], 8'h00} | {24'h0, cpu.tg68k.regfile_n1[0]});
   assign dbg_d1 = ({cpu.tg68k.regfile_n2[1], 8'h00} | {24'h0, cpu.tg68k.regfile_n1[1]});
   assign dbg_data_write_muxin = cpu.tg68k.data_write_muxin;
   assign dbg_data_in = cpu.tg68k.data_in;
   assign dbg_last_data_read = cpu.tg68k.last_data_read;
   assign dbg_data_read = cpu.tg68k.data_read;
   assign dbg_state = cpu.tg68k.state;
   // FP register file is a packed reg [639:0] = 8x80 bits. ghdl-synth
   // convention is to map VHDL array index 0 to the HIGH bits — so FP0
   // lives at bits [639:560], FP7 at bits [79:0].
   // These taps reach into mc68881_top internals; stubbed out when
   // USE_FPU_STUB selects sim_fpu_cir_stub (which has no such state).
`ifdef USE_FPU_STUB
   assign dbg_fp0 = 80'd0;
   assign dbg_cir_move_pending = 1'b0;
   assign dbg_cir_launch_alu   = 1'b0;
   assign dbg_cir_state        = 5'd0;
   assign dbg_cir_dst_reg_idx  = 3'd0;
   assign dbg_operand_reg_1    = 80'd0;
   assign dbg_fpu_bus_write    = 1'b0;
   assign dbg_fpu_addr         = fpu.a_in;
   assign dbg_cir_operand_staging = 96'd0;
   assign dbg_cir_xfer_word_idx = 6'd0;
`else
   assign dbg_fp0 = fpu.fp_reg_file_reg[(0)*80 +: 80];  // FP0 slot 0
   assign dbg_cir_move_pending = fpu.cir_move_pending_reg;
   assign dbg_cir_launch_alu   = fpu.cir_launch_alu;
   assign dbg_cir_state        = fpu.cir_state_reg;
   assign dbg_cir_dst_reg_idx  = fpu.cir_dst_reg_idx;
   assign dbg_operand_reg_1    = fpu.operand_reg[159:80];
   assign dbg_fpu_bus_write    = fpu.bus_write;
   assign dbg_fpu_addr         = fpu.a_in;
   assign dbg_cir_operand_staging = fpu.cir_operand_staging;
   assign dbg_cir_xfer_word_idx = fpu.cir_xfer_word_idx;
`endif
   assign dbg_fpu_rd_latch     = fpu_rd_latch;
   assign dbg_fpu_xfer_phase   = fpu_xfer_phase;
   assign dbg_fpu_d_out        = fpu_d_out;
   assign dbg_opcode           = cpu.tg68k.opcode;
   assign dbg_exe_opcode       = cpu.tg68k.exe_opcode;
   assign dbg_trap_1111        = cpu.tg68k.trap_1111;
   assign dbg_trap_illegal     = cpu.tg68k.trap_illegal;
   assign dbg_trapmake         = cpu.tg68k.trapmake;
`ifdef USE_FPU_STUB
   assign dbg_cir_cond_reg     = 6'd0;
   assign dbg_fpsr             = 32'd0;
   assign dbg_cir_response_reg = 32'd0;
`else
   assign dbg_cir_cond_reg     = fpu.cir_condition_reg;
   assign dbg_fpsr             = fpu.fpsr_reg;
   assign dbg_cir_response_reg = fpu.cir_response_reg;
`endif
   assign dbg_cp_do_branch     = cpu.tg68k.cp_do_branch;
   assign dbg_cp_branch_target = cpu.tg68k.cp_branch_target;
   assign dbg_pc               = cpu.tg68k.tg68_pc;

   // Architectural CPU taps (mirror of tg68k_tests.v). pc_out duplicates
   // dbg_pc; sr_out and usp_out are unique to this set.
   assign pc_out  = cpu.tg68k.tg68_pc;
   assign sr_out  = {cpu.tg68k.flagssr, cpu.tg68k.flags};
   assign usp_out = cpu.tg68k.usp;

   // -------------------- CPU bus signals --------------------------------
   wire [31:0] cpu_addr;
   wire [15:0] cpu_dout;
   wire        cpu_rw_n, cpu_as_n, cpu_uds_n, cpu_lds_n;
   wire        cpu_longword;
   wire [2:0]  cpu_fc;

   // Data presented back to the CPU: comes from FPU when fpu_select is
   // asserted, otherwise from external RAM (driven by host harness).
   wire [31:0] fpu_d_out;
   // Note: fpu_d_to_cpu is defined below in the bus-adapter section.
   wire [15:0] fpu_d_to_cpu;
   wire [15:0] cpu_din_mux = fpu_select ? fpu_d_to_cpu : data_in;

   // -------------------- FPU address decode -----------------------------
   wire fpu_addr_match = (cpu_fc == 3'b111)
                       && (cpu_addr[31:16] == 16'h0002)
                       && (cpu_addr[15:13] == 3'b001);
   wire fpu_cs = fpu_addr_match && !cpu_as_n;
   assign fpu_select = fpu_cs;

   // -------------------- FPU DSACK → DTACK ------------------------------
   wire fpu_dsack0_n, fpu_dsack1_n;

   // -------------------- 16-bit ↔ 32-bit bus adapter --------------------
   // TG68K has a 16-bit data bus and splits .L into 2 word transfers.
   // mc68881_top's d_in is 32-bit and expects ONE transfer per .L (per
   // cir_xfer_word_count = 1 for CIR_SRC_LONG). So the bench:
   //   - WRITES (CPU→FPU): latches the first 16-bit half into fpu_wr_hi.
   //     Suppresses fpu_cs_n on the first half (FPU sees nothing) and
   //     fakes a DSACK back to TG68K. On the second half, drives
   //     fpu_d_in = {fpu_wr_hi, cpu_dout} as a single 32-bit transfer
   //     and lets FPU's DSACK pass through.
   //   - READS (FPU→CPU): on the first half, lets FPU strobe normally
   //     and latches the full 32-bit FPU d_out into fpu_rd_latch. TG68K
   //     gets the HIGH word. On the second half, suppresses fpu_cs_n
   //     (FPU doesn't advance), fakes DSACK, returns the LOW half from
   //     the latch.
   reg        fpu_xfer_phase;   // 0 = first half (HIGH), 1 = second half (LOW)
   reg [15:0] fpu_wr_hi;
   reg [31:0] fpu_rd_latch;
   reg        prev_as_for_phase;
   // Aggregation only applies to the Operand CIR register (addr 8, after
   // the remap above). Response (remap → 13), Command (5), OpWord (4) etc.
   // are single 16-bit transfers; pass them straight through to the FPU.
   wire       fpu_is_operand_cycle = (fpu_addr_remapped == 5'd8);
   // Flip phase on the END of each FPU operand bus cycle (AS-rising edge
   // while addressed at operand). This way phase is stable throughout each
   // bus cycle: first access sees phase=0, second access sees phase=1.
   wire       fpu_bus_end_edge = fpu_addr_match && fpu_is_operand_cycle
                                 && cpu_as_n && !prev_as_for_phase;
   // Latch data DURING the access so it's captured before AS rises.
   wire       fpu_bus_in_access = fpu_addr_match && fpu_is_operand_cycle
                                  && !cpu_as_n;
   always @(posedge clk) begin
      if (reset) begin
         fpu_xfer_phase  <= 1'b0;
         fpu_wr_hi       <= 16'h0000;
         fpu_rd_latch    <= 32'h0000_0000;
         prev_as_for_phase <= 1'b1;
      end else begin
         prev_as_for_phase <= cpu_as_n;
         // Capture data at the END of each access (AS-rising-edge), when
         // the FPU has just dsacked and data is valid AND stable for one
         // more cycle. Latches simultaneously with the phase flip.
         if (fpu_bus_end_edge && fpu_xfer_phase == 1'b0) begin
            if (!cpu_rw_n) fpu_wr_hi    <= cpu_dout;
            else           fpu_rd_latch <= fpu_d_out;
         end
         if (fpu_bus_end_edge) begin
            fpu_xfer_phase <= ~fpu_xfer_phase;
         end
      end
   end

   // FPU bus signals.
   // For non-Operand (single-transfer) accesses: pass-through cs_n unchanged.
   // For Operand accesses:
   //   - WRITES (cpu_rw_n=0): FPU active on phase=1 (second half), suppressed
   //     on phase=0 (which the bench acks itself after latching the HIGH word).
   //   - READS  (cpu_rw_n=1): FPU active on phase=0 (first half) so it drives
   //     a real d_out; suppressed on phase=1 (bench serves the LOW word
   //     from the latch).
   wire fpu_active_phase = cpu_rw_n ? !fpu_xfer_phase : fpu_xfer_phase;
   wire fpu_cs_n_eff = fpu_is_operand_cycle
                       ? ~(fpu_addr_match && fpu_active_phase)
                       : ~fpu_addr_match;
   wire [31:0] fpu_d_in_eff = (fpu_is_operand_cycle && !cpu_rw_n)
                              ? {fpu_wr_hi, cpu_dout}
                              : {16'h0000, cpu_dout};
   // TG68K-side dsack: fake during the inactive phase, pass-through during
   // the active phase.
   wire fpu_inactive_phase_act = fpu_addr_match && fpu_is_operand_cycle
                                 && !cpu_as_n && !fpu_active_phase;
   wire eff_dsack0_n = fpu_inactive_phase_act ? 1'b0 : fpu_dsack0_n;
   wire eff_dsack1_n = fpu_inactive_phase_act ? 1'b1 : fpu_dsack1_n;
   wire cpu_dtack_n  = fpu_addr_match ? (eff_dsack0_n & eff_dsack1_n) : 1'b0;
   // TG68K read mux:
   //  - Non-Operand: pass FPU's d_out[15:0] (16-bit response/save/etc).
   //  - Operand phase=0: HIGH word direct from FPU's d_out[31:16].
   //  - Operand phase=1: LOW word from latch.
   assign fpu_d_to_cpu = fpu_is_operand_cycle
                         ? (fpu_xfer_phase ? fpu_rd_latch[15:0]
                                           : fpu_d_out[31:16])
                         : fpu_d_out[15:0];

   // -------------------- TG68K bus wrapper ------------------------------
   tg68k cpu (
      .clk        (clk),
      .reset      (reset),
      .phi1       (phi1),
      .phi2       (phi2),
      .cpu        (2'b11),
      .dtack_n    (cpu_dtack_n),
      .rw_n       (cpu_rw_n),
      .as_n       (cpu_as_n),
      .uds_n      (cpu_uds_n),
      .lds_n      (cpu_lds_n),
      .fc         (cpu_fc),
      .reset_n    (),
      .E          (),
      .E_div      (1'b1),
      .E_PosClkEn (),
      .E_NegClkEn (),
      .vma_n      (),
      .vpa_n      (1'b1),     // never assert VPA in this bench
      .br_n       (1'b1),
      .bg_n       (),
      .bgack_n    (1'b1),
      .ipl        (3'b111),
      .berr       (1'b0),
      .cpu_halted (),
      .din        (cpu_din_mux),
      .dout       (cpu_dout),
      .longword   (cpu_longword),
      .addr       (cpu_addr),
      .VBR_out    (),
      .berr_inhibit (),
      .berr_data    ()
   );

   assign addr_out   = cpu_addr;
   assign data_write = cpu_dout;
   assign as_n       = cpu_as_n;
   assign uds_n      = cpu_uds_n;
   assign lds_n      = cpu_lds_n;
   assign rw_n       = cpu_rw_n;
   assign longword   = cpu_longword;
   assign fc         = cpu_fc;

   // -------------------- mc68881_top instance ---------------------------
   wire sense_n;
   assign sense_n = 1'bz;

   // CIR register address remapping — mirrors LBMacTwo.sv. mc68881_top
   // uses non-standard addresses for the CIR regs that collide with
   // peripheral-mode addresses 0/2/3.
   wire [4:0] fpu_addr_remapped = (cpu_addr[5:1] == 5'd0) ? 5'd13 :
                                  (cpu_addr[5:1] == 5'd2) ? 5'd12 :
                                  (cpu_addr[5:1] == 5'd3) ? 5'd28 :
                                                            cpu_addr[5:1];

   // Size encoding: derive from longword + UDS/LDS.
   wire [1:0] fpu_size_n =
       cpu_as_n                   ? 2'b11 :  // idle
       cpu_longword               ? 2'b00 :  // .L
       (!cpu_uds_n && !cpu_lds_n) ? 2'b10 :  // .W
                                    2'b01;   // .B

   assign fpu_d_out_obs    = fpu_d_out;
   assign fpu_dsack0_n_obs = fpu_dsack0_n;
   assign fpu_dsack1_n_obs = fpu_dsack1_n;

`ifdef USE_FPU_STUB
   // CIR-protocol stub: drops every FPU op into an F-line trap. Use for
   // validating that the CPU correctly takes the trap when no real FPU
   // logic is present; matches the configuration of verilator/sim.v.
   sim_fpu_cir_stub fpu
     (
      .a_in         (fpu_addr_remapped),
      .d_in         (fpu_d_in_eff),
      .d_out        (fpu_d_out),
      .size_n       (fpu_size_n),
      .as_n         (cpu_as_n),
      .cs_n         (fpu_cs_n_eff),
      .rw           (cpu_rw_n),
      .ds_n         (cpu_uds_n & cpu_lds_n),
      .dsack0_n     (fpu_dsack0_n),
      .dsack1_n     (fpu_dsack1_n),
      .reset_n      (~reset),
      .clk          (clk),
      .sense_n      (sense_n),
      .status_valid (fpu_status_valid)
      );
`else
   mc68881_top fpu
     (
      .a_in         (fpu_addr_remapped),
      .d_in         (fpu_d_in_eff),
      .d_out        (fpu_d_out),
      .size_n       (fpu_size_n),
      .as_n         (cpu_as_n),
      .cs_n         (fpu_cs_n_eff),
      .rw           (cpu_rw_n),                 // 1=read, 0=write
      .ds_n         (cpu_uds_n & cpu_lds_n),
      .dsack0_n     (fpu_dsack0_n),
      .dsack1_n     (fpu_dsack1_n),
      .reset_n      (~reset),
      .clk          (clk),
      .sense_n      (sense_n),
      .status_valid (fpu_status_valid)
      );
`endif
endmodule
