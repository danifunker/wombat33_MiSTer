//============================================================================
//  sdram_beat32 — 32-bit machine beats on the 16-bit MiSTer SDRAM controller.
//
//  Wraps rtl/sdram.sv (Sorgelig's, from NeoGeo_MiSTer) and the clk_sys <->
//  clk_ram handshake that used to live inline in MacQuadra800.sv.  Two things
//  here that the plain two-access bridge did not do:
//
//  * A READ IS ONE ROW CYCLE, NOT TWO.  The controller's mode register
//    already programs BURST_LENGTH=4, so every READ returns four words —
//    the old bridge discarded all four but the first, then paid a second
//    full ACT -> RD -> auto-precharge cycle for a word the chip had already
//    handed it.  A 32-bit beat's two halves are a 4-byte-aligned pair, so
//    they are always words 0 and 1 of one burst: issue once, latch both.
//    14 -> 8 clk_ram of SDRAM time per read beat (~141 -> ~81 ns).
//    Writes still take two accesses; NO_WRITE_BURST=1 in the mode register.
//
//  * WRITES ARE POSTED.  ack fires as the beat is captured and the drain
//    happens behind the machine's back.  Nothing downstream had to change
//    for that: the whole stall chain — this bridge, wombat_bus32, the
//    cache's write-through C_PASS state, the core — is ack-based, so
//    releasing the ack releases all of it.  Ordering is free, because the
//    next beat still waits on `busy`: a read that follows a posted write
//    cannot start until the write has been issued to the chip.  Posting
//    hides write latency; it does not add bandwidth, so a sustained store
//    stream still drains at the controller's rate.
//
//  Beat contract (clk_sys):
//   - req is level-held; a beat is captured on the first cycle with
//     !busy && !ack, and req may drop as soon as ack is seen.
//   - ack is a single-cycle pulse.  For a read it means "rdata is valid";
//     for a write it means "accepted", not "in the chip".
//   - busy spans the whole access, a posted write's drain included, and is
//     the only thing that orders one beat against the next.
//
//  Byte lanes: be[3] is the byte at addr+0 = wdata[31:24] (the machine's
//  big-endian convention), so the first SDRAM word carries wdata[31:16].
//  Nothing else reads this memory, so the in-chip order only has to agree
//  with itself.
//============================================================================

module sdram_beat32
(
	input             init,          // hold the controller in its power-up sequence
	input             clk_sys,
	input             clk_ram,       // 3x clk_sys, same PLL, phase aligned

	// beat port (clk_sys)
	input             req,
	input             we,
	input      [26:2] addr,
	input       [3:0] be,
	input      [31:0] wdata,
	output reg        ack   = 0,
	output reg [31:0] rdata = 0,
	output reg        busy  = 0,

	// SDRAM pins
	inout      [15:0] SDRAM_DQ,
	output     [12:0] SDRAM_A,
	output            SDRAM_DQML,
	output            SDRAM_DQMH,
	output      [1:0] SDRAM_BA,
	output            SDRAM_nCS,
	output            SDRAM_nWE,
	output            SDRAM_nRAS,
	output            SDRAM_nCAS,
	output            SDRAM_CKE,
	output            SDRAM_CLK
);

// 8192 refreshes / 64 ms = one every 7.8 us = 772 cycles at 99 MHz
reg        refresh = 0;
reg  [9:0] refcnt  = 0;

