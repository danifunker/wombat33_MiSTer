// wombat33 — Verilator simulation main
//
// Same framework as the other cores' verilator setups (ImGui + SDL2,
// sim_video/sim_clock/sim_input helpers, FST tracing): a control window
// with run/pause/step, the core's option bits, and the emulated screen.
// Today it drives the MiSTer template pattern core in sim.v; the AP68040
// machine drops into the same shell as bring-up proceeds.

#include <verilated.h>
#include "Vemu.h"
#include "Vemu__Syms.h"

#include "imgui.h"
#include <stdio.h>
#include <SDL.h>
#include <SDL_opengl.h>

#define VERILATOR_MAJOR_VERSION (VERILATOR_VERSION_INTEGER / 1000000)
#if VERILATOR_MAJOR_VERSION >= 5
#define VERTOPINTERN top->rootp
#else
#define VERTOPINTERN top
#endif

#include "sim_console.h"
#include "sim_video.h"
#include "sim_input.h"
#include "sim_clock.h"
#include "sim_audio.h"
#include "sim_blkdevice.h"
#include "implot.h"
#include "m68k_dasm.h"

// sim.v keeps its own module class (the public arrays force it), so its
// internals live under rootp->emu rather than flattened into root.
#define SIMEMU (top->rootp->emu)

#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "sim/stb_image_write.h"

#include <string>
#include <sstream>
#include <vector>
#include <algorithm>

// Simulation control
// ------------------
int  initialReset = 48;
bool run_enable = 1;
int  batchSize = 500000;
bool single_step = 0;
bool multi_step = 0;
int  multi_step_amount = 1024;

// Core options (mirrors the CONF_STR options in MacQuadra800.sv)
int opt_tvmode = 0;      // 0 NTSC, 1 PAL
int opt_noise = 0;       // 0 white, 1 red, 2 green, 3 blue

// Headless / scripted runs
bool headless = false;
bool screenshot_mode = false;
std::vector<int> screenshot_frames;
int  stop_at_frame = -1;
vluint64_t max_cycles = 0;      // --max-cycles N: stop after N clk edges (0 = off)
vluint64_t trace_after = 0;     // --trace-after N: suppress the cpu trace before cycle N
uint32_t stop_pc_lo = 1, stop_pc_hi = 0;   // --stop-at-pc lo,hi: exit when pc_i enters range
bool pc_was_in_stop = false;               // edge detector for the stop range

// CPU instruction trace (MacLC cpu_trace pattern, adapted to AP68040's
// pc_i register: one entry per instruction dispatch, extension words read
// straight from the sim memory arrays)
bool cpu_trace_disabled = false;      // --no-cpu-trace
bool gui_instr_log = false;           // stream instructions into the Debug log
bool gui_trace_file = true;           // trace file toggle (GUI defaults off)
bool showDebugLog = true;
FILE* cpu_trace_file = nullptr;
const char* cpu_trace_filename = "cpu_trace.log";
long cpu_trace_count = 0;
uint32_t cpu_trace_last_pc = 0xFFFFFFFF;

// Cheap long-run observability: heartbeat line + a pc histogram (one
// bucket per 256 bytes over the whole 4 GB, sampled every clock).
vluint64_t heartbeat_every = 10000000;
vluint64_t next_heartbeat = 10000000;
bool pc_hist_enable = false;    // --hist: per-cycle pc histogram (slows the sim)
static uint32_t pc_hist[1 << 24];
static uint32_t pc_hist_pc(int i) { return (uint32_t)i << 8; }

static uint16_t sim_read_word(uint32_t addr);
static void cpu_trace_step();
static void machine_events();

// Verilog module
// --------------
Vemu* top = NULL;
vluint64_t main_time = 0;
double sc_time_stamp() { return main_time; }

SimClock clk_sys(1);
SimAudio audio(33000000, false);
std::string scsi_disk_file;      // --disk <path> mounts on SCSI ID 0

DebugConsole console;
SimBlockDevice blockdevice(console);
const char* windowTitle = "wombat33 sim";
const char* windowTitle_Control = "Simulation control";
const char* windowTitle_Video = "VGA output";

// Video: template pattern is 640x480-ish; the window autosizes to the
// measured extents anyway.
SimVideo video(800, 600, 0);
float vga_scale = 1.0f;
SimInput input(12, console);

