`timescale 1ns / 1ps
//============================================================================
//  wombat33 — Verilator simulation wrapper
//
//  `emu` here is the SIMULATION top — the sim-friendly port surface the
//  framework's sim_main.cpp drives.  Stage 1 of the machine bring-up: the
//  quadra800 machine (AP68040 + overlay + decode) with RAM/ROM/VRAM as
//  plain arrays behind the platform beat port.  The ROM image loads from
//  +rom=<hexfile> (default quadra800.rom.hex, built by the Makefile from
//  releases/quadra800.rom).  The template pattern core still paints the
//  VGA window and paces frames until DAFB lands in stage 2.
//============================================================================

module emu
(
	input         clk_sys,
	input         reset,

	// Template option bits (stand-ins for the MiSTer status word):
	//   sim_status[2]   TV mode (0 NTSC, 1 PAL)
	//   sim_status[4:3] Noise colour (0 white, 1 red, 2 green, 3 blue)
	input  [31:0] sim_status,

	// PS2 keyboard/mouse (unused by the template; wired for the machine)
	input  [10:0] ps2_key,
	input  [24:0] ps2_mouse,

	// VGA output
	output [7:0]  VGA_R,
	output [7:0]  VGA_G,
	output [7:0]  VGA_B,
	output        VGA_HS,
	output        VGA_VS,
	output        VGA_HB,
	output        VGA_VB,
	output        CE_PIXEL,

	// Audio output
	output [15:0] AUDIO_L,
	output [15:0] AUDIO_R,

	// ROM/disk loading interface (ioctl) — the MiSTer quadra800.rom path;
	// the sim loads the ROM by $readmemh instead
	input         ioctl_download,
	input         ioctl_wr,
	input  [24:0] ioctl_addr,
	input  [15:0] ioctl_dout,
	input  [7:0]  ioctl_index,
	output reg    ioctl_wait = 1'b0,

	// SCSI disk: MiSTer block-device surface for sim_blkdevice.cpp
	output [31:0] sd_lba0,
	output        sd_rd,
	output        sd_wr,
	input         sd_ack,
	input   [7:0] sd_buff_addr,
	input  [15:0] sd_buff_dout,
	output [15:0] sd_buff_din0,
	input         sd_buff_wr,
	input         img_mounted,
	input         img_readonly,
	input  [63:0] img_size,

	// CPU debug taps
	output [31:0] debug_pc,        // fetch pointer (debug_status pc)
	output [15:0] debug_opcode,    // current IR
	output        debug_fetch_valid,
	output [31:0] debug_data_addr, // last bus-error address
	output        debug_berr,      // machine bus-error pulse
	output        debug_overlay,
	output        debug_cpu_fault,
	output        debug_cpu_halted,
	output [15:0] debug_sr,
	output [31:0] debug_a7
);


//----------------------------------------------------------------------------
// The machine
//----------------------------------------------------------------------------
localparam RAM_ADDR_BITS = 27;                 // ceiling: 128 MB
// +ram=0|1|2 selects 32/64/128 MB, matching the OSD option on hardware
reg [1:0] ram_cfg = 2'd0;
initial if (!$value$plusargs("ram=%d", ram_cfg)) ram_cfg = 2'd0;
localparam RAM_WORDS  = 1 << (RAM_ADDR_BITS-2);
localparam ROM_WORDS  = 262144;                // 1 MB
// VRAM mirrors MacQuadra800.sv exactly: 308 KB backed, with the 204 KB fold
// that makes the unbacked 308K..512K window alias downward.  It used to be
// a flat 1 MB with no fold, so the fold had NEVER executed in sim and
// hardware-only video corruption was invisible here (RESUME-disk-gate.md
// carried this as a standing warning).
localparam VRAM_WORDS = 82016;                 // 320.4 KB: 512*160 + 96 tail
localparam [16:0] VRAM_FOLD = 17'd52224;       // 204 KB, in words
localparam [16:0] VRAM_TAIL = 17'd81920;       // 512 rows * 160 words

wire        mem_req, mem_write;
wire [31:2] mem_addr;
wire  [3:0] mem_be;
wire [31:0] mem_wdata;
wire  [1:0] mem_memsel;
reg  [31:0] mem_rdata;
reg         mem_ack;

wire [21:2] vid_addr;
wire [13:0] vid_stride;
wire        vram_compact = (vid_stride == 14'd1024);
reg  [31:0] vid_rdata;

wire [255:0] m_debug_status;
wire [127:0] m_debug_status2;

// The sim runs the scanout on clk_sys, as MacLC's does: the dedicated pixel
// clock only matters to the HDMI scaler on real hardware, and using it here
// would change every frame count in the existing sim regressions for no
// benefit. Frame rate in sim is therefore 78.6 Hz, not the hardware's 59.94.
quadra800 #(.RAM_ADDR_BITS(RAM_ADDR_BITS)) machine (
	.clk(clk_sys),
	.clk_vid(clk_sys),
	.nreset_vid(~reset),
	.ram_cfg(ram_cfg),
	.nreset(~reset),
	.ce(1'b1),

	.mem_req(mem_req),
	.mem_write(mem_write),
	.mem_addr(mem_addr),
	.mem_be(mem_be),
	.mem_wdata(mem_wdata),
	.mem_memsel(mem_memsel),
	.mem_rdata(mem_rdata),
	.mem_ack(mem_ack),

	.vid_addr(vid_addr),
	.vid_stride(vid_stride),
	.vid_rdata(vid_rdata),
	.VGA_R(VGA_R),
	.VGA_G(VGA_G),
	.VGA_B(VGA_B),
	.VGA_HS(VGA_HS),
	.VGA_VS(VGA_VS),
	.VGA_HB(VGA_HB),
	.VGA_VB(VGA_VB),
	.CE_PIXEL(CE_PIXEL),

	.AUDIO_L(AUDIO_L),
	.AUDIO_R(AUDIO_R),

	.ps2_key(ps2_key),
	.ps2_mouse(ps2_mouse),

	.img_mounted(img_mounted),
	.img_size(img_size),
	.io_lba(sd_lba0),
	.io_rd(sd_rd),
	.io_wr(sd_wr),
	.io_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din(sd_buff_din0),
	.sd_buff_wr(sd_buff_wr),

	// SCC serial.  Both RX lines idle high (nothing attached); TX is left
	// open — the boot path only needs the chip to answer the ROM's InitSCC
	// and selftest, which is exactly what this sim is for.
	.scc_rxd_a(1'b1),
	.scc_txd_a(),
	.scc_cts_a(1'b1),
	.scc_rts_a(),
	.scc_rxd_b(1'b1),
	.scc_txd_b(),

	.dbg_berr(debug_berr),
	.dbg_berr_addr(debug_data_addr),
	.dbg_overlay(debug_overlay),
	.debug_status(m_debug_status),
	.debug_status2(m_debug_status2),
	.debug_fault(debug_cpu_fault),
	.debug_halted(debug_cpu_halted)
);

assign debug_pc          = m_debug_status[31:0];
assign debug_opcode      = m_debug_status[63:48];
assign debug_sr          = m_debug_status[47:32];
assign debug_a7          = m_debug_status[95:64];
assign debug_fetch_valid = ~reset;

//----------------------------------------------------------------------------
// Platform memory: plain arrays behind the beat port (see quadra800.sv for
// the contract).  ROM writes are acked and discarded, as djMEMC does.
//----------------------------------------------------------------------------
reg [31:0] ram  [0:RAM_WORDS-1]  /*verilator public*/;
reg [31:0] rom  [0:ROM_WORDS-1]  /*verilator public*/;
reg [31:0] vram [0:VRAM_WORDS-1] /*verilator public*/;

reg [1023:0] rom_file;
initial begin
	if (!$value$plusargs("rom=%s", rom_file))
		rom_file = "quadra800.rom.hex";
	$readmemh(rom_file, rom);
	// +warmstart: preload the warm-start signature so the ROM skips the
	// destructive RAM test (iteration aid; cold boot leaves this off)
	if ($test$plusargs("warmstart")) ram['h33F] = "WLSC";
end

wire [RAM_ADDR_BITS-3:0] ram_idx  = mem_addr[RAM_ADDR_BITS-1:2];
wire [17:0]              rom_idx  = mem_addr[19:2];

function [16:0] vram_map(input [16:0] w);      // window word -> storage word
	reg [8:0] row;
	reg [7:0] col;
	begin
		row = w[16:8];
		col = w[7:0];
		if (!vram_compact)
			vram_map = (w >= VRAM_WORDS) ? (w - VRAM_FOLD) : w;
		else if (col < 8'd160)
			vram_map = {row, 7'd0} + {2'd0, row, 5'd0} + {9'd0, col};
		else
			vram_map = VRAM_TAIL + {9'd0, (col - 8'd160)};
	end
endfunction

wire [16:0]              vram_idx = vram_map(mem_addr[18:2]);

// DAFB scanout port: registered read, 1-cycle latency
always @(posedge clk_sys) vid_rdata <= vram[vram_map(vid_addr[18:2])];

always @(posedge clk_sys) begin
	mem_ack <= 0;
	if (mem_req && !mem_ack) begin
		mem_ack <= 1;
		case (mem_memsel)
		2'd0: begin
			mem_rdata <= ram[ram_idx];
			if (mem_write) begin
				if (mem_be[3]) ram[ram_idx][31:24] <= mem_wdata[31:24];
				if (mem_be[2]) ram[ram_idx][23:16] <= mem_wdata[23:16];
				if (mem_be[1]) ram[ram_idx][15:8]  <= mem_wdata[15:8];
				if (mem_be[0]) ram[ram_idx][7:0]   <= mem_wdata[7:0];
			end
		end
		2'd1: mem_rdata <= rom[rom_idx];
		default: begin
			mem_rdata <= vram[vram_idx];
			if (mem_write) begin
				if (mem_be[3]) vram[vram_idx][31:24] <= mem_wdata[31:24];
				if (mem_be[2]) vram[vram_idx][23:16] <= mem_wdata[23:16];
				if (mem_be[1]) vram[vram_idx][15:8]  <= mem_wdata[15:8];
				if (mem_be[0]) vram[vram_idx][7:0]   <= mem_wdata[7:0];
			end
		end
		endcase
	end
end

endmodule