always @(posedge clk_ram) begin
	refcnt <= refcnt + 1'b1;
	if (refcnt == 10'd771) begin
		refcnt  <= 0;
		refresh <= ~refresh;
	end
end

// ---- clk_sys side: hand one beat over, wait for the ack toggle ----------
reg        req_tgl  = 0;
reg        ack_seen = 0;
reg  [1:0] ack_sync = 0;
reg        posted   = 0;             // the beat in flight was acked at capture
reg [26:2] r_addr;
reg [31:0] r_wdata;
reg  [3:0] r_be;
reg        r_we;

// ---- clk_ram side: one burst read, or two 16-bit writes ----------------
reg        req_seen = 0;
reg  [1:0] req_sync = 0;
reg        busy_r   = 0;
reg        acc      = 0;             // write half: 0 = high word, 1 = low
reg        rd2      = 0;             // burst word 1 is on the bus this cycle
reg        ready_d  = 0;
reg [31:0] hold     = 0;
reg        ack_tgl  = 0;

wire [15:0] dout;
wire        ready;

always @(posedge clk_sys) begin
	ack <= 0;

	if (req && !busy && !ack) begin
		r_addr  <= addr;
		r_wdata <= wdata;
		r_be    <= be;
		r_we    <= we;
		req_tgl <= ~req_tgl;
		busy    <= 1;
		posted  <= we;
		if (we) ack <= 1;            // posted: the drain is invisible from here
	end

	ack_sync <= {ack_sync[0], ack_tgl};
	if (busy && (ack_sync[1] != ack_seen)) begin
		ack_seen <= ack_sync[1];
		busy     <= 0;
		posted   <= 0;
		if (!posted) begin
			rdata <= hold;
			ack   <= 1;
		end
	end
end

// rd/wr are held for the whole access: the controller may still be walking
// back to its idle state when a request arrives, and it samples the request
// only there.  Completion is the RISING edge of ready — ready sits low
// before the very first access and through the ~122 us power-up sequence,
// so waiting on the edge cannot false-trigger or deadlock.
//
// rd2 drops rd one cycle early.  With the burst captured, the controller is
// back in STATE_IDLE the cycle after word 1 lands, and a still-asserted rd
// there would read as a fresh request for the same address.
wire rd = busy_r && !r_we && !rd2;
wire wr = busy_r &&  r_we;

always @(posedge clk_ram) begin
	req_sync <= {req_sync[0], req_tgl};
	ready_d  <= ready;

	if (rd2) begin
		// BURST_LENGTH=4, sequential: word 1 follows word 0 with no gap, and
		// the pair is 4-byte aligned so the burst can never wrap between them.
		rd2        <= 0;
		hold[15:0] <= dout;
		busy_r     <= 0;
		ack_tgl    <= ~ack_tgl;
	end
	else if (!busy_r) begin
		if (req_sync[1] != req_seen) begin
			req_seen <= req_sync[1];
			acc      <= 0;
			busy_r   <= 1;
		end
	end
	else if (ready && !ready_d) begin
		if (!r_we) begin
			hold[31:16] <= dout;     // burst word 0
			rd2         <= 1;
		end
		else if (!acc) acc <= 1;     // second half of the write
		else begin
			busy_r  <= 0;
			ack_tgl <= ~ack_tgl;
		end
	end
end

sdram sdram
(
	.init      (init),
	.clk       (clk_ram),
	.SDRAM_EN  (1'b1),

	.SDRAM_DQ  (SDRAM_DQ),
	.SDRAM_A   (SDRAM_A),
	.SDRAM_DQML(SDRAM_DQML),
	.SDRAM_DQMH(SDRAM_DQMH),
	.SDRAM_BA  (SDRAM_BA),
	.SDRAM_nCS (SDRAM_nCS),
	.SDRAM_nWE (SDRAM_nWE),
	.SDRAM_nRAS(SDRAM_nRAS),
	.SDRAM_nCAS(SDRAM_nCAS),
	.SDRAM_CKE (SDRAM_CKE),
	.SDRAM_CLK (SDRAM_CLK),

	.sel       (1'b1),
	.addr      ({r_addr, acc}),          // word address; acc picks the half
	.dout      (dout),
	.din       (acc ? r_wdata[15:0] : r_wdata[31:16]),
	.wr        (wr),
	.bs        (acc ? r_be[1:0] : r_be[3:2]),
	.rd        (rd),
	.ready     (ready),
	.refresh   (refresh),

	.cpsel     (1'b0),
	.cpaddr    (26'd0),
	.cpdin     (16'd0),
	.cprd      (),
	.cpreq     (1'b0),
	.cpbusy    ()
);

endmodule