// ---- ADB mouse from clicks on the VGA image -------------------------------
// A click (or drag) on the VGA output picks a target pixel; each GUI frame
// one MiSTer-format ps2_mouse packet nudges the pointer toward it.  The ADB
// mouse is relative, so the loop is closed against the Mac's own idea of the
// pointer — the RawMouse low-memory global at $82C ({v,h} words) — which
// self-corrects for clamped or overwritten deltas.  Before the System is up
// nobody maintains RawMouse, so a target that makes no progress is dropped
// after a few dozen packets instead of being chased forever.
static bool     mouse_btn_down   = false;   // hovered-image button state
static bool     mouse_btn_sent   = false;   // last button state delivered
static bool     mouse_btn_dirty  = false;
static int      mouse_warp_x     = -1;      // target in Mac pixels (-1 = idle)
static int      mouse_warp_y     = -1;
static uint32_t mouse_strobe     = 0;       // ps2_mouse[24] toggle
static uint32_t mouse_last_raw   = 0xFFFFFFFF;
static int      mouse_stalled    = 0;

static void adb_mouse_update() {
	if (mouse_warp_x < 0 && !mouse_btn_dirty) return;

	int dx = 0, dy = 0;
	if (mouse_warp_x >= 0) {
		// RawMouse at $082C: bytes {v.hi v.lo h.hi h.lo} = one big-endian
		// RAM word, v in [31:16], h in [15:0]
		uint32_t raw = SIMEMU->ram[0x082C >> 2];
		int v = (int)(raw >> 16), h = (int)(raw & 0xFFFF);
		if (h > 2047 || v > 2047) {              // boot fill / no cursor yet
			mouse_warp_x = mouse_warp_y = -1;
		}
		else {
			dx = mouse_warp_x - h;
			dy = mouse_warp_y - v;
			if (dx == 0 && dy == 0) {
				mouse_warp_x = mouse_warp_y = -1;    // arrived
			}
			else if (raw == mouse_last_raw && ++mouse_stalled > 48) {
				mouse_warp_x = mouse_warp_y = -1;    // nobody is listening
				mouse_stalled = 0;
			}
			if (raw != mouse_last_raw) mouse_stalled = 0;
			mouse_last_raw = raw;
		}
	}
	if (mouse_warp_x < 0 && !mouse_btn_dirty) return;

	// one packet: clamp to the ADB event range so nothing is distorted
	if (dx > 63) dx = 63; else if (dx < -63) dx = -63;
	if (dy > 63) dy = 63; else if (dy < -63) dy = -63;
	int py = -dy;                                // PS/2 y is up-positive
	mouse_strobe ^= 1;
	VERTOPINTERN->ps2_mouse =
		(mouse_strobe << 24) |
		((py & 0xFF) << 16) | ((dx & 0xFF) << 8) |
		((py < 0) ? 0x20 : 0) | ((dx < 0) ? 0x10 : 0) |
		(mouse_btn_down ? 0x01 : 0);
	mouse_btn_sent = mouse_btn_down;
	mouse_btn_dirty = false;
}

// --- open-loop ADB mouse injection (bring-up) -----------------------------
// +mousewiggle=N : emit one relative-move packet every N frames, moving the
// pointer down-and-right.  The click-to-warp path above closes its loop
// against RawMouse ($82C), which nothing maintains before a System boots, so
// it CANNOT exercise the ADB mouse at the flashing-? screen — which is
// exactly where the hardware sits.  This path is unconditional, needs no
// System, and runs headless (adb_mouse_update() is GUI-only).
static int      mouse_wiggle = 0;
static uint64_t mouse_wiggle_last = ~0ull;

// The wiggle also CLICKS: it holds the button down for a run of reports, then
// releases for a run.  Motion-only wiggling cannot reproduce the hardware
// symptom where mouse movement works but button presses never take effect --
// the button is bit 0 of ps2_mouse, carried in the same report as the deltas
// and returned in the same ADB byte (adb.sv: response[0] = {~mouseButton, dy}).
// +mousebtn=N sets the hold/release run length in wiggle events; 0 disables.
static int mouse_btn_period = 0;
static int mouse_wiggle_n   = 0;

