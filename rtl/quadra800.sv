//============================================================================
//  quadra800 — the Wombat machine: AP68040 on djMEMC's flat 32-bit bus.
//
//  Stage 1 (ROM executes): CPU + boot overlay + address decode.  RAM, ROM
//  and VRAM live on the platform beat port (BRAM/SDRAM on MiSTer, plain
//  arrays in the Verilator sim); everything unmapped takes a bus error,
//  which is what the ROM's probe code expects of empty space.
//
//  Physical map (MAME djmemc/iosb/macquadra800 as reference):
//    $00000000-$3FFFFFFF  RAM (installed size; beyond it: berr).  While the
//                         reset overlay holds, the low 4 MB reads ROM.
//    $40000000-$4FFFFFFF  ROM, 1 MB image mirrored; writes ignored; the
//                         first read here clears the overlay.
//    $50000000-$5FFFFFFF  IOSB I/O (stage 2+; only the ID reg lives here
//                         today: $5FFF0000-$5FFFFFFF = $A55A2BAD).
//    $F9000000-$F91FFFFF  DAFB VRAM (1 MB mirrored across the window).
//    $F9800000-$F98003FF  DAFB registers (stage 2).
//
//  Platform beat port: aligned longwords, be[3] = byte at addr+0 =
//  wdata[31:24]; req level-held per beat, accept on req && !your-own-ack,
//  answer with a single-cycle ack (rdata valid with it).  Writes with
//  memsel=ROM must be discarded but still acked.
//============================================================================

module quadra800
#(
	parameter RAM_ADDR_BITS = 27              // address space ceiling: 128 MB
)
(
	input         clk,
	input         nreset,
	input         ce,

	// 25.175 MHz dot clock for the DAFB scanout (rtl/pll_video.v)
	input         clk_vid,
	input         nreset_vid,

	// installed RAM, as a real Quadra 800 configuration.  The ROM sizes
	// memory by probing at startup, so this must be settled before reset
	// releases — the top folds a change into the reset.
	//   0 = 32 MB   1 = 64 MB   2 = 128 MB
	input   [1:0] ram_cfg,

	// platform memory beat port
	output reg        mem_req,
	output reg        mem_write,
	output reg [31:2] mem_addr,
	output reg  [3:0] mem_be,
	output reg [31:0] mem_wdata,
	output reg  [1:0] mem_memsel,             // 0 RAM, 1 ROM, 2 VRAM
	input      [31:0] mem_rdata,
	input             mem_ack,

	// video: DAFB scanout (VRAM fetch port + VGA)
	output     [21:2] vid_addr,
	input      [31:0] vid_rdata,
	output     [13:0] vid_stride,
	output      [7:0] VGA_R,
	output      [7:0] VGA_G,
	output      [7:0] VGA_B,
	output            VGA_HS,
	output            VGA_VS,
	output            VGA_HB,
	output            VGA_VB,
	output            CE_PIXEL,

	output signed [15:0] AUDIO_L,
	output signed [15:0] AUDIO_R,

	// SCSI disk block device
	input         img_mounted,
	input  [63:0] img_size,
	output [31:0] io_lba,
	output        io_rd,
	output        io_wr,
	input         io_ack,
	input   [7:0] sd_buff_addr,
	input  [15:0] sd_buff_dout,
	output [15:0] sd_buff_din,
	input         sd_buff_wr,

	// ADB input devices
	input  [10:0] ps2_key,
	input  [24:0] ps2_mouse,

	// Unix seconds from the HPS, for the RTC
	input  [32:0] timestamp,

	// SCC serial: channel A = modem port (MidiLink / PPP / MIDI),
	// channel B = printer port (LocalTalk on a real machine; TX only here)
	input         scc_rxd_a,
	output        scc_txd_a,
	input         scc_cts_a,
	output        scc_rts_a,
	input         scc_rxd_b,
	output        scc_txd_b,

	// debug
	output            dbg_berr,
	output     [31:0] dbg_berr_addr,
	output            dbg_overlay,
	output [255:0] debug_status,
	output [127:0] debug_status2,
	output        debug_fault,
	output        debug_halted
);

localparam [1:0] MSEL_RAM  = 2'd0,
                 MSEL_ROM  = 2'd1,
                 MSEL_VRAM = 2'd2;

//----------------------------------------------------------------------------
// CPU bundle and the transaction-to-beat adapter
//----------------------------------------------------------------------------
wire        bus_req, bus_write, bus_instr;
wire  [1:0] bus_size;
wire [31:0] bus_addr, bus_wdata;
wire  [2:0] bus_fc;
wire        bus_ack;
wire [31:0] bus_rdata;

