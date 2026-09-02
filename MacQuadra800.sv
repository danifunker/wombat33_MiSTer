//============================================================================
//  MacQuadra800 — MiSTer top for the Quadra 800 machine.
//
//  Platform memory contract (see rtl/quadra800.sv and verilator/sim.v):
//  one ack-based beat port with mem_memsel (0 RAM, 1 ROM, 2 VRAM) plus a
//  registered 1-cycle video scanout port.  Here:
//   - RAM (32 MB) and ROM (1 MB) live in DDR3 behind a simple bridge —
//     the machine's bus FSM already tolerates wait states and the 68040
//     caches absorb the latency.  ROM writes are acked and discarded
//     (djMEMC behavior), which also write-protects the ROM region.
//   - VRAM is on-chip BRAM, 320 KB physical, advertised as 512 KB: the
//     driver's 1024-byte row pitch is compacted to the 640 bytes each
//     row can actually show, so every row of every depth is backed
//     exactly once — see the VRAM section.  The DAFB scanout expects
//     registered 1-cycle reads.  Still the main BRAM consumer.
//   - The ROM uploads as boot.rom (ioctl index 0) into the DDR3 ROM
//     region; the machine is held in reset until it lands.
//   - The SCSI disk is hps_io block device 0 (mount a .hda in the OSD);
//     the 53C96 speaks the 16-bit sd_buff interface natively.
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//============================================================================