static void adb_mouse_wiggle(uint64_t frame) {
	if (!mouse_wiggle) return;
	if (frame == mouse_wiggle_last || (frame % (unsigned)mouse_wiggle)) return;
	mouse_wiggle_last = frame;
	const int dx = 8, py = -8;              // right, and down (PS/2 y is up+)
	int btn = 0;
	if (mouse_btn_period > 0)
		btn = ((mouse_wiggle_n / mouse_btn_period) & 1) ? 1 : 0;
	mouse_wiggle_n++;
	mouse_strobe ^= 1;
	VERTOPINTERN->ps2_mouse =
		(mouse_strobe << 24) |
		((py & 0xFF) << 16) | ((dx & 0xFF) << 8) |
		((py < 0) ? 0x20 : 0) | ((dx < 0) ? 0x10 : 0) |
		(btn ? 0x01 : 0);
}

static void save_screenshot(int frame) {
	char filename[64];
	snprintf(filename, sizeof(filename), "screenshot_f%d.png", frame);
	stbi_write_png(filename, output_width, output_height, 4, output_ptr,
	               output_width * 4);
	printf("Saved %s (%dx%d)\n", filename, output_width, output_height);
}

int verilate() {
	if (!Verilated::gotFinish()) {
		if (main_time < (vluint64_t)initialReset) VERTOPINTERN->reset = 1;
		if (main_time == (vluint64_t)initialReset) VERTOPINTERN->reset = 0;

		clk_sys.Tick();
		VERTOPINTERN->clk_sys = clk_sys.clk;
		VERTOPINTERN->sim_status =
			((opt_tvmode & 1) << 2) | ((opt_noise & 3) << 3);

		if (clk_sys.clk != clk_sys.old) {
			if (clk_sys.clk) {
				input.BeforeEval();
				if (!scsi_disk_file.empty()) blockdevice.BeforeEval(main_time);
			}
			top->eval();
			if (clk_sys.clk && !scsi_disk_file.empty()) blockdevice.AfterEval();
			if (clk_sys.clk && !VERTOPINTERN->reset) {
				machine_events();
				if (!cpu_trace_disabled && main_time >= trace_after) cpu_trace_step();
				uint32_t hpc = SIMEMU->__PVT__machine__DOT__cpu__DOT__core__DOT__pc_i;
				if (pc_hist_enable) pc_hist[hpc >> 8]++;
				{
					// RAM write watchpoints: DrvQHdr + the DrvQEl at $B94E
					static const uint32_t watch_addr[] =
						{ 0x308, 0x30C, 0xB948, 0xB94C, 0xB950, 0xB954, 0xB958, 0xB95C };
					static uint32_t watch_prev[8];
					static bool watch_init = false;
					for (int w = 0; w < 8; w++) {
						uint32_t cur = SIMEMU->ram[watch_addr[w] >> 2];
						if (watch_init && cur != watch_prev[w]) {
							printf("[WATCH] %05X: %08X -> %08X pc=%08X cycle=%llu\n",
							       watch_addr[w], watch_prev[w], cur, hpc,
							       (unsigned long long)main_time);
							fflush(stdout);
						}
						watch_prev[w] = cur;
					}
					watch_init = true;
				}
				// edge-triggered: fire on entering the range, so RUN can
				// resume through it without an instant re-stop
				bool pc_in_stop = (hpc >= stop_pc_lo && hpc <= stop_pc_hi);
				if (pc_in_stop && !pc_was_in_stop) {
					printf("[STOP] pc=%08X at cycle %llu\n", hpc,
					       (unsigned long long)main_time);
					for (int r = 0; r < 8; r++)
						printf("[STOP] d%d=%08X a%d=%08X\n", r,
						       SIMEMU->__PVT__machine__DOT__cpu__DOT__core__DOT__regfile__DOT__dreg[r], r,
						       SIMEMU->__PVT__machine__DOT__cpu__DOT__core__DOT__regfile__DOT__areg[r]);
					printf("[STOP] DSErrCode($AF0)=%04X\n",
					       SIMEMU->ram[0x0AF0 >> 2] >> 16);
					{
						// dump the Drive Queue (DrvQHdr $308): big-endian
						// words packed {b0b1,b2b3} per 32-bit RAM word
						auto r16 = [](uint32_t a) -> uint32_t {
							uint32_t w = SIMEMU->ram[a >> 2];
							return (a & 2) ? (w & 0xFFFF) : (w >> 16);
						};
						auto r32 = [&](uint32_t a) -> uint32_t {
							return (r16(a) << 16) | r16(a + 2);
						};
						uint32_t qh = r32(0x30A);
						printf("[STOP] DrvQHdr qFlags=%04X qHead=%08X qTail=%08X\n",
						       r16(0x308), qh, r32(0x30E));
						for (int n = 0; n < 8 && qh; n++) {
							if (qh >= (32u << 20) || (qh & 1)) {
								printf("[STOP]  node %08X outside RAM\n", qh);
								break;
							}
							printf("[STOP]  DrvQEl@%08X qLink=%08X qType=%04X"
							       " dQDrive=%04X dQRefNum=%04X dQFSID=%04X\n",
							       qh, r32(qh), r16(qh + 4), r16(qh + 6),
							       r16(qh + 8), r16(qh + 10));
							qh = r32(qh);
						}
					}
					fflush(stdout);
					if (cpu_trace_file) fflush(cpu_trace_file);
					run_enable = 0;              // park the RUN checkbox
					Verilated::gotFinish(true);  // halt exactly here
				}
				pc_was_in_stop = pc_in_stop;
				if (main_time >= next_heartbeat) {
					next_heartbeat += heartbeat_every;
					printf("[HB] cycle=%llu pc=%08X instr=%ld a3=%08X d7=%08X\n",
					       (unsigned long long)main_time, hpc, cpu_trace_count,
					       SIMEMU->__PVT__machine__DOT__cpu__DOT__core__DOT__regfile__DOT__areg[3],
					       SIMEMU->__PVT__machine__DOT__cpu__DOT__core__DOT__regfile__DOT__dreg[7]);
					fflush(stdout);
				}
			}
		}

		if (clk_sys.IsRising() && !headless)
			audio.Clock(VERTOPINTERN->AUDIO_L, VERTOPINTERN->AUDIO_R);

		if (clk_sys.IsRising() && VERTOPINTERN->CE_PIXEL) {
			uint32_t colour = 0xFF000000 |
				(VERTOPINTERN->VGA_B << 16) |
				(VERTOPINTERN->VGA_G << 8) |
				 VERTOPINTERN->VGA_R;
			video.Clock(VERTOPINTERN->VGA_HB, VERTOPINTERN->VGA_VB,
			            VERTOPINTERN->VGA_HS, VERTOPINTERN->VGA_VS, colour);
		}

		main_time++;
		return 1;
	}
	return 0;
}

