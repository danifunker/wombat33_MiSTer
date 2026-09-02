//============================================================================
//  tb_ncr53c96 — directed unit test for rtl/ncr53c96.sv.
//
//  Two driver dialects talk to this chip and they are NOT the same:
//
//    * the Quadra 800 ROM — DMA-form selects ($C1/$C2) with TC preloaded
//      and an EMPTY FIFO, the CDB arriving afterwards as FIFO writes plus
//      a trailing PDMA byte.  This is what the model was shaped around and
//      what boots Mac OS today (docs/scsi/rom-driver-scsi-access-patterns.md).
//
//    * a real Unix 53C9x driver — NetBSD's ncr53c9x, and A/UX's, which is
//      the same driver family.  On mac68k NCR_F_DMASELECT is never set, so
//      every select is FIFO-PRELOADED: $41 SELNATN (CDB only), $42 SELATN
//      (IDENTIFY + CDB), $43 SELATNS (stop after IDENTIFY, for sync
//      negotiation), $46 SELATN3 (IDENTIFY + 2 tag bytes + CDB).  After the
//      select interrupt it reads STAT, then STEP, then INTR last, and
//      demands FC|BS together with a sequence step of 0..4
//      (docs/scsi/netbsd-ncr53c9x-expectations.md section 2).
//
//  Both dialects are exercised here so that widening the model for the
//  second cannot silently break the first.  Runs in seconds and needs no
//  ROM and no disk image — the backing store is a tiny synthetic disk.
//
//    make tb_ncr53c96 && ./obj_dir_tb/tb_ncr53c96
//============================================================================
`timescale 1ns/1ps

module tb_ncr53c96;

localparam [3:0] R_TCL = 4'h0, R_TCM = 4'h1, R_FIFO = 4'h2, R_CMD = 4'h3,
                 R_STAT = 4'h4, R_SELID = 4'h4, R_INTR = 4'h5, R_STEP = 4'h6,
                 R_FFLAG = 4'h7, R_CFG1 = 4'h8;

// interrupt status bits (as the driver names them)
localparam [7:0] I_SEL = 8'h01, I_SELATN = 8'h02, I_RESEL = 8'h04,
                 I_FC = 8'h08, I_BUS = 8'h10, I_DISC = 8'h20, I_ILL = 8'h40,
                 I_RST = 8'h80;

localparam [2:0] PH_DOUT = 3'd0, PH_DIN = 3'd1, PH_CMD = 3'd2, PH_STAT = 3'd3,
                 PH_MOUT = 3'd6, PH_MIN = 3'd7;

//----------------------------------------------------------------------------
// DUT
//----------------------------------------------------------------------------
reg         clk = 0;
reg         nreset = 0;
reg         ce = 1;

reg         sel = 0, write = 0;
reg   [3:0] rs = 0;
reg   [7:0] wdata = 0;
wire  [7:0] rdata;

reg         dma_rd = 0, dma_wr = 0;
reg   [7:0] dma_wdata = 0;
wire  [7:0] dma_rdata;
wire        dma_valid, drq, irq;

reg         img_mounted = 0;
reg  [63:0] img_size = 0;
wire [31:0] io_lba;
wire        io_rd, io_wr;
reg         io_ack = 0;
reg   [7:0] sd_buff_addr = 0;
reg  [15:0] sd_buff_dout = 0;
wire [15:0] sd_buff_din;
reg         sd_buff_wr = 0;

always #5 clk = ~clk;

ncr53c96 #(.DISK_ID(0)) dut (
	.clk(clk), .nreset(nreset), .ce(ce),
	.sel(sel), .write(write), .rs(rs), .wdata(wdata), .rdata(rdata),
	.dma_rd(dma_rd), .dma_wr(dma_wr), .dma_wdata(dma_wdata),
	.dma_rdata(dma_rdata), .dma_valid(dma_valid), .drq(drq), .irq(irq),
	.img_mounted(img_mounted), .img_size(img_size),
	.io_lba(io_lba), .io_rd(io_rd), .io_wr(io_wr), .io_ack(io_ack),
	.sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout),
	.sd_buff_din(sd_buff_din), .sd_buff_wr(sd_buff_wr)
);

//----------------------------------------------------------------------------
// synthetic block device — 64 blocks, byte b of block n = n*7 + b (mod 256).
// Mirrors verilator/sim/sim_blkdevice.cpp: ack rises after a latency, words
// stream in on sd_buff_wr while ack is high, ack falls when the block is done.
// Sim packing is BIG-endian (disk byte 0 in [15:8]), same as that model.
//----------------------------------------------------------------------------
localparam NBLK = 64;
reg [7:0] disk [0:NBLK*512-1];

integer d_state = 0, d_lat = 0, d_i = 0, d_lba = 0;
integer wr_blocks = 0;                       // blocks the device has accepted

always @(posedge clk) begin
	sd_buff_wr <= 0;
	case (d_state)
	0: begin
		if (io_rd || io_wr) begin
			d_lba   <= io_lba;
			d_lat   <= 40;                   // short but non-zero round trip
			d_state <= io_rd ? 1 : 3;
		end
	end
	// ---- read: hold ack high while the 256 words stream in
	1: begin
		if (d_lat != 0) d_lat <= d_lat - 1;
		else begin io_ack <= 1; d_i <= 0; d_state <= 2; end
	end
	2: begin
		if (d_i < 256) begin
			sd_buff_addr <= d_i[7:0];
			sd_buff_dout <= {disk[d_lba*512 + d_i*2], disk[d_lba*512 + d_i*2 + 1]};
			sd_buff_wr   <= 1;
			d_i          <= d_i + 1;
		end
		else begin io_ack <= 0; d_state <= 0; end
	end
	// ---- write: same handshake, sampling sd_buff_din.  sbuf's port S read
	// (q_s) is REGISTERED, so sd_buff_din this cycle reflects the address
	// driven LAST cycle.  Drive addr = d_i and capture the word for d_i-1;
	// advancing the address AND capturing on the same index (as a naive
	// model does) reads every word one slot stale -- a 1-word (2-byte)
	// offset that looks like an RTL write bug but is purely a model latency
	// error.  The real platform (hps_io) and sim_blkdevice.cpp both let the
	// address settle before sampling, exactly like this.
	3: begin
		if (d_lat != 0) d_lat <= d_lat - 1;
		else begin io_ack <= 1; d_i <= 0; d_state <= 4; end
	end
	4: begin
		// TWO-cycle round trip: the tb's sd_buff_addr register delays the
		// address one cycle, and sbuf's q_s read register delays the data a
		// second, so sd_buff_din reflects the address driven TWO cycles ago.
		if (d_i >= 2 && d_i < 258) begin
			disk[d_lba*512 + (d_i-2)*2]     <= sd_buff_din[15:8];
			disk[d_lba*512 + (d_i-2)*2 + 1] <= sd_buff_din[7:0];
		end
		if (d_i < 258) begin
			if (d_i < 256) sd_buff_addr <= d_i[7:0];
			d_i <= d_i + 1;
		end
		else begin io_ack <= 0; wr_blocks <= wr_blocks + 1; d_state <= 0; end
	end
	endcase
end

//----------------------------------------------------------------------------
// bus tasks
//----------------------------------------------------------------------------
integer fails = 0, checks = 0;

task expect8(input [8*24:1] what, input [7:0] got, input [7:0] want);
	begin
		checks = checks + 1;
		if (got !== want) begin
			fails = fails + 1;
			$display("  FAIL %0s: got %02X want %02X", what, got, want);
		end
	end
endtask

task expect_bits(input [8*24:1] what, input [7:0] got, input [7:0] mask);
	begin
		checks = checks + 1;
		if ((got & mask) !== mask) begin
			fails = fails + 1;
			$display("  FAIL %0s: got %02X, missing bits %02X", what, got, mask & ~got);
		end
	end
endtask

task reg_wr(input [3:0] r, input [7:0] d);
	begin
		@(negedge clk); sel = 1; write = 1; rs = r; wdata = d;
		@(negedge clk); sel = 0; write = 0;
	end
endtask

task reg_rd(input [3:0] r, output [7:0] d);
	begin
		@(negedge clk); sel = 1; write = 0; rs = r;
		#1 d = rdata;
		@(negedge clk); sel = 0;
	end
endtask

// peek without asserting sel, so polling loops consume nothing
task reg_peek(input [3:0] r, output [7:0] d);
	begin
		@(negedge clk); rs = r; #1 d = rdata;
	end
endtask

task pdma_wr(input [7:0] b);
	integer g;
	begin
		g = 0;
		@(negedge clk); dma_wr = 1; dma_wdata = b;
		@(negedge clk);
		while (!dma_valid && g < 2000) begin @(negedge clk); g = g + 1; end
		if (!dma_valid) begin
			fails = fails + 1;
			$display("  FAIL pdma_wr(%02X) never acked", b);
		end
		dma_wr = 0;
	end
endtask

task pdma_rd(output [7:0] b);
	integer g;
	begin
		g = 0;
		@(negedge clk); dma_rd = 1;
		@(negedge clk);
		while (!dma_valid && g < 2000) begin @(negedge clk); g = g + 1; end
		if (!dma_valid) begin
			fails = fails + 1;
			$display("  FAIL pdma_rd never acked");
		end
		b = dma_rdata;
		dma_rd = 0;
	end
endtask

// wait for the chip to raise INT; ok = 0 on timeout
task wait_irq(input integer limit, output integer ok);
	integer g;
	begin
		g = 0;
		while (!irq && g < limit) begin @(negedge clk); g = g + 1; end
		ok = irq ? 1 : 0;
		if (!ok) begin
			fails = fails + 1;
			$display("  FAIL no interrupt within %0d cycles", limit);
		end
	end
endtask

// the driver's read order: STAT, STEP, then INTR last (section 2.2)
task read_regs(output [7:0] st_o, output [7:0] sp_o, output [7:0] it_o);
	begin
		reg_rd(R_STAT, st_o);
		reg_rd(R_STEP, sp_o);
		reg_rd(R_INTR, it_o);
	end
endtask

task set_tc(input [15:0] n);
	begin
		reg_wr(R_TCL, n[7:0]);
		reg_wr(R_TCM, n[15:8]);
	end
endtask

//----------------------------------------------------------------------------
// stimulus
//----------------------------------------------------------------------------
reg [7:0] st, sp, it, ff, b;
integer ok, k, guard;
reg [7:0] cdb [0:11];

// ---- ROM dialect: DMA select, then CDB via FIFO writes + a trailing PDMA
// byte.  `n` = CDB length.  Leaves the chip at the command's data/status phase.
task rom_command(input integer n);
	integer j;
	begin
		reg_wr(R_SELID, 8'h00);
		reg_wr(R_CMD, 8'h01);                  // flush FIFO
		set_tc(16'd1);
		reg_wr(R_CMD, 8'hC1);                  // DMA select w/o ATN
		reg_wr(R_CMD, 8'h01);                  // SCSICmd: flush
		set_tc(16'd1);
		reg_wr(R_CMD, 8'h90);                  // DMA transfer info in CMD phase
		for (j = 0; j < n-1; j = j + 1) reg_wr(R_FIFO, cdb[j]);
		pdma_wr(cdb[n-1]);                     // last byte retires TC
	end
endtask

// ---- Unix dialect: preload the FIFO, then one of the four select forms.
task unix_select(input [7:0] selcmd, input integer n, input integer identify);
	integer j;
	begin
		reg_wr(R_SELID, 8'h00);
		reg_wr(R_CMD, 8'h01);                  // flush
		if (identify) reg_wr(R_FIFO, 8'h80);   // IDENTIFY, LUN 0, no disconnect
		for (j = 0; j < n; j = j + 1) reg_wr(R_FIFO, cdb[j]);
		reg_wr(R_CMD, selcmd);
	end
endtask

integer blk, byi;

initial begin
	for (blk = 0; blk < NBLK; blk = blk + 1)
		for (byi = 0; byi < 512; byi = byi + 1)
			disk[blk*512 + byi] = (blk*7 + byi) & 8'hFF;

	$display("== tb_ncr53c96 ==");
	repeat (4) @(negedge clk);
	nreset = 1;
	repeat (4) @(negedge clk);

	// mount: 64 blocks of 512 bytes
	img_size = 64*512;
	img_mounted = 1; @(negedge clk); @(negedge clk); img_mounted = 0;
	repeat (4) @(negedge clk);

	reg_wr(R_CMD, 8'h02);                      // chip reset
	repeat (4) @(negedge clk);

	//------------------------------------------------------------------
	$display("-- T1  ROM dialect: TEST UNIT READY");
	//------------------------------------------------------------------
	cdb[0]=8'h00; cdb[1]=0; cdb[2]=0; cdb[3]=0; cdb[4]=0; cdb[5]=0;
	rom_command(6);
	wait_irq(500, ok);
	read_regs(st, sp, it);
	expect_bits("T1 intr BS|FC", it, I_BUS | I_FC);
	expect8("T1 phase STATUS", {5'd0, st[2:0]}, {5'd0, PH_STAT});
	reg_wr(R_CMD, 8'h11);                      // ICCS
	wait_irq(500, ok);
	read_regs(st, sp, it);
	expect_bits("T1 iccs FC", it, I_FC);
	reg_rd(R_FIFO, b); expect8("T1 status GOOD", b, 8'h00);
	reg_rd(R_FIFO, b); expect8("T1 msg CMDCOMP", b, 8'h00);
	reg_wr(R_CMD, 8'h12);                      // message accept
	wait_irq(500, ok);
	read_regs(st, sp, it);
	expect_bits("T1 disconnect", it, I_DISC);

	//------------------------------------------------------------------
	$display("-- T2  ROM dialect: READ(6) block 3, first 16 bytes");
	//------------------------------------------------------------------
	cdb[0]=8'h08; cdb[1]=8'h00; cdb[2]=8'h00; cdb[3]=8'h03; cdb[4]=8'h01; cdb[5]=8'h00;
	rom_command(6);
	wait_irq(500, ok);
	read_regs(st, sp, it);
	expect_bits("T2 intr BS|FC", it, I_BUS | I_FC);
	expect8("T2 phase DATA IN", {5'd0, st[2:0]}, {5'd0, PH_DIN});
	// the ROM's 16-byte burst: TC=16, $90, gate on TC0 + FIFO>=16, drain
	set_tc(16'd16);
	reg_wr(R_CMD, 8'h90);
	guard = 0;
	reg_peek(R_STAT, st);
	reg_peek(R_FFLAG, ff);
	while (!(st[4] && ff[4]) && guard < 100000) begin
		@(negedge clk);
		reg_peek(R_STAT, st);
		reg_peek(R_FFLAG, ff);
		guard = guard + 1;
	end
	if (guard >= 100000) begin
		fails = fails + 1;
		$display("  FAIL T2 burst never gated (stat=%02X fflag=%02X)", st, ff);
	end
	for (k = 0; k < 16; k = k + 1) begin
		pdma_rd(b);
		expect8("T2 data", b, (3*7 + k) & 8'hFF);
	end
	wait_irq(500, ok);
	read_regs(st, sp, it);
	expect_bits("T2 burst done BS", it, I_BUS);

	//------------------------------------------------------------------
	$display("-- T3  Unix dialect: $42 SELATN, FIFO-preloaded IDENTIFY+CDB");
	//------------------------------------------------------------------
	reg_wr(R_CMD, 8'h02); repeat (4) @(negedge clk);   // chip reset between cases
	cdb[0]=8'h00; cdb[1]=0; cdb[2]=0; cdb[3]=0; cdb[4]=0; cdb[5]=0;
	unix_select(8'h42, 6, 1);
	wait_irq(500, ok);
	read_regs(st, sp, it);
	$display("   T3 stat=%02X step=%02X intr=%02X", st, sp, it);
	expect_bits("T3 intr BS|FC", it, I_BUS | I_FC);
	expect8("T3 step 4", sp & 8'h07, 8'd4);
	expect8("T3 phase STATUS", {5'd0, st[2:0]}, {5'd0, PH_STAT});
	reg_rd(R_FFLAG, ff);
	expect8("T3 FIFO drained", ff & 8'h1F, 8'd0);

	//------------------------------------------------------------------
	$display("-- T4  Unix dialect: $41 SELNATN (REQUEST SENSE, no IDENTIFY)");
	//------------------------------------------------------------------
	reg_wr(R_CMD, 8'h02); repeat (4) @(negedge clk);
	cdb[0]=8'h03; cdb[1]=0; cdb[2]=0; cdb[3]=0; cdb[4]=8'h12; cdb[5]=0;
	unix_select(8'h41, 6, 0);
	wait_irq(500, ok);
	read_regs(st, sp, it);
	$display("   T4 stat=%02X step=%02X intr=%02X", st, sp, it);
	expect_bits("T4 intr BS|FC", it, I_BUS | I_FC);
	expect8("T4 step 4", sp & 8'h07, 8'd4);
	expect8("T4 phase DATA IN", {5'd0, st[2:0]}, {5'd0, PH_DIN});

	//------------------------------------------------------------------
	$display("-- T5  Unix dialect: $43 SELATNS (stop after IDENTIFY)");
	//------------------------------------------------------------------
	reg_wr(R_CMD, 8'h02); repeat (4) @(negedge clk);
	cdb[0]=8'h00; cdb[1]=0; cdb[2]=0; cdb[3]=0; cdb[4]=0; cdb[5]=0;
	unix_select(8'h43, 6, 1);
	wait_irq(500, ok);
	read_regs(st, sp, it);
	$display("   T5 stat=%02X step=%02X intr=%02X", st, sp, it);
	expect_bits("T5 intr BS|FC", it, I_BUS | I_FC);
	expect8("T5 step 1", sp & 8'h07, 8'd1);
	expect8("T5 phase MESSAGE OUT", {5'd0, st[2:0]}, {5'd0, PH_MOUT});
	checks = checks + 1;
	if (it & I_ILL) begin
		fails = fails + 1;
		$display("  FAIL T5 chip reported ILLEGAL COMMAND for $43 SELATNS");
	end

	//------------------------------------------------------------------
	$display("-- T5b negotiation: SDTR out, MESSAGE REJECT in, then the CDB");
	//------------------------------------------------------------------
	// The driver flushes the CDB it had preloaded behind the IDENTIFY,
	// builds the SDTR message, and transfers it with a non-DMA TI.
	reg_rd(R_FFLAG, ff);
	$display("   T5b FIFO after $43 holds %0d byte(s) (the un-sent CDB)", ff & 8'h1F);
	reg_wr(R_CMD, 8'h01);                      // flush
	reg_wr(R_FIFO, 8'h01);                     // EXTENDED MESSAGE
	reg_wr(R_FIFO, 8'h03);                     // length 3
	reg_wr(R_FIFO, 8'h01);                     // SDTR
	reg_wr(R_FIFO, 8'd25);                     // transfer period
	reg_wr(R_FIFO, 8'd15);                     // REQ/ACK offset
	reg_wr(R_CMD, 8'h10);                      // TRANS, no DMA bit
	wait_irq(500, ok);
	read_regs(st, sp, it);
	$display("   T5b msgout stat=%02X step=%02X intr=%02X", st, sp, it);
	expect_bits("T5b msgout BS", it, I_BUS);
	expect8("T5b phase MESSAGE IN", {5'd0, st[2:0]}, {5'd0, PH_MIN});
	// message in, one byte per TI, completing with FC
	reg_wr(R_CMD, 8'h01);
	reg_wr(R_CMD, 8'h10);
	wait_irq(500, ok);
	read_regs(st, sp, it);
	expect_bits("T5b msgin FC", it, I_FC);
	reg_rd(R_FFLAG, ff);
	expect8("T5b one message byte", ff & 8'h1F, 8'd1);
	reg_rd(R_FIFO, b);
	expect8("T5b MESSAGE REJECT", b, 8'h07);
	// MSGOK must NOT disconnect here — the target is still connected and
	// wants the command it was selected for.
	reg_wr(R_CMD, 8'h12);
	wait_irq(500, ok);
	read_regs(st, sp, it);
	$display("   T5b msgok  stat=%02X step=%02X intr=%02X", st, sp, it);
	checks = checks + 1;
	if (it & I_DISC) begin
		fails = fails + 1;
		$display("  FAIL T5b MSGOK after a rejected negotiation disconnected the bus");
	end
	expect8("T5b phase COMMAND", {5'd0, st[2:0]}, {5'd0, PH_CMD});
	// now the CDB, from COMMAND phase
	cdb[0]=8'h08; cdb[1]=8'h00; cdb[2]=8'h00; cdb[3]=8'h05; cdb[4]=8'h01; cdb[5]=8'h00;
	for (k = 0; k < 6; k = k + 1) reg_wr(R_FIFO, cdb[k]);
	reg_wr(R_CMD, 8'h10);
	wait_irq(500, ok);
	read_regs(st, sp, it);
	$display("   T5b cmd    stat=%02X step=%02X intr=%02X", st, sp, it);
	expect_bits("T5b cmd BS|FC", it, I_BUS | I_FC);
	expect8("T5b phase DATA IN", {5'd0, st[2:0]}, {5'd0, PH_DIN});
	// and the data really is block 5
	set_tc(16'd16);
	reg_wr(R_CMD, 8'h90);
	guard = 0;
	reg_peek(R_STAT, st);
	reg_peek(R_FFLAG, ff);
	while (!(st[4] && ff[4]) && guard < 100000) begin
		@(negedge clk);
		reg_peek(R_STAT, st);
		reg_peek(R_FFLAG, ff);
		guard = guard + 1;
	end
	if (guard >= 100000) begin
		fails = fails + 1;
		$display("  FAIL T5b burst never gated (stat=%02X fflag=%02X)", st, ff);
	end
	for (k = 0; k < 16; k = k + 1) begin
		pdma_rd(b);
		expect8("T5b data", b, (5*7 + k) & 8'hFF);
	end

	//------------------------------------------------------------------
	$display("-- T6  Unix dialect: $46 SELATN3 (IDENTIFY + 2 tag bytes + CDB)");
	//------------------------------------------------------------------
	reg_wr(R_CMD, 8'h02); repeat (4) @(negedge clk);
	cdb[0]=8'h00; cdb[1]=0; cdb[2]=0; cdb[3]=0; cdb[4]=0; cdb[5]=0;
	reg_wr(R_SELID, 8'h00);
	reg_wr(R_CMD, 8'h01);
	reg_wr(R_FIFO, 8'hC0);                     // IDENTIFY w/ disconnect
	reg_wr(R_FIFO, 8'h20);                     // SIMPLE QUEUE TAG
	reg_wr(R_FIFO, 8'h05);                     // tag number
	for (k = 0; k < 6; k = k + 1) reg_wr(R_FIFO, cdb[k]);
	reg_wr(R_CMD, 8'h46);
	wait_irq(500, ok);
	read_regs(st, sp, it);
	$display("   T6 stat=%02X step=%02X intr=%02X", st, sp, it);
	expect_bits("T6 intr BS|FC", it, I_BUS | I_FC);
	expect8("T6 step 4", sp & 8'h07, 8'd4);
	expect8("T6 phase STATUS", {5'd0, st[2:0]}, {5'd0, PH_STAT});
	checks = checks + 1;
	if (it & I_ILL) begin
		fails = fails + 1;
		$display("  FAIL T6 chip reported ILLEGAL COMMAND for $46 SELATN3");
	end

	//------------------------------------------------------------------
	$display("-- T7  selection timeout on an empty target");
	//------------------------------------------------------------------
	reg_wr(R_CMD, 8'h02); repeat (4) @(negedge clk);
	reg_wr(R_SELID, 8'h03);
	reg_wr(R_CMD, 8'h01);
	reg_wr(R_FIFO, 8'h80);
	for (k = 0; k < 6; k = k + 1) reg_wr(R_FIFO, 8'h00);
	reg_wr(R_CMD, 8'h42);
	wait_irq(500, ok);
	read_regs(st, sp, it);
	reg_rd(R_FFLAG, ff);
	$display("   T7 stat=%02X step=%02X intr=%02X fflag=%02X", st, sp, it, ff);
	expect_bits("T7 selection timeout DISC", it, I_DISC);
	expect8("T7 step 0", sp & 8'h07, 8'd0);
	// The preloaded bytes must still be countable.  A/UX's c94 driver
	// compares FIFO-flags & $1F against the 7 bytes it pushed to tell
	// "nobody answered" (benign) from "the target vanished mid-command"
	// (fatal protocol error).  Flushing here reports the fatal one for
	// every empty SCSI ID.
	expect8("T7 FIFO still holds IDENTIFY+CDB", ff & 8'h1F, 8'd7);

	//------------------------------------------------------------------
	$display("-- T8  after a timeout the chip still selects the real target");
	//------------------------------------------------------------------
	reg_wr(R_CMD, 8'h01);                      // driver flushes, as it does
	cdb[0]=8'h12; cdb[1]=0; cdb[2]=0; cdb[3]=0; cdb[4]=8'h24; cdb[5]=0;
	unix_select(8'h42, 6, 1);
	wait_irq(500, ok);
	read_regs(st, sp, it);
	$display("   T8 stat=%02X step=%02X intr=%02X", st, sp, it);
	expect_bits("T8 intr BS|FC", it, I_BUS | I_FC);
	checks = checks + 1;
	if (it & (I_DISC | I_RESEL)) begin
		fails = fails + 1;
		$display("  FAIL T8 stale DISC/RESEL survived into the next select");
	end
	expect8("T8 step 4", sp & 8'h07, 8'd4);
	expect8("T8 phase DATA IN", {5'd0, st[2:0]}, {5'd0, PH_DIN});

	//------------------------------------------------------------------
	$display("-- T9  A/UX 3.1 c94 driver, verbatim register sequence");
	//------------------------------------------------------------------
	// Transcribed from the shipped kernel (docs/scsi/aux-c94-driver.md).
	// Every check below is a branch the driver actually takes; failing any
	// of them lands in $1004fd88, which defaults req->ret to 8 =
	// "Protocol Error Processing SCSI request".
	reg_wr(R_CMD, 8'h02); repeat (4) @(negedge clk);

	//   scsiselect: $01, FIFO <- $C0 + CDB, SELID, $42
	reg_wr(R_CMD, 8'h01);
	reg_wr(R_FIFO, 8'hC0);                     // IDENTIFY, disconnect OK
	cdb[0]=8'h08; cdb[1]=8'h00; cdb[2]=8'h00; cdb[3]=8'h00; cdb[4]=8'h01; cdb[5]=8'h00;
	for (k = 0; k < 6; k = k + 1) reg_wr(R_FIFO, cdb[k]);
	reg_wr(R_SELID, 8'h00);
	reg_wr(R_CMD, 8'h42);

	//   the select-completion handler ($1004fb4e)
	wait_irq(500, ok);
	read_regs(st, sp, it);
	$display("   T9 select : stat=%02X step=%02X intr=%02X", st, sp, it);
	checks = checks + 1;
	if (it & I_RESEL) begin
		fails = fails + 1; $display("  FAIL T9 RESEL set at select - driver backs off");
	end
	checks = checks + 1;
	if (it & I_DISC) begin
		fails = fails + 1; $display("  FAIL T9 DISC set at select - driver reports a select failure");
	end
	expect8("T9 intr is exactly BS|FC", it & 8'h18, 8'h18);
	//   dophase: COMMAND (2), 4 and 5 are hard errors
	checks = checks + 1;
	if (st[2:0] == PH_CMD || st[2:0] == 3'd4 || st[2:0] == 3'd5) begin
		fails = fails + 1;
		$display("  FAIL T9 dophase rejects phase %0d", st[2:0]);
	end
	expect8("T9 phase DATA IN", {5'd0, st[2:0]}, {5'd0, PH_DIN});

	//   scsidma: TC=256 (TCM written FIRST), $90, then DREQ-paced move.w
	for (blk = 0; blk < 2; blk = blk + 1) begin
		reg_wr(R_TCM, 8'h01);
		reg_wr(R_TCL, 8'h00);
		reg_wr(R_CMD, 8'h90);
		for (k = 0; k < 128; k = k + 1) begin
			guard = 0;
			while (!drq && guard < 100000) begin @(negedge clk); guard = guard + 1; end
			if (guard >= 100000) begin
				fails = fails + 1;
				$display("  FAIL T9 DREQ never asserted, chunk %0d word %0d", blk, k);
				k = 128;
			end
			else begin
				pdma_rd(b);
				if (blk == 0 && k == 0) expect8("T9 first data byte", b, 8'h00);
				pdma_rd(b);
			end
		end
		wait_irq(2000, ok);
		read_regs(st, sp, it);
		$display("   T9 chunk%0d: stat=%02X step=%02X intr=%02X", blk, st, sp, it);
		expect_bits("T9 chunk BS", it, I_BUS);
	end
	$display("   T9 after data: phase=%0d", st[2:0]);
	expect8("T9 phase STATUS after 512 bytes", {5'd0, st[2:0]}, {5'd0, PH_STAT});

	//   status phase: $11 ICCS.  The handler at $1004ec36 FAILS on BS and
	//   only succeeds on FC — raising BS|FC here would break A/UX.
	reg_wr(R_CMD, 8'h11);
	wait_irq(500, ok);
	read_regs(st, sp, it);
	$display("   T9 iccs   : stat=%02X step=%02X intr=%02X", st, sp, it);
	checks = checks + 1;
	if (it & I_BUS) begin
		fails = fails + 1;
		$display("  FAIL T9 ICCS raised BS - A/UX treats that as a failure");
	end
	expect_bits("T9 iccs FC", it, I_FC);
	reg_rd(R_FIFO, b); expect8("T9 status byte", b, 8'h00);
	reg_rd(R_FIFO, b); expect8("T9 message byte", b, 8'h00);
	//   the driver then reads the FIFO ONE MORE TIME (tst.b) and asserts
	//   ATN if it is non-zero — which would send it looking for MESSAGE OUT
	reg_rd(R_FIFO, b);
	expect8("T9 third FIFO read is 0 (no spurious SET ATN)", b, 8'h00);
	reg_wr(R_CMD, 8'h12);
	wait_irq(500, ok);
	read_regs(st, sp, it);
	$display("   T9 msgok  : stat=%02X step=%02X intr=%02X", st, sp, it);
	expect_bits("T9 disconnect", it, I_DISC);

	//------------------------------------------------------------------
	$display("-- T10 ROM SCSI Manager: bulk READ(6) as 16-byte $90 chunks");
	//------------------------------------------------------------------
	// This is what A/UX Startup's saio ACTUALLY does, transcribed from
	// qemu-system-m68k master booting this exact ROM+disk: the ROM's
	// original-API SCSIRead reads a block as a run of TC=16 $90 chunks, each
	// drained FULLY on DRQ (lower_drq at fifo<2) and only THEN a BS
	// interrupt (reg[4]=0x91, phase still DATA IN).  The completion never
	// arrives with data in the FIFO; the LAST chunk drains, then flips to
	// STATUS.  Earlier this test asserted the opposite (16 bytes left in the
	// FIFO at completion) -- that scenario does not occur, and modelling it
	// dropped DREQ and produced the flashing-"?" regression.  512 bytes = 32
	// chunks of 16.
	reg_wr(R_CMD, 8'h02); repeat (4) @(negedge clk);
	cdb[0]=8'h08; cdb[1]=8'h00; cdb[2]=8'h00; cdb[3]=8'h05; cdb[4]=8'h01; cdb[5]=8'h00;
	rom_command(6);
	wait_irq(500, ok);
	read_regs(st, sp, it);
	expect_bits("T10 intr BS|FC", it, I_BUS | I_FC);
	expect8("T10 phase DATA IN", {5'd0, st[2:0]}, {5'd0, PH_DIN});
	for (blk = 0; blk < 32; blk = blk + 1) begin
		set_tc(16'd16);
		reg_wr(R_CMD, 8'h90);
		// ROM bulk gate: poll STATUS.TC0 + FIFO-flags bit 4, then drain 16
		guard = 0;
		reg_peek(R_STAT, st);
		reg_peek(R_FFLAG, ff);
		while (!(st[4] && ff[4]) && guard < 100000) begin
			@(negedge clk);
			reg_peek(R_STAT, st);
			reg_peek(R_FFLAG, ff);
			guard = guard + 1;
		end
		if (guard >= 100000) begin
			fails = fails + 1;
			$display("  FAIL T10 chunk %0d never gated (stat=%02X fflag=%02X)", blk, st, ff);
		end
		// DREQ must be up with a full chunk waiting, and stay up through it
		checks = checks + 1;
		if (!drq) begin
			fails = fails + 1;
			$display("  FAIL T10 DREQ down with chunk %0d in the FIFO", blk);
		end
		for (k = 0; k < 16; k = k + 1) begin
			pdma_rd(b);
			expect8("T10 data", b, (5*7 + blk*16 + k) & 8'hFF);
		end
		wait_irq(2000, ok);
		checks = checks + 1;
		if (!ok) begin
			fails = fails + 1;
			$display("  FAIL T10 chunk %0d never completed", blk);
		end
		read_regs(st, sp, it);
		reg_peek(R_FFLAG, ff);
		expect_bits("T10 chunk BS", it, I_BUS);
		// the completion always arrives with the FIFO already drained
		expect8("T10 FIFO empty at completion", ff & 8'h1F, 8'd0);
		if (blk < 31)
			expect8("T10 mid chunk still DATA IN", {5'd0, st[2:0]}, {5'd0, PH_DIN});
		else
			expect8("T10 last chunk flips to STATUS", {5'd0, st[2:0]}, {5'd0, PH_STAT});
	end
	reg_wr(R_CMD, 8'h11);
	wait_irq(500, ok);
	read_regs(st, sp, it);
	expect_bits("T10 iccs FC", it, I_FC);
	reg_rd(R_FIFO, b); expect8("T10 status GOOD", b, 8'h00);
	reg_rd(R_FIFO, b); expect8("T10 msg CMDCOMP", b, 8'h00);
	reg_wr(R_CMD, 8'h12);
	wait_irq(500, ok);
	read_regs(st, sp, it);
	expect_bits("T10 disconnect", it, I_DISC);

	//------------------------------------------------------------------
	$display("-- T11 ROM polled read: per-byte $10, phase flips ON the last byte");
	//------------------------------------------------------------------
	// Original-API SCSIRead (non-blind): one non-DMA TI per byte, INTR
	// checked as (INTR & $30) == $10 each time, byte loop ends by count,
	// then SCSIComplete polls for the phase change.  The last byte must
	// therefore arrive with phase ALREADY showing STATUS (QEMU leaves the
	// last byte in the FIFO for exactly this reason).
	reg_wr(R_CMD, 8'h02); repeat (4) @(negedge clk);
	cdb[0]=8'h12; cdb[1]=8'h00; cdb[2]=8'h00; cdb[3]=8'h00; cdb[4]=8'h24; cdb[5]=8'h00;
	rom_command(6);
	wait_irq(500, ok);
	read_regs(st, sp, it);
	expect_bits("T11 intr BS|FC", it, I_BUS | I_FC);
	expect8("T11 phase DATA IN", {5'd0, st[2:0]}, {5'd0, PH_DIN});
	for (k = 0; k < 36; k = k + 1) begin
		reg_wr(R_CMD, 8'h10);
		wait_irq(2000, ok);
		checks = checks + 1;
		if (!ok) begin
			fails = fails + 1;
			$display("  FAIL T11 no interrupt for byte %0d", k);
		end
		read_regs(st, sp, it);
		expect8("T11 INTR&$30 is BS", it & 8'h30, 8'h10);
		if (k < 35)
			expect8("T11 mid byte DATA IN", {5'd0, st[2:0]}, {5'd0, PH_DIN});
		else begin
			expect8("T11 last byte: STATUS", {5'd0, st[2:0]}, {5'd0, PH_STAT});
			reg_peek(R_FFLAG, ff);
			expect8("T11 last byte in FIFO", ff & 8'h1F, 8'd1);
		end
		reg_rd(R_FIFO, b);
		if (k == 0) expect8("T11 inquiry byte 0", b, 8'h00);
	end
	reg_wr(R_CMD, 8'h11);
	wait_irq(500, ok);
	read_regs(st, sp, it);
	expect_bits("T11 iccs FC", it, I_FC);
	reg_rd(R_FIFO, b); expect8("T11 status GOOD", b, 8'h00);
	reg_rd(R_FIFO, b); expect8("T11 msg CMDCOMP", b, 8'h00);
	reg_wr(R_CMD, 8'h12);
	wait_irq(500, ok);
	read_regs(st, sp, it);
	expect_bits("T11 disconnect", it, I_DISC);

	//------------------------------------------------------------------
	$display("-- T12 A/UX Startup saio: 512-byte READ(6) as 2x256 $90 chunks");
	//------------------------------------------------------------------
	// Transcribed VERBATIM from qemu-system-m68k master booting this exact
	// ROM+disk (hw/scsi/esp.c trace, 2026-09-01): saio issues $42 SELATN
	// with a FIFO-preloaded IDENTIFY($C0)+CDB, then reads the 512-byte block
	// as TWO $90 DMA chunks of TC=256 bytes each, draining every chunk fully
	// on DRQ before the interrupt.  The FIRST chunk ends with BS and phase
	// still DATA IN (reg[4]=0x91); the SECOND ends with command-complete,
	// phase STATUS (reg[4]=0x93).  The completion NEVER arrives with data
	// still in the FIFO -- DRQ is up throughout the drain, down before the
	// interrupt.  This is the path A/UX Startup actually fails on hardware.
	reg_wr(R_CMD, 8'h02); repeat (4) @(negedge clk);
	reg_wr(R_CMD, 8'h01);                          // flush
	reg_wr(R_FIFO, 8'hC0);                         // IDENTIFY, disconnect OK
	cdb[0]=8'h08; cdb[1]=8'h00; cdb[2]=8'h00; cdb[3]=8'h01; cdb[4]=8'h01; cdb[5]=8'h00;
	for (k = 0; k < 6; k = k + 1) reg_wr(R_FIFO, cdb[k]);
	reg_wr(R_SELID, 8'h00);
	reg_wr(R_CMD, 8'h42);                          // SELATN
	wait_irq(500, ok);
	read_regs(st, sp, it);
	$display("   T12 select : stat=%02X step=%02X intr=%02X", st, sp, it);
	expect_bits("T12 select BS|FC", it, I_BUS | I_FC);
	expect8("T12 step 4", sp & 8'h07, 8'd4);
	expect8("T12 phase DATA IN", {5'd0, st[2:0]}, {5'd0, PH_DIN});
	for (blk = 0; blk < 2; blk = blk + 1) begin
		reg_wr(R_TCM, 8'h01); reg_wr(R_TCL, 8'h00);   // TC = 256 bytes
		reg_wr(R_CMD, 8'h90);                          // DMA TI
		// the Mac reads 16 bits per PDMA access: 128 word-accesses = 256
		// bytes.  DRQ (fifo_cnt>=2) gates each 2-byte access.
		for (k = 0; k < 128; k = k + 1) begin
			guard = 0;
			while (!drq && guard < 100000) begin @(negedge clk); guard = guard + 1; end
			if (guard >= 100000) begin
				fails = fails + 1;
				$display("  FAIL T12 DREQ never asserted, chunk %0d word %0d", blk, k);
				k = 128;
			end
			else begin
				pdma_rd(b);
				expect8("T12 data hi", b, (1*7 + blk*256 + k*2)     & 8'hFF);
				pdma_rd(b);
				expect8("T12 data lo", b, (1*7 + blk*256 + k*2 + 1) & 8'hFF);
			end
		end
		wait_irq(2000, ok);
		checks = checks + 1;
		if (!ok) begin
			fails = fails + 1;
			$display("  FAIL T12 chunk %0d never completed (the block-0 hang)", blk);
		end
		read_regs(st, sp, it);
		reg_peek(R_FFLAG, ff);
		$display("   T12 chunk%0d: stat=%02X intr=%02X fflag=%02X", blk, st, it, ff);
		expect_bits("T12 chunk BS", it, I_BUS);
		if (blk == 0)
			expect8("T12 chunk0 phase still DATA IN", {5'd0, st[2:0]}, {5'd0, PH_DIN});
		else
			expect8("T12 chunk1 phase STATUS", {5'd0, st[2:0]}, {5'd0, PH_STAT});
	end
	reg_wr(R_CMD, 8'h11);                          // ICCS
	wait_irq(500, ok);
	read_regs(st, sp, it);
	expect_bits("T12 iccs FC", it, I_FC);
	reg_rd(R_FIFO, b); expect8("T12 status GOOD", b, 8'h00);
	reg_rd(R_FIFO, b); expect8("T12 msg CMDCOMP", b, 8'h00);
	reg_wr(R_CMD, 8'h12);                          // message accept
	wait_irq(500, ok);
	read_regs(st, sp, it);
	expect_bits("T12 disconnect", it, I_DISC);

	//------------------------------------------------------------------
	$display("-- T13 multi-sector READ(6): 4 blocks (2048 B) across boundaries");
	//------------------------------------------------------------------
	// fsck reads the superblock as an 8 KB (16-sector) block; T10/T12 only
	// ever read ONE sector, so the sector-prefetch path (blocks_left>1, lba
	// advancing across boundaries) was untested.  A bug here reads correct
	// bytes for sector 0 and garbage after -- which is exactly how a valid
	// superblock reads back as "BAD SUPER BLOCK: MAGIC NUMBER WRONG".  Read
	// 4 sectors from LBA 5 in one $90 (TC spans sectors) and check every
	// byte advances block*7+offset across all four.
	reg_wr(R_CMD, 8'h02); repeat (4) @(negedge clk);
	cdb[0]=8'h08; cdb[1]=8'h00; cdb[2]=8'h00; cdb[3]=8'h05; cdb[4]=8'h04; cdb[5]=8'h00;
	rom_command(6);
	wait_irq(500, ok);
	read_regs(st, sp, it);
	expect_bits("T13 intr BS|FC", it, I_BUS | I_FC);
	expect8("T13 phase DATA IN", {5'd0, st[2:0]}, {5'd0, PH_DIN});
	// one $90 with TC = 2048, DRQ-paced 2-byte reads (1024 accesses)
	set_tc(16'd2048);
	reg_wr(R_CMD, 8'h90);
	for (k = 0; k < 1024; k = k + 1) begin
		guard = 0;
		while (!drq && guard < 100000) begin @(negedge clk); guard = guard + 1; end
		if (guard >= 100000) begin
			fails = fails + 1;
			$display("  FAIL T13 DREQ stalled at access %0d (byte %0d, sector %0d)",
			         k, k*2, (k*2)/512);
			k = 1024;
		end
		else begin
			pdma_rd(b);
			expect8("T13 hi", b, ((5 + (k*2)/512)*7     + ((k*2)   % 512)) & 8'hFF);
			pdma_rd(b);
			expect8("T13 lo", b, ((5 + (k*2+1)/512)*7   + ((k*2+1) % 512)) & 8'hFF);
		end
	end
	wait_irq(2000, ok);
	read_regs(st, sp, it);
	$display("   T13 done : stat=%02X intr=%02X", st, it);
	expect_bits("T13 completion BS", it, I_BUS);
	expect8("T13 phase STATUS after 2048 bytes", {5'd0, st[2:0]}, {5'd0, PH_STAT});

	//------------------------------------------------------------------
	$display("-- T14 multi-sector WRITE(6) then read-back: 2 blocks at LBA 10");
	//------------------------------------------------------------------
	// A/UX's autorecovery WRITES to the disk (fsck repairs) as multi-sector
	// $90 DATA OUT transfers -- and the whole write path was untested.  A
	// corrupting write is exactly how a valid on-disk superblock reads back
	// with a wrong magic number after fsck "repairs" it.  Write a distinct
	// pattern across a 2-sector boundary, then read it back and require an
	// exact round-trip.
	reg_wr(R_CMD, 8'h02); repeat (4) @(negedge clk);
	cdb[0]=8'h0A; cdb[1]=8'h00; cdb[2]=8'h00; cdb[3]=8'h0A; cdb[4]=8'h02; cdb[5]=8'h00;
	rom_command(6);                                // select + WRITE(6) CDB
	wait_irq(500, ok);
	read_regs(st, sp, it);
	$display("   T14 wsel  : stat=%02X intr=%02X", st, it);
	expect_bits("T14 write select BS|FC", it, I_BUS | I_FC);
	expect8("T14 phase DATA OUT", {5'd0, st[2:0]}, {5'd0, PH_DOUT});
	// DATA OUT: TC = 1024, $90, then DRQ-paced byte writes
	reg_wr(R_CMD, 8'h01);                          // flush
	set_tc(16'd1024);
	reg_wr(R_CMD, 8'h90);
	for (k = 0; k < 1024; k = k + 1) begin
		guard = 0;
		while (!drq && guard < 100000) begin @(negedge clk); guard = guard + 1; end
		if (guard >= 100000) begin
			fails = fails + 1;
			$display("  FAIL T14 write DREQ stalled at byte %0d (sector %0d)", k, k/512);
			k = 1024;
		end
		else pdma_wr((k*5 + 3) & 8'hFF);
	end
	wait_irq(4000, ok);
	read_regs(st, sp, it);
	$display("   T14 wdone : stat=%02X intr=%02X blocks_written=%0d", st, it, wr_blocks);
	expect_bits("T14 write completion BS", it, I_BUS);
	expect8("T14 phase STATUS after write", {5'd0, st[2:0]}, {5'd0, PH_STAT});
	reg_wr(R_CMD, 8'h11); wait_irq(500, ok);       // ICCS
	reg_rd(R_FIFO, b); reg_rd(R_FIFO, b);
	reg_wr(R_CMD, 8'h12); wait_irq(500, ok);       // msgacc
	// now READ it back and require an exact round-trip
	reg_wr(R_CMD, 8'h02); repeat (4) @(negedge clk);
	cdb[0]=8'h08; cdb[1]=8'h00; cdb[2]=8'h00; cdb[3]=8'h0A; cdb[4]=8'h02; cdb[5]=8'h00;
	rom_command(6);
	wait_irq(500, ok);
	read_regs(st, sp, it);
	expect8("T14 readback phase DATA IN", {5'd0, st[2:0]}, {5'd0, PH_DIN});
	set_tc(16'd1024);
	reg_wr(R_CMD, 8'h90);
	for (k = 0; k < 512; k = k + 1) begin
		guard = 0;
		while (!drq && guard < 100000) begin @(negedge clk); guard = guard + 1; end
		if (guard >= 100000) begin
			fails = fails + 1;
			$display("  FAIL T14 readback DREQ stalled at access %0d", k);
			k = 512;
		end
		else begin
			pdma_rd(b);
			expect8("T14 rb hi", b, (k*2*5 + 3) & 8'hFF);
			pdma_rd(b);
			expect8("T14 rb lo", b, ((k*2+1)*5 + 3) & 8'hFF);
		end
	end
	wait_irq(2000, ok);
	read_regs(st, sp, it);
	expect8("T14 readback ends STATUS", {5'd0, st[2:0]}, {5'd0, PH_STAT});

	//------------------------------------------------------------------
	$display("-- T15 chunked WRITE(6): 4 blocks at LBA 20 as 8 x ($90 TC=256) -- the saio/fsck dialect");
	//------------------------------------------------------------------
	// Under A/UX Startup the ROM SCSI Manager splits one WRITE into many
	// $90 TIs of TC=256 (QEMU master esp trace of this ROM+disk: fsck's
	// 2KB superblock write-back is 8 x TC=256, cg flushes 32 x TC=256).
	// T14's single TC=1024 TI never exercised a TC expiry mid-sector, so
	// the old "trailing partial sector" flush went unseen: it flushed 256
	// real bytes plus a stale upper half per chunk, burned one block of
	// the CDB count per chunk, and flipped to STATUS halfway through the
	// data -- fsck's superblock landed smeared at 256 bytes/sector and
	// the magic number vanished.  Require: phase holds DATA OUT through
	// chunk 7, exactly 4 blocks flushed, and a byte-exact disk image.
	reg_wr(R_CMD, 8'h02); repeat (4) @(negedge clk);
	byi = wr_blocks;                               // blocks flushed so far
	cdb[0]=8'h0A; cdb[1]=8'h00; cdb[2]=8'h00; cdb[3]=8'h14; cdb[4]=8'h04; cdb[5]=8'h00;
	rom_command(6);                                // select + WRITE(6) LBA 20, 4 blocks
	wait_irq(500, ok);
	read_regs(st, sp, it);
	$display("   T15 wsel  : stat=%02X intr=%02X", st, it);
	expect_bits("T15 write select BS|FC", it, I_BUS | I_FC);
	expect8("T15 phase DATA OUT", {5'd0, st[2:0]}, {5'd0, PH_DOUT});
	reg_wr(R_CMD, 8'h01);                          // flush, as the ROM does
	for (blk = 0; blk < 8; blk = blk + 1) begin
		set_tc(16'd256);
		reg_wr(R_CMD, 8'h90);
		for (k = 0; k < 256; k = k + 1) begin
			guard = 0;
			while (!drq && guard < 100000) begin @(negedge clk); guard = guard + 1; end
			if (guard >= 100000) begin
				fails = fails + 1;
				$display("  FAIL T15 DREQ stalled at chunk %0d byte %0d", blk, k);
				k = 256;
			end
			else pdma_wr(((blk*256 + k)*11 + 7) & 8'hFF);
		end
		wait_irq(4000, ok);
		read_regs(st, sp, it);
		expect_bits("T15 chunk completion BS", it, I_BUS);
		if (blk != 7)
			expect8("T15 phase DATA OUT between chunks", {5'd0, st[2:0]}, {5'd0, PH_DOUT});
	end
	expect8("T15 phase STATUS after chunk 8", {5'd0, st[2:0]}, {5'd0, PH_STAT});
	reg_wr(R_CMD, 8'h11); wait_irq(500, ok);       // ICCS
	reg_rd(R_FIFO, b); expect8("T15 status GOOD", b, 8'h00);
	reg_rd(R_FIFO, b);
	reg_wr(R_CMD, 8'h12); wait_irq(500, ok);       // msgacc
	// the final flush is armed the same cycle STATUS is raised (a real
	// target completes with the last block still in its cache); let the
	// platform model drain it before inspecting the medium
	guard = 0;
	while (wr_blocks - byi != 4 && guard < 100000) begin @(negedge clk); guard = guard + 1; end
	$display("   T15 wdone : stat=%02X intr=%02X blocks_flushed=%0d", st, it, wr_blocks - byi);
	checks = checks + 1;
	if (wr_blocks - byi != 4) begin
		fails = fails + 1;
		$display("  FAIL T15 blocks flushed: got %0d want 4", wr_blocks - byi);
	end
	// the disk itself, byte-exact -- a smear cannot hide from this
	for (k = 0; k < 2048; k = k + 1) begin
		checks = checks + 1;
		if (disk[20*512 + k] !== (((k*11) + 7) & 8'hFF)) begin
			fails = fails + 1;
			if (fails < 12)
				$display("  FAIL T15 disk byte %0d (sector %0d+%0d): got %02X want %02X",
				         k, 20 + k/512, k%512, disk[20*512 + k], ((k*11) + 7) & 8'hFF);
		end
	end

	$display("== tb_ncr53c96: %0d checks, %0d failures ==", checks, fails);
	if (fails != 0) $display("RESULT: FAIL");
	else            $display("RESULT: PASS");
	$finish;
end

initial begin
	#20_000_000;
	$display("== tb_ncr53c96: TIMEOUT ==");
	$display("RESULT: FAIL");
	$finish;
end

endmodule