wire        walker_req, walker_we;
wire [31:0] walker_addr, walker_wdat;
reg         walker_ack;
reg  [31:0] walker_data;
reg         walker_berr;

reg         cpu_berr;
wire  [2:0] ipl_n;

wombat_cpu cpu (
	.clk(clk),
	.nreset(nreset),
	.ce(ce),

	.ipl(ipl_n),
	.ipl_autovector(1'b1),
	.berr(cpu_berr),

	.bus_req(bus_req),
	.bus_write(bus_write),
	.bus_instr(bus_instr),
	.bus_size(bus_size),
	.bus_addr(bus_addr),
	.bus_wdata(bus_wdata),
	.bus_fc(bus_fc),
	.bus_ack(bus_ack),
	.bus_rdata(bus_rdata),

	.walker_req(walker_req),
	.walker_we(walker_we),
	.walker_addr(walker_addr),
	.walker_wdat(walker_wdat),
	.walker_ack(walker_ack),
	.walker_data(walker_data),
	.walker_berr(walker_berr),

	.snoop_stb(1'b0),
	.snoop_addr(32'd0),

	.nresetout(),
	.nmi_ack_toggle(),
	.cacr_out(),
	.vbr_out(),
	.debug_busy(),
	.debug_fault(debug_fault),
	.debug_halted(debug_halted),
	.debug_status(debug_status),
	.debug_status2(debug_status2)
);

wire        b_req, b_write;
wire [31:2] b_addr;
wire  [3:0] b_be;
wire [31:0] b_wdata;
reg         b_ack;
reg  [31:0] b_rdata;

wombat_bus32 bus32 (
	.clk(clk),
	.nreset(nreset),
	.ce(ce),

	.t_req(bus_req),
	.t_write(bus_write),
	.t_size(bus_size),
	.t_addr(bus_addr),
	.t_wdata(bus_wdata),
	.t_berr(cpu_berr),
	.t_ack(bus_ack),
	.t_rdata(bus_rdata),

	.b_req(b_req),
	.b_write(b_write),
	.b_addr(b_addr),
	.b_be(b_be),
	.b_wdata(b_wdata),
	.b_ack(b_ack),
	.b_rdata(b_rdata)
);

//----------------------------------------------------------------------------
// IOSB — VIA1/VIA2, config regs, ID; the 3-level interrupt encoder
//----------------------------------------------------------------------------
reg         iosb_sel;
reg         iosb_write;
reg  [27:2] iosb_addr;
reg   [3:0] iosb_be;
reg  [31:0] iosb_wdata;
wire [31:0] iosb_rdata;
wire        iosb_ack;
wire        iosb_fault;   // ack released a timed-out PDMA beat -> bus error

wire dafb_vbl;

iosb iosb (
	.clk(clk),
	.nreset(nreset),
	.ce(ce),

	.sel(iosb_sel),
	.write(iosb_write),
	.addr(iosb_addr),
	.be(iosb_be),
	.wdata(iosb_wdata),
	.rdata(iosb_rdata),
	.ack(iosb_ack),
	.sdma_fault(iosb_fault),

	.vbl_irq(dafb_vbl),
	.scsi_irq(1'b0),
	.scsi_drq(1'b0),
	.asc_irq(1'b0),

	.scc_rxd_a(scc_rxd_a),
	.scc_txd_a(scc_txd_a),
	.scc_cts_a(scc_cts_a),
	.scc_rts_a(scc_rts_a),
	.scc_rxd_b(scc_rxd_b),
	.scc_txd_b(scc_txd_b),

	.ipl_n(ipl_n),

	.audio_l(AUDIO_L),
	.audio_r(AUDIO_R),

	.img_mounted(img_mounted),
	.img_size(img_size),
	.io_lba(io_lba),
	.io_rd(io_rd),
	.io_wr(io_wr),
	.io_ack(io_ack),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din(sd_buff_din),
	.sd_buff_wr(sd_buff_wr),

	.ps2_key(ps2_key),
	.ps2_mouse(ps2_mouse),
	.timestamp(timestamp),

	// DEBUG: fault channel for the SCSI trace in iosb.sv
	.berr_active(svc == S_BERR),
	.berr_addr(svc_addr)
);

//----------------------------------------------------------------------------
// DAFB — registers at $F9800000, scanout from VRAM
//----------------------------------------------------------------------------
reg         dafb_sel;
reg         dafb_write;
reg   [9:2] dafb_addr;
reg  [31:0] dafb_wdata;
wire [31:0] dafb_rdata;
wire        dafb_ack;

dafb dafb (
	.clk_vid(clk_vid),
	.nreset_vid(nreset_vid),
	.clk(clk),
	.nreset(nreset),
	.ce(ce),

	.sel(dafb_sel),
	.write(dafb_write),
	.addr(dafb_addr),
	.wdata(dafb_wdata),
	.rdata(dafb_rdata),
	.ack(dafb_ack),

	.vbl_irq(dafb_vbl),

	.vid_addr(vid_addr),
	.vid_rdata(vid_rdata),
	.vid_stride(vid_stride),

	.vga_r(VGA_R),
	.vga_g(VGA_G),
	.vga_b(VGA_B),
	.vga_hs(VGA_HS),
	.vga_vs(VGA_VS),
	.vga_hb(VGA_HB),
	.vga_vb(VGA_VB),
	.ce_pixel(CE_PIXEL)
);

//----------------------------------------------------------------------------
// Beat service: arbitrate CPU vs table walker, decode, dispatch
//----------------------------------------------------------------------------
reg        overlay;

// Installed-RAM ceiling in LONGWORDS.  Anything at or above it decodes as
// open bus (never a bus error — see the note below), which is how the ROM's
// sizing loop discovers the top of memory.
// Powers of two only.  The djMEMC bank registers (iosb's djmemc_regs) are
// stored but not honoured by this decode, so RAM is one flat linear range —
// which matches what the ROM computes only for power-of-two totals.  A
// 48 MB option was tried and hangs the ROM in a 3-instruction loop at
// $408A022A: on real hardware 48 MB is two unequal banks, and sizing it
// needs the bank decode this stub does not implement.
// Powers of two only.  48 MB was hardcoded and RE-MEASURED on the SDRAM
// branch: the ROM still hangs in a 3-instruction loop at $408A0230 with
// d7=$11 and no bus error, exactly as it did on DDR3 — so the backing store
// is NOT what rejects it.  The cause is this decode: RAM is one flat linear
// range and the djMEMC bank registers (iosb's djmemc_regs) are stored but
// never acted on.  Before the ROM remaps them, djMEMC banks appear at fixed
// strides and are sized individually; a flat map only matches what the ROM
// computes when the total is a single power-of-two bank.  Making 48 MB (and
// 20/24/36/40/72) work means implementing that bank decode — worth doing,
// but it is a feature, not a constant.
wire [29:2] ram_limit = (ram_cfg == 2'd0) ? 28'h0800000 :   // 32 MB
                        (ram_cfg == 2'd1) ? 28'h1000000 :   // 64 MB
                                            28'h2000000;    // 128 MB

// decode of a beat address; the walker sees the same physical map.
// djMEMC acknowledges its whole DRAM window: probes beyond installed RAM
// read open-bus zeros, never a bus error — the ROM's RAM sizing treats a
// berr there as a fatal hardware fault (found the hard way; QEMU agrees).
function [2:0] decode;       // 0 ram,1 rom,2 vram,3 iosb,4 berr,5 dafb,6 open
	input [31:2] a;
	begin
		if (a[31:28] == 4'h4)              decode = 3'd1;
		else if (overlay && a[31:22] == 10'd0) decode = 3'd1;
		else if (a[31:30] == 2'b00)
			decode = (a[29:2] < ram_limit) ? 3'd0 : 3'd6;
		else if (a[31:21] == 11'b1111_1001_000) decode = 3'd2;  // $F900xxxx-$F91Fxxxx
		else if (a[31:10] == 22'b1111_1001_1000_0000_0000_00) decode = 3'd5;
		else if (a[31:28] == 4'h5)         decode = 3'd3;
		else                               decode = 3'd4;
	end
endfunction

localparam S_IDLE = 3'd0, S_MEM = 3'd1, S_IOSB = 3'd2, S_BERR = 3'd3,
           S_DAFB = 3'd4, S_OPEN = 3'd5;
reg  [2:0] svc;
reg        svc_walker;                        // owner of the beat in service
reg [31:2] svc_addr;

wire        walker_pend = walker_req && walker_armed;
reg         walker_armed;

assign dbg_berr      = (svc == S_BERR);
assign dbg_berr_addr = {svc_addr, 2'b00};
assign dbg_overlay   = overlay;

always @(posedge clk) begin
	if (!nreset) begin
		overlay      <= 1;
		svc          <= S_IDLE;
		svc_walker   <= 0;
		svc_addr     <= 0;
		walker_armed <= 1;
		walker_ack   <= 0;
		walker_data  <= 0;
		walker_berr  <= 0;
		b_ack        <= 0;
		b_rdata      <= 0;
		cpu_berr     <= 0;
		mem_req      <= 0;
		mem_write    <= 0;
		mem_addr     <= 0;
		mem_be       <= 0;
		mem_wdata    <= 0;
		mem_memsel   <= MSEL_RAM;
		iosb_sel     <= 0;
		iosb_write   <= 0;
		iosb_addr    <= 0;
		iosb_be      <= 0;
		iosb_wdata   <= 0;
		dafb_sel     <= 0;
		dafb_write   <= 0;
		dafb_addr    <= 0;
		dafb_wdata   <= 0;
	end
	else if (ce) begin
		walker_ack  <= 0;
		walker_berr <= 0;
		b_ack       <= 0;
		cpu_berr    <= 0;
		if (!walker_req) walker_armed <= 1;

		case (svc)
		S_IDLE: begin
			// walker first: it only runs mid-translation, never starves the
			// CPU.  !b_ack/!cpu_berr: the adapter needs a cycle to retire a
			// just-completed or just-faulted beat before b_req means "next".
			if (walker_pend || (b_req && !b_ack && !cpu_berr)) begin
				reg [31:2] a;
				reg        wr;
				a  = walker_pend ? walker_addr[31:2] : b_addr;
				wr = walker_pend ? walker_we : b_write;
				svc_walker <= walker_pend;
				if (walker_pend) walker_armed <= 0;
				svc_addr   <= a;
				// the ROM's own window read ends the boot overlay
				if (a[31:28] == 4'h4 && !wr) overlay <= 0;
				case (decode(a))
				3'd0, 3'd1, 3'd2: begin
					mem_req    <= 1;
					mem_write  <= wr;
					mem_addr   <= a;
					mem_be     <= walker_pend ? 4'b1111 : b_be;
					mem_wdata  <= walker_pend ? walker_wdat : b_wdata;
					mem_memsel <= decode(a) == 3'd0 ? MSEL_RAM :
					              decode(a) == 3'd1 ? MSEL_ROM : MSEL_VRAM;
					svc        <= S_MEM;
				end
				3'd3: begin
					iosb_sel   <= 1;
					iosb_write <= wr;
					iosb_addr  <= a[27:2];
					iosb_be    <= walker_pend ? 4'b1111 : b_be;
					iosb_wdata <= walker_pend ? walker_wdat : b_wdata;
					svc        <= S_IOSB;
				end
				3'd5: begin
					dafb_sel   <= 1;
					dafb_write <= wr;
					dafb_addr  <= a[9:2];
					dafb_wdata <= walker_pend ? walker_wdat : b_wdata;
					svc        <= S_DAFB;
				end
				3'd6: svc <= S_OPEN;
				default: svc <= S_BERR;
				endcase
			end
		end
		S_MEM: if (mem_ack) begin
			mem_req <= 0;
			if (svc_walker) begin
				walker_ack  <= 1;
				walker_data <= mem_rdata;
			end
			else begin
				b_ack   <= 1;
				b_rdata <= mem_rdata;
			end
			svc <= S_IDLE;
		end
		S_IOSB: if (iosb_ack) begin
			iosb_sel <= 0;
			// iosb_fault rides with the ack that releases a pseudo-DMA beat the
			// IOSB gave up on. Report it as a bus error rather than acking junk:
			// the ROM's blind PDMA path does unrolled move.l with no polling and
			// RELIES on a bus error (handler at $408D2606) to notice a failed
			// transfer. Acking zeros would silently corrupt the buffer instead.
			if (iosb_fault) begin
				if (svc_walker) walker_berr <= 1;
				else            cpu_berr    <= 1;
			end
			else if (svc_walker) begin
				walker_ack  <= 1;
				walker_data <= iosb_rdata;
			end
			else begin
				b_ack   <= 1;
				b_rdata <= iosb_rdata;
			end
			svc <= S_IDLE;
		end
		S_DAFB: if (dafb_ack) begin
			dafb_sel <= 0;
			if (svc_walker) begin
				walker_ack  <= 1;
				walker_data <= dafb_rdata;
			end
			else begin
				b_ack   <= 1;
				b_rdata <= dafb_rdata;
			end
			svc <= S_IDLE;
		end
		S_BERR: begin
			if (svc_walker) walker_berr <= 1;
			else            cpu_berr    <= 1;
			svc <= S_IDLE;
		end
		S_OPEN: begin
			if (svc_walker) begin
				walker_ack  <= 1;
				walker_data <= 32'd0;
			end
			else begin
				b_ack   <= 1;
				b_rdata <= 32'd0;
			end
			svc <= S_IDLE;
		end
		endcase
	end
end

endmodule