// sim.v keeps its own module class (the public arrays force it), so its
// internals live under rootp->emu rather than flattened into root.
// Physical-address word read mirroring the quadra800 decode.  Valid while
// the CPU runs untranslated (all of ROM startup); once the MMU is on,
// pc_i is logical and entries for non-identity mappings would misread.
static uint16_t sim_read_word(uint32_t addr) {
	uint32_t word;
	bool overlay = VERTOPINTERN->debug_overlay;
	if ((addr >> 28) == 4 || (overlay && addr < 0x400000))
		word = SIMEMU->rom[(addr & 0xFFFFF) >> 2];
	else if (addr < 0x800000)
		word = SIMEMU->ram[addr >> 2];
	else if (addr >= 0xF9000000 && addr < 0xF9200000)
		word = SIMEMU->vram[(addr & 0xFFFFF) >> 2];
	else
		return 0;
	return (addr & 2) ? (uint16_t)word : (uint16_t)(word >> 16);
}

// One trace line per instruction dispatch: pc_i changed inside the core.
static void cpu_trace_step() {
	uint32_t pc = SIMEMU->__PVT__machine__DOT__cpu__DOT__core__DOT__pc_i;
	if (pc == cpu_trace_last_pc) return;
	cpu_trace_last_pc = pc;

	unsigned short opwords[5];
	for (int k = 0; k < 5; k++) opwords[k] = sim_read_word(pc + 2*k);
	unsigned int len = 2;
	const char* disasm = disassemble_68k_ext_len(pc, opwords, 5, &len);
	cpu_trace_count++;
	if (cpu_trace_file && gui_trace_file)
		fprintf(cpu_trace_file, "%08X: %04X  %s\n", pc, opwords[0], disasm);
	if (gui_instr_log)
		console.AddLog("%08X: %04X  %s", pc, opwords[0], disasm);
}