module emu
(
	`include "sys/emu_ports.vh"
);

///////// Default values for ports not used in this core /////////

assign ADC_BUS  = 'Z;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
// USER_OUT is driven by the mt32pi instance (user-port MIDI + I2C); unused
// user-port pins are held at '1 inside sys/mt32pi.sv.  UART_TXD/RTS/DTR are
// driven from the SCC further down.

assign VGA_SL = 0;
assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

assign AUDIO_S = 1;                        // ASC samples are signed
assign AUDIO_MIX = 0;

assign LED_POWER = 0;
assign BUTTONS = 0;

//////////////////////////////////////////////////////////////////

wire [1:0] ar = status[122:121];

assign VIDEO_ARX = (!ar) ? 12'd4 : (ar - 1'd1);
assign VIDEO_ARY = (!ar) ? 12'd3 : 12'd0;

`include "build_id.v"
localparam CONF_STR = {
	// UART token: 57600/115200 for MidiLink + PPP, plus MIDI (31250).  The SCC
	// reaches 31250 through its own WR11/TRxC path (rtl/scc.v); the token is
	// what makes the Main offer the MIDI mode, and the mode it reports back in
	// uart_mode is what gates the user-port MIDI-in merge on serialIn below.
	"MacQuadra800;UART57600:115200,MIDI;",
	// SC0, not S0: the letter after S is a flag, and 'C' is what sets
	// store_name in the Main's option parser -- i.e. what makes MiSTer write
	// config/MacQuadra800.s0 and re-mount the image on the next core start. With a
	// plain S0 the mount works but is forgotten every boot, so the disk had to
	// be picked from the OSD by hand each time and the deploy's slot-0 seed was
	// inert. Every sibling Mac core (MacLC, MacLCII, MacIIvi, MacPlus,
	// LBMacTwo) uses SC0 for this reason.
	"SC0,HDAVHD,Mount SCSI disk;",
	"-;",
	"O[4:3],RAM (on reset),32MB,64MB,128MB;",
	"O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"-;",
	"T[0],Reset;",
	"R[0],Reset and close OSD;",
	"-;",
	"P1,MT32-pi;",
	"P1-;",
	"P1O[35],Use MT32-pi,Yes,No;",
	"P1O[36],Synth,Munt,FluidSynth;",
	"P1O[38:37],Munt ROM,MT-32 v1,MT-32 v2,CM-32L;",
	"P1O[41:39],SoundFont,0,1,2,3,4,5,6,7;",
	"P1O[43:42],Show Info,No,Yes,LCD-On,LCD-Auto;",
	// "Show Info = Yes" popup strings, indexed 1-based by mt32_info_disp
	"I,",
	"MT32-pi: SoundFont #0,",
	"MT32-pi: SoundFont #1,",
	"MT32-pi: SoundFont #2,",
	"MT32-pi: SoundFont #3,",
	"MT32-pi: SoundFont #4,",
	"MT32-pi: SoundFont #5,",
	"MT32-pi: SoundFont #6,",
	"MT32-pi: SoundFont #7,",
	"MT32-pi: MT-32 v1,",
	"MT32-pi: MT-32 v2,",
	"MT32-pi: CM-32L,",
	"MT32-pi: Unknown mode;",
	"v,0;",
	"V,v",`BUILD_DATE
};

wire  [1:0] buttons;
wire [127:0] status;
wire [10:0] ps2_key;
wire [24:0] ps2_mouse;

wire        ioctl_download;
wire [15:0] ioctl_index;
wire        ioctl_wr;
wire [26:0] ioctl_addr;
wire [15:0] ioctl_dout;
reg         ioctl_wait;

wire [31:0] sd_lba[1];
wire  [0:0] sd_rd, sd_wr;
wire  [0:0] sd_ack;
wire [12:0] sd_buff_addr;
wire [15:0] sd_buff_dout;
wire [15:0] sd_buff_din[1];
wire        sd_buff_wr;
wire [32:0] TIMESTAMP;                     // Unix seconds from the HPS, for the RTC
wire  [0:0] img_mounted;
wire        img_readonly;
wire [63:0] img_size;

hps_io #(.CONF_STR(CONF_STR), .WIDE(1), .VDNUM(1), .BLKSZ(2)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(),

	.buttons(buttons),
	.status(status),

	// MT32-pi "Show Info = Yes" OSD popup (CONF_STR "I," strings, 1-based)
	.info_req(mt32_info_req),
	.info({4'd0, mt32_info_disp}),

	// OSD "UART mode" as the Main reports it: 0=None, 1=PPP (the Main maps
	// its modem modes to 1 before sending), 2=Console, 3=MIDI.  Gates the
	// user-port MIDI-in merge at the serialIn assign above.
	.uart_mode(uart_mode),

	.ps2_key(ps2_key),
	.ps2_mouse(ps2_mouse),

	.TIMESTAMP(TIMESTAMP),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait),

	.sd_lba(sd_lba),
	.sd_blk_cnt('{6'd0}),
	.sd_rd(sd_rd),
	.sd_wr(sd_wr),
	.sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din(sd_buff_din),
	.sd_buff_wr(sd_buff_wr),
	.img_mounted(img_mounted),
	.img_readonly(img_readonly),
	.img_size(img_size)
);

///////////////////////   CLOCKS   ///////////////////////////////

wire clk_sys;
wire clk_ram;                              // 99 MHz = 3x clk_sys, SDRAM domain
wire pll_locked;

// Dedicated dot clock for the DAFB scanout.  The video used to run on clk_sys,
// which made 640x480 in an 800x525 frame refresh at 78.6 Hz with a 33 MHz dot
// clock -- far enough off spec that Main_MiSTer's vsync_adjust synthesised a
// broken HDMI mode from it (the reported screen showing the frame four times
// across the width).  25.175 MHz gives exactly VGA 640x480 @ 59.94 Hz, which
// is what the Mac LC core does; see rtl/pll_video.v.
wire clk_vid, pll_video_locked;
pll_video pllv
(
	.refclk(CLK_50M),
	.rst(1'b0),
	.outclk_0(clk_vid),
	.locked(pll_video_locked),
	.reconfig_to_pll(64'd0),
	.reconfig_from_pll()
);

// video-domain reset: released only once the pixel clock is locked AND the
// machine is out of reset, 2FF-synced into clk_vid
reg vidrst_meta, vidrst_s;
always @(posedge clk_vid) begin
	vidrst_meta <= reset | ~pll_video_locked;
	vidrst_s    <= vidrst_meta;
end
wire nreset_vid = ~vidrst_s;
pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_1(clk_ram),
	.outclk_0(clk_sys),                    // 33.000000 MHz machine clock — the
	                                       // real Quadra 800 rate, and the exact
	                                       // base every time-anchored divider
	                                       // assumes (RTC SEC_DIV, the 60.15 Hz
	                                       // tick, VIA E_HALF, ASC SAMPLE_DIV)
	.locked(pll_locked)
);

// hold the machine until the PLL locks and boot.rom has landed in DDR3
wire rom_index = (ioctl_index[5:0] == 0);
reg  rom_loaded = 0;
reg  dl_d = 0;
always @(posedge clk_sys) begin
	dl_d <= ioctl_download;
	if (dl_d && !ioctl_download && rom_index) rom_loaded <= 1;
end

wire reset = RESET | status[0] | buttons[1] | ioctl_download |
             ~rom_loaded | ~pll_locked;

// Re-announce the mounted image to the machine after EVERY reset.
//
// ncr53c96 latches `mounted`/`disk_blocks` only on the img_mounted pulse, and
// its always block is reset-gated, so a machine reset throws the mount away.
// The Main sends that pulse exactly twice in a core's life -- once at core
// start (SC0 restoring the saved mount) and again if you pick a file in the
// OSD -- so after any reset the target believed no disk was present and the ROM
// dropped to the flashing-? screen. That is why the disk had to be re-assigned
// by hand after every reboot.
//
// Two distinct problems are handled here:
//   1. The core-start mount lands INSIDE the reset window, because `reset`
//      spans the whole boot.rom ioctl upload -- so the pulse would be dropped
//      even on the first boot. Symptom: the Main holds the file open (fd
//      present, pos stuck at 0) while the machine shows flashing-?.
//   2. Every LATER reset clears the target's copy with no new pulse coming.
//
// So the mount is remembered here, outside the machine reset, and replayed on
// each reset release as well as when it first arrives. Size is captured a cycle
// ahead of the pulse so it is stable when the target samples it.
reg        mount_valid  = 0;      // an image is mounted (survives machine reset)
reg [63:0] mount_size   = 0;
reg        mount_replay = 0;
reg        reset_d      = 1;
reg        mach_img_mounted = 0;
always @(posedge clk_sys) begin
	mach_img_mounted <= 0;
	reset_d          <= reset;

	if (img_mounted[0]) begin
		mount_size   <= img_size;
		mount_valid  <= (img_size != 0);   // size 0 = eject, replay that too
		mount_replay <= 1;
	end
	else if (reset_d && !reset && mount_valid) begin
		mount_replay <= 1;                 // reset just released: re-announce
	end
	else if (mount_replay && !reset) begin
		mount_replay     <= 0;
		mach_img_mounted <= 1;
	end
end

///////////////////////   MACHINE   //////////////////////////////

wire        mem_req, mem_write;
wire [31:2] mem_addr;
wire  [3:0] mem_be;
wire [31:0] mem_wdata;
wire  [1:0] mem_memsel;
wire [31:0] mem_rdata;                     // VRAM/ROM reg, or the SDRAM bridge
wire        mem_ack;
reg  [31:0] mem_rdata_r;
reg         mem_ack_r;

wire        mem_is_ram  = (mem_memsel == 2'd0);
wire        mem_is_rom  = (mem_memsel == 2'd1);
wire        mem_is_vram = !mem_is_ram && !mem_is_rom;

wire [21:2] vid_addr;
reg  [31:0] vid_rdata;
wire [13:0] vid_stride;

wire [255:0] m_debug_status;
wire [127:0] m_debug_status2;

localparam RAM_ADDR_BITS = 27;             // address ceiling: 128 MB

// Installed RAM from the OSD (0=32MB, 1=64MB, 2=128MB — powers of two only;
// see the ram_limit comment in rtl/quadra800.sv for why 48MB needs the djMEMC
// bank decode first).
wire [1:0] ram_cfg_osd = (status[4:3] == 2'd3) ? 2'd0 : status[4:3];

// Sampled ONLY while the machine is in reset, so a new size takes effect at the
// next reset and never under a running machine.
//
// This used to fold ram_cfg_change straight into `reset`, which meant nudging
// the OSD setting instantly hard-reset a running Mac OS -- a power-cut on a
// mounted HFS volume, and a good way to corrupt the disk by accident. The ROM
// sizes memory exactly once during startup, so applying a change live could
// never have worked anyway: the machine would keep using the size it probed.
reg [1:0] ram_cfg = 2'd0;
always @(posedge clk_sys) if (reset) ram_cfg <= ram_cfg_osd;

quadra800 #(.RAM_ADDR_BITS(RAM_ADDR_BITS)) machine (
	.clk(clk_sys),
	.nreset(~reset),
	.ce(1'b1),
	.clk_vid(clk_vid),
	.nreset_vid(nreset_vid),
	.ram_cfg(ram_cfg),

	.mem_req(mem_req),
	.mem_write(mem_write),
	.mem_addr(mem_addr),
	.mem_be(mem_be),
	.mem_wdata(mem_wdata),
	.mem_memsel(mem_memsel),
	.mem_rdata(mem_rdata),
	.mem_ack(mem_ack),

	.vid_addr(vid_addr),
	.vid_rdata(vid_rdata),
	.vid_stride(vid_stride),
	.VGA_R(mac_vga_r),
	.VGA_G(mac_vga_g),
	.VGA_B(mac_vga_b),
	.VGA_HS(VGA_HS),
	.VGA_VS(VGA_VS),
	.VGA_HB(m_hblank),
	.VGA_VB(m_vblank),
	.CE_PIXEL(CE_PIXEL),

	.AUDIO_L(mac_audio_l),
	.AUDIO_R(mac_audio_r),

	.ps2_key(ps2_key),
	.ps2_mouse(ps2_mouse),
	.timestamp(TIMESTAMP),

	.scc_rxd_a(serialIn),
	.scc_txd_a(serialOut),
	.scc_cts_a(serialCTS),
	.scc_rts_a(serialRTS),
	.scc_rxd_b(1'b1),          // printer port RX idles high (no LocalTalk yet)
	.scc_txd_b(serialOutB),

	.img_mounted(mach_img_mounted),
	.img_size(mount_size),
	.io_lba(sd_lba[0]),
	.io_rd(sd_rd[0]),
	.io_wr(sd_wr[0]),
	.io_ack(sd_ack[0]),
	.sd_buff_addr(sd_buff_addr[7:0]),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din(sd_buff_din[0]),
	.sd_buff_wr(sd_buff_wr),

	.dbg_berr(),
	.dbg_berr_addr(),
	.dbg_overlay(),
	.debug_status(m_debug_status),
	.debug_status2(m_debug_status2),
	.debug_fault(),
	.debug_halted()
);

wire m_hblank, m_vblank;
assign CLK_VIDEO = clk_vid;
assign VGA_DE = ~(m_hblank | m_vblank);

//////////////////////////////////////////////////////////////////
// SCC serial — MidiLink / PPP / console on channel A, MT32-pi on the user port
//
// Channel A TX fans out to BOTH the HPS UART (UART_TXD -> MidiLink, PPP,
// console) and the MT32-pi's MIDI-in on the user port.  RX sources:
//   - ALWAYS the HPS UART (UART_RXD) — MidiLink / console / PPP.
//   - In OSD UART mode = MIDI ONLY, the user-port MIDI-in line (mt32_midi_rx:
//     the Pi's TX pin when an MT32-pi is detected, USER_IN[0] otherwise) is
//     AND-merged in.  Both lines idle high, so the merge is inert until a
//     source actually transmits and a start bit from either reaches the SCC.
//
// The uart_mode gate is load-bearing, and is the one piece here that was paid
// for in hardware debugging on the LC: an unconditional
// `mt32_available ? mt32_midi_rx : UART_RXD` mux repointed guest RX at the
// Pi's MIDI-return line whenever a Pi was detected, so EVERY guest-receive
// path died with a Pi plugged in while TX kept working (which made it look
// one-directional).  PPP was what exposed it — LCP hung because the guest
// never saw pppd's ConfAck.  Outside MIDI mode serialIn is UART_RXD alone, so
// the user port can never hijack guest receive; PPP/console are unaffected.
//////////////////////////////////////////////////////////////////
wire serialOut, serialRTS;
wire serialOutB;                           // printer port TX — unused for now
wire serialCTS = 1'b1;                     // idle/deasserted: no device attached
wire [7:0] uart_mode;                      // from hps_io; 3 = MIDI

wire userport_midi_in = (uart_mode == 8'd3) ? mt32_midi_rx : 1'b1;
wire serialIn = UART_RXD & userport_midi_in;
assign UART_TXD = serialOut;
assign UART_RTS = serialRTS;
assign UART_DTR = UART_DSR;

// MT32-pi on the user port (framework module sys/mt32pi.sv): serial MIDI out
// on USER_OUT[1] at the SCC's programmed rate, I2S synth audio back on
// USER_IN[2/4/5], I2C detection/control on USER_IN[0]/[3].  The synth path
// runs in the fixed 24.576 MHz CLK_AUDIO domain; the LCD-overlay raster
// tracker runs on clk_vid and its box is composited into VGA_R/G/B below.
wire [15:0] mt32_i2s_l, mt32_i2s_r;
wire        mt32_available;
wire        mt32_midi_rx;
wire        mt32_disable = status[35];              // "Use MT32-pi" = No
wire        mt32_mute    = mt32_available & mt32_disable;
wire        mt32_use     = mt32_available & ~mt32_disable;
wire  [1:0] mt32_info    = status[43:42];           // No/Yes/LCD-On/LCD-Auto
wire  [7:0] mt32_mode, mt32_rom, mt32_sf;
wire        mt32_newmode;
wire        mt32_lcd_en, mt32_lcd_pix, mt32_lcd_update;

mt32pi mt32pi
(
	.CLK_AUDIO(CLK_AUDIO),
	.CLK_VIDEO(clk_vid),
	.CE_PIXEL(CE_PIXEL),
	.VGA_VS(VGA_VS),
	.VGA_DE(VGA_DE),
	.USER_IN(USER_IN),
	.USER_OUT(USER_OUT),
	.reset(reset),
	.midi_tx(serialOut | mt32_mute),        // idle the Pi's MIDI-in when off
	.midi_rx(mt32_midi_rx),
	.mt32_i2s_r(mt32_i2s_r),
	.mt32_i2s_l(mt32_i2s_l),
	.mt32_available(mt32_available),
	.mt32_mode_req(status[36]),             // Synth: 0=Munt, 1=FluidSynth
	.mt32_rom_req(status[38:37]),           // Munt ROM: MT-32 v1/v2/CM-32L
	.mt32_sf_req({5'd0, status[41:39]}),    // SoundFont 0-7
	.mt32_mode(mt32_mode),
	.mt32_rom(mt32_rom),
	.mt32_sf(mt32_sf),
	.mt32_newmode(mt32_newmode),
	.mt32_lcd_en(mt32_lcd_en),
	.mt32_lcd_pix(mt32_lcd_pix),
	.mt32_lcd_update(mt32_lcd_update)
);

// "Show Info = Yes": on a Pi-acknowledged mode change (mt32_newmode toggles),
// flash the mode name via the framework info popup (hps_io info_req/info ->
// the CONF_STR "I," strings, 1-based).  Block is ao486-verbatim.
reg       mt32_info_req;
reg [3:0] mt32_info_disp;
always @(posedge clk_sys) begin
	reg old_mode;

	old_mode <= mt32_newmode;
	mt32_info_req <= (old_mode ^ mt32_newmode) && (mt32_info == 1);

	mt32_info_disp <= (mt32_mode == 'hA2) ? (4'd1 + mt32_sf[2:0]) :
	                  (mt32_mode == 'hA1 && mt32_rom == 0) ?  4'd9 :
	                  (mt32_mode == 'hA1 && mt32_rom == 1) ?  4'd10 :
	                  (mt32_mode == 'hA1 && mt32_rom == 2) ?  4'd11 : 4'd12;
end

// LCD overlay visibility (ao486 pattern): "LCD-On" pins it up, "LCD-Auto"
// shows it while the Pi pushes LCD updates and drops it after a timeout.
// clk_vid is the 25.175 MHz dot clock here, so 50M ticks is ~2.0 s.
reg mt32_lcd_on;
always @(posedge clk_vid) begin
	int to;
	reg old_update;

	old_update <= mt32_lcd_update;
	if(to) to <= to - 1;

	if(mt32_info == 2) mt32_lcd_on <= 1;
	else if(mt32_info != 3) mt32_lcd_on <= 0;
	else begin
		if(!to) mt32_lcd_on <= 0;
		if(old_update ^ mt32_lcd_update) begin
			mt32_lcd_on <= 1;
			to <= 50_000_000;
		end
	end
end

// Video: inside the overlay box the picture is dimmed to its low 6 bits and
// the LCD text pixel is OR'd into the top 2 (ao486's compositing, verbatim).
wire [7:0] mac_vga_r, mac_vga_g, mac_vga_b;
wire       mt32_lcd = mt32_lcd_en & mt32_lcd_on;
assign VGA_R = mt32_lcd ? {{2{mt32_lcd_pix}}, mac_vga_r[7:2]} : mac_vga_r;
assign VGA_G = mt32_lcd ? {{2{mt32_lcd_pix}}, mac_vga_g[7:2]} : mac_vga_g;
assign VGA_B = mt32_lcd ? {{2{mt32_lcd_pix}}, mac_vga_b[7:2]} : mac_vga_b;

// Audio: the MT32-pi I2S return joins at unity gain, gated by mt32_use (a Pi
// is present AND "Use MT32-pi" is Yes); exact zeros otherwise, so the mix is
// bit-identical to today with no Pi attached or the device disabled.
wire signed [15:0] mac_audio_l, mac_audio_r;
wire signed [17:0] audio_mix_l = {{2{mac_audio_l[15]}}, mac_audio_l}
                               + (mt32_use ? {{2{mt32_i2s_l[15]}}, mt32_i2s_l} : 18'sd0);
wire signed [17:0] audio_mix_r = {{2{mac_audio_r[15]}}, mac_audio_r}
                               + (mt32_use ? {{2{mt32_i2s_r[15]}}, mt32_i2s_r} : 18'sd0);
assign AUDIO_L = (audio_mix_l > 18'sd32767)  ?  16'sd32767 :
                 (audio_mix_l < -18'sd32768) ? -16'sd32768 : audio_mix_l[15:0];
assign AUDIO_R = (audio_mix_r > 18'sd32767)  ?  16'sd32767 :
                 (audio_mix_r < -18'sd32768) ? -16'sd32768 : audio_mix_r[15:0];

assign LED_USER = ioctl_download | sd_rd[0] | sd_wr[0];
assign LED_DISK = {1'b1, sd_rd[0] | sd_wr[0]};

//////////////////////////////////////////////////////////////////
// SDRAM — the machine's RAM.  ROM stays in DDR3 (it is uploaded once
// through the ioctl path and read rarely enough that latency is free).
//
// rtl/sdram_beat32.sv owns the 16-bit controller and both clock domains:
// one beat is one burst read (BURST_LENGTH=4 is already in the mode
// register, so both halves arrive in a single row cycle) or two 16-bit
// writes, and writes are acked here and drained behind the machine.  The
// controller runs at 99 MHz — three times clk_sys, from the same PLL — and
// derives SDRAM_CLK itself with an altddio_out, so no phase-shifted clock
// is needed here.
//////////////////////////////////////////////////////////////////

wire        sdr_ack;
wire [31:0] sdr_rdata;

// The ack the machine sees is this bridge's or the VRAM/ROM one; they are
// never asserted together, because mem_memsel picks exactly one consumer.
assign mem_ack   = mem_ack_r | sdr_ack;
assign mem_rdata = sdr_ack ? sdr_rdata : mem_rdata_r;

sdram_beat32 sdr
(
	.init      (~pll_locked),
	.clk_sys   (clk_sys),
	.clk_ram   (clk_ram),

	.req       (mem_req && mem_is_ram),
	.we        (mem_write),
	.addr      (mem_addr[26:2]),
	.be        (mem_be),
	.wdata     (mem_wdata),
	.ack       (sdr_ack),
	.rdata     (sdr_rdata),
	.busy      (),                       // ordering is the bridge's own affair

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
	.SDRAM_CLK (SDRAM_CLK)
);

//////////////////////////////////////////////////////////////////
// VRAM — on-chip, true dual port: CPU beats on port A (2-cycle
// handshake: capture, then deliver), DAFB scanout on port B with the
// registered 1-cycle read the machine expects.
//
// The machine's 2 MB window aliases mod 512 KB, so a ROM size probe sees
// the classic power-of-2 wrap and ADVERTISES 512 KB.  Backing all of it
// is impossible on this device — but it does not have to be backed
// densely; see the compaction note on VRAM_WORDS below.
//////////////////////////////////////////////////////////////////
// STRIDE COMPACTION.  The ROM programs a 1024-byte row pitch (confirmed on
// hardware and by the sim's [DAFB] tap), so a 480-row framebuffer spans
// 0x1000 + 480*1024 = 495,616 bytes — far past anything M10K can hold, and
// the old fold aliased screen rows 304..479 back onto rows 100..275 (the
// duplicated boot floppy seen on the DE10).
//
// But at 640 pixels wide only the FIRST 640 bytes of each 1024-byte row are
// ever visible: 80 bytes at 1bpp, 160 at 2bpp, 320 at 4bpp, 640 at 8bpp.
// The remaining 384 bytes are pitch padding no supported depth reaches.  So
// store 640 bytes of every row and drop the tail: the whole 512 KB window
// becomes 512*640 = 320 KB of BRAM, which fits with room to spare, and
// EVERY row of EVERY depth (8bpp included) is backed exactly once — no
// aliasing anywhere in the visible framebuffer.
//
// The 384-byte tails all share one scratch block, so a write and read-back
// at the same tail address still agree (VRAM size probes poke row-aligned
// offsets, which are all col 0).  Only software genuinely storing data in
// the pitch padding of two different rows at once would notice.
//
// Compaction assumes the 1024-byte pitch, so it engages only when the
// driver has actually programmed one; any pitch <= 640 already fits the
// array linearly and maps identically (with the old fold as a backstop for
// probe reads past the end).
localparam VRAM_WORDS = 82016;             // 320.4 KB: 512*160 + 96 tail
localparam [16:0] VRAM_FOLD = 17'd52224;   // 204 KB, in words
localparam [16:0] VRAM_TAIL = 17'd81920;   // 512 rows * 160 words

wire vram_compact = (vid_stride == 14'd1024);

function [16:0] vram_map(input [16:0] w);  // window word -> storage word
	reg [8:0] row;                         // 1024 B = 256 words per row
	reg [7:0] col;
	begin
		row = w[16:8];
		col = w[7:0];
		if (!vram_compact)
			vram_map = (w >= VRAM_WORDS) ? (w - VRAM_FOLD) : w;
		else if (col < 8'd160)             // visible 640 bytes: row*160 + col
			vram_map = {row, 7'd0} + {2'd0, row, 5'd0} + {9'd0, col};
		else                               // pitch padding: shared scratch
			vram_map = VRAM_TAIL + {9'd0, (col - 8'd160)};
	end
endfunction

reg [31:0] vram_qa;
reg        vram_ph;                        // port-A phase: 0 capture, 1 deliver

wire [16:0]  va_addr     = vram_map(mem_addr[18:2]);
wire [16:0]  vb_addr     = vram_map(vid_addr[18:2]);
wire         va_we       = mem_req && mem_is_vram && mem_write && !vram_ph;

// Storage is one byte-wide array per lane rather than one 32-bit array
// with byte enables: mem_be becomes each lane's write enable, so nothing
// rests on Quartus inferring byte enables on a true-dual-port M10K, and a
// x8 two-read-port array is the simplest shape a block can take.
// no_rw_check is accurate here — port A throws its read away on a write
// cycle (vram_ph delivers on the FOLLOWING cycle), so the
// read-during-write value is a genuine don't-care.  Without these
// attributes Quartus honors the implied "old data" same-port
// read-during-write in logic cells, and 2.5 Mbit of registers is what
// turns Analysis & Synthesis into an all-day run that never finishes.
(* ramstyle = "M10K, no_rw_check" *) reg [7:0] vram0 [0:VRAM_WORDS-1];
(* ramstyle = "M10K, no_rw_check" *) reg [7:0] vram1 [0:VRAM_WORDS-1];
(* ramstyle = "M10K, no_rw_check" *) reg [7:0] vram2 [0:VRAM_WORDS-1];
(* ramstyle = "M10K, no_rw_check" *) reg [7:0] vram3 [0:VRAM_WORDS-1];

always @(posedge clk_sys) begin            // port A: CPU beats
	if (va_we && mem_be[0]) vram0[va_addr] <= mem_wdata[7:0];
	if (va_we && mem_be[1]) vram1[va_addr] <= mem_wdata[15:8];
	if (va_we && mem_be[2]) vram2[va_addr] <= mem_wdata[23:16];
	if (va_we && mem_be[3]) vram3[va_addr] <= mem_wdata[31:24];
	vram_qa <= {vram3[va_addr], vram2[va_addr],
	            vram1[va_addr], vram0[va_addr]};
end

// port B: DAFB scanout, on the PIXEL clock.  M10K is natively dual-clock, so
// this costs nothing and there is no timed arc between the ports -- the
// crossing is blessed in MacQuadra800.sdc along with the rest of clk_vid.
always @(posedge clk_vid)
	vid_rdata <= {vram3[vb_addr], vram2[vb_addr],
	              vram1[vb_addr], vram0[vb_addr]};

//////////////////////////////////////////////////////////////////
// DDR3 bridge — RAM + ROM regions, plus the boot.rom upload path.
// 64-bit word convention: the machine's 32-bit word at byte address A
// sits in DDRAM_DOUT[31:0] when A[2]=0 and [63:32] when A[2]=1; the
// big-endian byte packing inside the 32-bit lane is preserved, so
// mem_be maps 1:1 onto DDRAM_BE (shifted by the half-select).
//////////////////////////////////////////////////////////////////
assign DDRAM_CLK = clk_sys;

localparam [28:0] DDR_RAM_BASE = 29'h0600_0000;   // byte 0x3000_0000 >> 3
localparam [28:0] DDR_ROM_BASE = 29'h0700_0000;   // byte 0x3800_0000 >> 3

reg  [7:0] ddram_burstcnt;
reg [28:0] ddram_addr;
reg [63:0] ddram_din;
reg  [7:0] ddram_be;
reg        ddram_we, ddram_rd;
assign DDRAM_BURSTCNT = ddram_burstcnt;
assign DDRAM_ADDR     = ddram_addr;
assign DDRAM_DIN      = ddram_din;
assign DDRAM_BE       = ddram_be;
assign DDRAM_WE       = ddram_we;
assign DDRAM_RD       = ddram_rd;

reg        ioctl_pend;
reg [26:0] ioctl_a;
reg [15:0] ioctl_d;
reg        ddr_wait_data;                  // read issued, awaiting DOUT_READY
reg        ddr_rd_hi;

always @(posedge clk_sys) begin
	mem_ack_r <= 0;

	// boot.rom halfwords: capture, then stall hps_io until written
	if (ioctl_download && rom_index && ioctl_wr) begin
		ioctl_pend <= 1;
		ioctl_wait <= 1;
		ioctl_a <= ioctl_addr;
		ioctl_d <= ioctl_dout;
	end

	if (!DDRAM_BUSY) begin
		ddram_we <= 0;
		ddram_rd <= 0;
	end

	// VRAM beats (BRAM port A): capture edge, then deliver vram_qa
	if (mem_req && !mem_ack && mem_is_vram) begin
		if (!vram_ph) vram_ph <= 1;
		else begin
			vram_ph <= 0;
			mem_rdata_r <= vram_qa;
			mem_ack_r <= 1;
		end
	end

	if (ddr_wait_data) begin
		if (DDRAM_DOUT_READY) begin
			mem_rdata_r <= ddr_rd_hi ? DDRAM_DOUT[63:32] : DDRAM_DOUT[31:0];
			mem_ack_r   <= 1;
			ddr_wait_data <= 0;
		end
	end
	else if (!DDRAM_BUSY && !ddram_we && !ddram_rd) begin
		if (ioctl_pend) begin
			// file bytes are big-endian in the 32-bit lane: swap the
			// little-endian ioctl halfword and replicate across lanes,
			// steering with BE
			ddram_addr     <= DDR_ROM_BASE | {10'd0, ioctl_a[19:3]};
			ddram_din      <= {4{{ioctl_d[7:0], ioctl_d[15:8]}}};
			ddram_be       <= ioctl_a[1] ? (ioctl_a[2] ? 8'h30 : 8'h03)
			                             : (ioctl_a[2] ? 8'hC0 : 8'h0C);
			ddram_burstcnt <= 8'd1;
			ddram_we       <= 1;
			ioctl_pend     <= 0;
			ioctl_wait     <= 0;
		end
		else if (mem_req && !mem_ack && mem_is_rom) begin
			if (mem_write) begin
				mem_ack_r <= 1;            // djMEMC discards ROM writes
			end
			else begin
				ddram_addr     <= DDR_ROM_BASE | {12'd0, mem_addr[19:3]};
				ddram_burstcnt <= 8'd1;
				ddram_rd       <= 1;
				ddr_rd_hi      <= mem_addr[2];
				ddr_wait_data  <= 1;
			end
		end
		// RAM beats are sdram_beat32's; nothing here gates them, so a RAM
		// access never waits on the DDR3 side of this block.
	end

	if (reset && !ioctl_download) begin
		vram_ph <= 0;
		ddr_wait_data <= 0;
	end
	if (RESET) begin
		ioctl_pend <= 0;
		ioctl_wait <= 0;
	end
end

endmodule