// Bus errors (coalesced per address), overlay switch, core fault/halt.
static void machine_events() {
	static int last_overlay = -1;
	static uint32_t berr_addr = 0xFFFFFFFF;
	static long berr_repeat = 0;
	static int last_fault = 0, last_halted = 0;

	int ov = VERTOPINTERN->debug_overlay;
	if (ov != last_overlay) {
		if (last_overlay != -1 || !ov)
		{
			printf("[MACHINE] overlay %s at cycle %llu\n", ov ? "set" : "cleared",
			       (unsigned long long)main_time);
			console.AddLog("[MACHINE] overlay %s at cycle %llu", ov ? "set" : "cleared",
			       (unsigned long long)main_time);
		}
		last_overlay = ov;
	}

	if (VERTOPINTERN->debug_berr) {
		uint32_t addr = VERTOPINTERN->debug_data_addr;
		if (addr == berr_addr) {
			berr_repeat++;
		} else {
			if (berr_repeat > 1)
				printf("[BERR] %08X repeated x%ld\n", berr_addr, berr_repeat);
			printf("[BERR] addr=%08X pc=%08X cycle=%llu\n", addr,
			       (unsigned)VERTOPINTERN->debug_pc, (unsigned long long)main_time);
			console.AddLog("[BERR] addr=%08X pc=%08X", addr,
			       (unsigned)VERTOPINTERN->debug_pc);
			if (cpu_trace_file)
				fprintf(cpu_trace_file, "[BERR] addr=%08X\n", addr);
			berr_addr = addr;
			berr_repeat = 1;
		}
	}

	int fault = VERTOPINTERN->debug_cpu_fault;
	int halted = VERTOPINTERN->debug_cpu_halted;
	if (halted && !last_halted)
		printf("[LOWMEM] $108=%08X $10C=%08X $2A6=%08X $CFC=%08X\n",
		       SIMEMU->ram[0x108>>2], SIMEMU->ram[0x10C>>2],
		       SIMEMU->ram[0x2A4>>2], SIMEMU->ram[0xCFC>>2]);
	if ((fault && !last_fault) || (halted && !last_halted))
	{
		printf("[MACHINE] %s at cycle %llu pc=%08X\n",
		       halted ? "CPU HALTED (double fault)" : "fault",
		       (unsigned long long)main_time, (unsigned)VERTOPINTERN->debug_pc);
		console.AddLog("[MACHINE] %s pc=%08X",
		       halted ? "CPU HALTED (double fault)" : "fault",
		       (unsigned)VERTOPINTERN->debug_pc);
	}
	last_fault = fault; last_halted = halted;
}

int main(int argc, char** argv, char** env) {
	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--headless") || !strcmp(argv[i], "--no-gui")) {
			headless = true;
		} else if (!strcmp(argv[i], "--no-cpu-trace")) {
			cpu_trace_disabled = true;
		} else if (!strcmp(argv[i], "--max-cycles") && i + 1 < argc) {
			max_cycles = strtoull(argv[++i], nullptr, 0);
		} else if (!strcmp(argv[i], "--trace-after") && i + 1 < argc) {
			trace_after = strtoull(argv[++i], nullptr, 0);
		} else if (!strcmp(argv[i], "--stop-at-pc") && i + 1 < argc) {
			sscanf(argv[++i], "%x,%x", &stop_pc_lo, &stop_pc_hi);
		} else if (!strcmp(argv[i], "--disk") && i + 1 < argc) {
			scsi_disk_file = argv[++i];
		} else if (!strncmp(argv[i], "+mousewiggle=", 13)) {
			mouse_wiggle = atoi(argv[i] + 13);
		} else if (!strncmp(argv[i], "+mousebtn=", 10)) {
			mouse_btn_period = atoi(argv[i] + 10);
		} else if (!strcmp(argv[i], "--hist")) {
			pc_hist_enable = true;
		} else if (!strcmp(argv[i], "--screenshot") && i + 1 < argc) {
			screenshot_mode = true;
			std::stringstream ss(argv[++i]);
			std::string n;
			while (std::getline(ss, n, ',')) screenshot_frames.push_back(std::stoi(n));
		} else if (!strcmp(argv[i], "--stop-at-frame") && i + 1 < argc) {
			stop_at_frame = std::stoi(argv[++i]);
		} else if (!strcmp(argv[i], "-h") || !strcmp(argv[i], "--help")) {
			printf("wombat33 sim: [--headless] [--screenshot F1,F2,..] [--stop-at-frame N]\n"
			       "              [--no-cpu-trace] [--max-cycles N] [+rom=<hexfile>]\n");
			return 0;
		}
	}

	// The interactive GUI must not fill the disk behind the user's back:
	// the trace file starts enabled only for headless runs — unless a
	// debug window was explicitly requested on the command line.
	gui_trace_file = headless || trace_after != 0;
	if (!cpu_trace_disabled) {
		cpu_trace_file = fopen(cpu_trace_filename, "w");
		if (!cpu_trace_file) { cpu_trace_disabled = true; }
	}

	top = new Vemu();
	Verilated::commandArgs(argc, argv);
	Verilated::traceEverOn(true);

	VERTOPINTERN->clk_sys = 0;
	VERTOPINTERN->reset = 1;
	VERTOPINTERN->ps2_key = 0;
	VERTOPINTERN->ps2_mouse = 0;
	VERTOPINTERN->ioctl_download = 0;
	VERTOPINTERN->ioctl_wr = 0;
	VERTOPINTERN->ioctl_addr = 0;
	VERTOPINTERN->ioctl_dout = 0;
	VERTOPINTERN->ioctl_index = 0;
	top->eval();

	blockdevice.sd_lba[0]      = &VERTOPINTERN->sd_lba0;
	blockdevice.sd_rd          = &VERTOPINTERN->sd_rd;
	blockdevice.sd_wr          = &VERTOPINTERN->sd_wr;
	blockdevice.sd_ack         = &VERTOPINTERN->sd_ack;
	blockdevice.sd_buff_addr   = &VERTOPINTERN->sd_buff_addr;
	blockdevice.sd_buff_dout   = &VERTOPINTERN->sd_buff_dout;
	blockdevice.sd_buff_din[0] = &VERTOPINTERN->sd_buff_din0;
	blockdevice.sd_buff_wr     = &VERTOPINTERN->sd_buff_wr;
	blockdevice.img_mounted    = &VERTOPINTERN->img_mounted;
	blockdevice.img_readonly   = &VERTOPINTERN->img_readonly;
	blockdevice.img_size       = &VERTOPINTERN->img_size;
	if (!scsi_disk_file.empty()) blockdevice.MountDisk(scsi_disk_file, 0);

	input.Initialise();
	if (!headless) {
		audio.Initialise();
		if (video.Initialise(windowTitle) == 1) return 1;
	} else {
		// video.Initialise allocates the pixel buffer; headless runs skip
		// the SDL window but still render into the buffer for screenshots.
		// The sim_video globals default to 512x512 until Initialise: size
		// them from the SimVideo instance so frames are not clipped.
		extern unsigned int output_size;
		output_width = video.output_width;
		output_height = video.output_height;
		output_size = output_width * output_height * 4;
		output_ptr = (uint32_t*)calloc(1, output_size);
	}

	bool done = false;
	while (!done) {
		if (!headless) {
			SDL_Event event;
			while (SDL_PollEvent(&event)) {
				ImGui_ImplSDL2_ProcessEvent(&event);
				if (event.type == SDL_QUIT) done = true;
			}

			video.StartFrame();
			input.Read();

			ImGui::NewFrame();
			ImGui::Begin(windowTitle_Control);
			ImGui::SetWindowPos(windowTitle_Control, ImVec2(0, 0), ImGuiCond_Once);
			ImGui::SetWindowSize(windowTitle_Control, ImVec2(500, 230), ImGuiCond_Once);
			if (ImGui::Button("Reset simulation")) { main_time = 0; }
			ImGui::SameLine();
			if (ImGui::Button("Reset core")) {
				VERTOPINTERN->reset = 1;
				for (int i = 0; i < 8; i++) verilate();
				VERTOPINTERN->reset = 0;
			}
			ImGui::Checkbox("RUN", &run_enable);
			ImGui::SameLine();
			ImGui::Checkbox("Instr log", &gui_instr_log);
			ImGui::SameLine();
			ImGui::Checkbox("Trace file", &gui_trace_file);
			ImGui::SliderInt("Batch size", &batchSize, 1000, 1000000);
			if (single_step) single_step = 0;
			if (ImGui::Button("Single step")) single_step = 1;
			ImGui::SameLine();
			if (multi_step) multi_step = 0;
			if (ImGui::Button("Multi step")) multi_step = 1;
			ImGui::SameLine();
			ImGui::SliderInt("Steps", &multi_step_amount, 8, 1024);
			ImGui::Separator();
			ImGui::Text("Frame %06d  %.1f fps  %dx%d", video.count_frame,
			            video.stats_fps, video.stats_xMax - video.stats_xMin + 1,
			            video.stats_yMax - video.stats_yMin + 1);
			ImGui::End();

			// Machine panel: system info + live CPU state
			ImGui::Begin("Machine");
			ImGui::SetWindowPos("Machine", ImVec2(0, 240), ImGuiCond_Once);
			ImGui::SetWindowSize("Machine", ImVec2(500, 330), ImGuiCond_Once);
			{
				uint32_t pc  = SIMEMU->__PVT__machine__DOT__cpu__DOT__core__DOT__pc_i;
				uint16_t ir  = VERTOPINTERN->debug_opcode;
				uint16_t sr  = VERTOPINTERN->debug_sr;
				auto &ds = SIMEMU->__PVT__machine__DOT__cpu__DOT__core__DOT__regfile__DOT__dreg;
				auto &as = SIMEMU->__PVT__machine__DOT__cpu__DOT__core__DOT__regfile__DOT__areg;
				ImGui::Text("Quadra 800 — 68040 @ 33 MHz, 32 MB RAM, 1 MB ROM, 1 MB VRAM");
				ImGui::Text("640x480, 256 colors max (DAFB II)");
				ImGui::Text("overlay=%d  cycle=%llu  instr=%ld",
				            (int)VERTOPINTERN->debug_overlay,
				            (unsigned long long)main_time, cpu_trace_count);
				ImGui::Separator();
				unsigned short opw[5];
				for (int k = 0; k < 5; k++) opw[k] = sim_read_word(pc + 2*k);
				unsigned int dlen = 2;
				ImGui::Text("PC %08X  IR %04X  SR %04X  %s", pc, ir, sr,
				            disassemble_68k_ext_len(pc, opw, 5, &dlen));
				for (int r = 0; r < 8; r += 4)
					ImGui::Text("D%d %08X  D%d %08X  D%d %08X  D%d %08X",
					            r, ds[r], r+1, ds[r+1], r+2, ds[r+2], r+3, ds[r+3]);
				ImGui::Text("A0 %08X  A1 %08X  A2 %08X  A3 %08X",
				            as[0], as[1], as[2], as[3]);
				ImGui::Text("A4 %08X  A5 %08X  A6 %08X  A7 %08X",
				            as[4], as[5], as[6],
				            (uint32_t)VERTOPINTERN->debug_a7);
				ImGui::Separator();
				ImGui::TextDisabled("SCC / SCSI / floppy / ADB panels arrive with their devices");
			}
			ImGui::End();

			console.Draw("Debug log", &showDebugLog, ImVec2(500, 400));
			ImGui::SetWindowPos("Debug log", ImVec2(0, 580), ImGuiCond_Once);

			ImGui::Begin("Audio output");
			ImGui::SetWindowPos("Audio output", ImVec2(510, 540), ImGuiCond_Once);
			ImGui::SetWindowSize("Audio output", ImVec2(680, 250), ImGuiCond_Once);
			{
				audio.CollectDebug((signed short)VERTOPINTERN->AUDIO_L,
				                   (signed short)VERTOPINTERN->AUDIO_R);
				float channelWidth = 320.0f;
				ImPlot::CreateContext();
				if (ImPlot::BeginPlot("Audio - L", ImVec2(channelWidth, 220),
				        ImPlotFlags_NoLegend | ImPlotFlags_NoMenus | ImPlotFlags_NoTitle)) {
					ImPlot::PlotStairs("", audio.debug_positions, audio.debug_wave_l,
					                   audio.debug_max_samples, audio.debug_pos);
					ImPlot::EndPlot();
				}
				ImGui::SameLine();
				if (ImPlot::BeginPlot("Audio - R", ImVec2(channelWidth, 220),
				        ImPlotFlags_NoLegend | ImPlotFlags_NoMenus | ImPlotFlags_NoTitle)) {
					ImPlot::PlotStairs("", audio.debug_positions, audio.debug_wave_r,
					                   audio.debug_max_samples, audio.debug_pos);
					ImPlot::EndPlot();
				}
				ImPlot::DestroyContext();
			}
			ImGui::End();

			ImGui::Begin(windowTitle_Video);
			ImGui::SetWindowPos(windowTitle_Video, ImVec2(510, 0), ImGuiCond_Once);
			ImGui::SetWindowSize(windowTitle_Video,
				ImVec2(video.output_width * vga_scale + 24,
				       video.output_height * vga_scale + 46), ImGuiCond_Once);
			ImGui::SliderFloat("Zoom", &vga_scale, 0.5, 4.0);
			ImGui::Image(video.texture_id,
				ImVec2(video.output_width * vga_scale,
				       video.output_height * vga_scale));
			// clicks/drags on the image drive the ADB mouse: the click
			// point becomes the warp target; button state rides along
			if (ImGui::IsItemHovered()) {
				bool down = ImGui::IsMouseDown(ImGuiMouseButton_Left);
				if (down || ImGui::IsMouseReleased(ImGuiMouseButton_Left)) {
					ImVec2 rmin = ImGui::GetItemRectMin();
					ImVec2 mp = ImGui::GetMousePos();
					mouse_warp_x = (int)((mp.x - rmin.x) / vga_scale);
					mouse_warp_y = (int)((mp.y - rmin.y) / vga_scale);
					mouse_stalled = 0;
				}
				if (down != mouse_btn_sent) {
					mouse_btn_down = down;
					mouse_btn_dirty = true;
				}
			}
			else if (mouse_btn_sent) {
				// pointer left the image with the button down: release it
				mouse_btn_down = false;
				mouse_btn_dirty = true;
			}
			ImGui::End();

			adb_mouse_update();
			video.UpdateTexture();
		}

		adb_mouse_wiggle(video.count_frame);

		if (screenshot_mode) {
			auto it = std::find(screenshot_frames.begin(), screenshot_frames.end(),
			                    (int)video.count_frame);
			if (it != screenshot_frames.end()) {
				save_screenshot(video.count_frame);
				screenshot_frames.erase(it);
			}
		}
		if (stop_at_frame >= 0 && (int)video.count_frame >= stop_at_frame) {
			printf("Reached frame %d, exiting\n", stop_at_frame);
			break;
		}
		if (max_cycles && main_time >= max_cycles) {
			printf("Reached %llu cycles, exiting\n", (unsigned long long)main_time);
			break;
		}

		// run_enable true with finish latched can only mean the user
		// re-checked RUN after a [STOP]: clear the latch and resume
		if (Verilated::gotFinish() && run_enable) Verilated::gotFinish(false);
		if (Verilated::gotFinish()) run_enable = 0;
		if (run_enable)
			for (int step = 0; step < batchSize; step++) verilate();
		else {
			if (single_step) verilate();
			if (multi_step)
				for (int step = 0; step < multi_step_amount; step++) verilate();
		}

		if (headless && Verilated::gotFinish()) done = true;
	}

	if (cpu_trace_file) {
		printf("CPU trace: %ld instructions, last pc=%08X (%s)\n",
		       cpu_trace_count, cpu_trace_last_pc, cpu_trace_filename);
		fclose(cpu_trace_file);
	}
	{
		std::vector<int> idx;
		for (int i = 0; i < (1 << 24); i++) if (pc_hist[i]) idx.push_back(i);
		std::sort(idx.begin(), idx.end(),
		          [](int a, int b) { return pc_hist[a] > pc_hist[b]; });
		printf("PC histogram (top 15 of %zu 256-byte buckets):\n", idx.size());
		for (size_t i = 0; i < idx.size() && i < 15; i++)
			printf("  %08X: %u cycles\n", pc_hist_pc(idx[i]), pc_hist[idx[i]]);
	}
	if (!headless) { audio.CleanUp(); video.CleanUp(); input.CleanUp(); }
	top->final();
	delete top;
	return 0;
}
