# wombat33 — Verilator GUI simulation (same setup as the other cores'
# verilator directories: ImGui + SDL2, FST tracing, `make && ./obj_dir/Vemu`).
V = verilator

TOP = --top-module emu
RTL = ../rtl
AP  = ../rtl/ap68040/rtl
V_INC = +incdir+$(RTL) +incdir+$(AP) -I$(AP)

V_DEFINE = +define+SIMULATION=1 \
	-CFLAGS "-I../sim/imgui -I../sim/ -g" \
	--timescale-override 1ps/1ps -Wno-TIMESCALEMOD \
	-I$(RTL)
V_DEFINE += -Wno-fatal -Wno-WIDTH -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-IMPLICIT \
	-Wno-PINMISSING -Wno-UNUSEDSIGNAL -Wno-UNOPTFLAT -Wno-CASEINCOMPLETE \
	-Wno-UNSIGNED -Wno-CMPCONST -Wno-LATCH -Wno-UNDRIVEN -Wno-MISINDENT \
	-Wno-COMBDLY -Wno-INITIALDLY -Wno-SYNCASYNCNET -Wno-BLKLOOPINIT \
	-Wno-MULTIDRIVEN -Wno-GENUNNAMED
V_DEFINE += --trace-fst --timing

UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S), Linux)
	LIBS += -lGL -ldl `sdl2-config --libs`
	CXXFLAGS += `sdl2-config --cflags` -Iimgui
	CFLAGS = $(CXXFLAGS)
endif
ifeq ($(UNAME_S), Darwin)
	# homebrew: SDL2, plus lz4/zstd/zlib for verilator >=5.05x FST writer
	LIBS += -framework OpenGL `sdl2-config --libs` -L/opt/homebrew/lib -llz4 -lzstd -lz
	CXXFLAGS += `sdl2-config --cflags` -I/opt/homebrew/include -Iimgui -DGL_SILENCE_DEPRECATION
	CFLAGS = $(CXXFLAGS)
endif

CFLAGS += -Iimgui
LDFLAGS = $(LIBS)
EXE = ./obj_dir/Vemu
V_OPT = --x-assign fast --x-initial fast --noassert

# Core RTL under simulation: the quadra800 machine (AP68040 submodule +
# wombat glue) plus the template pattern core, which still paces frames
# and paints the VGA window until DAFB lands.
V_SRC = \
	sim.v \
	$(RTL)/mycore.v \
	$(RTL)/cos.sv \
	sim_lfsr.v \
	$(RTL)/quadra800.sv \
	$(RTL)/wombat_cpu.sv \
	$(RTL)/wombat_bus32.sv \
	$(RTL)/iosb.sv \
	$(RTL)/via6522.sv \
	$(RTL)/dafb.sv \
	$(RTL)/rtc3430042.sv \
	$(RTL)/easc.sv \
	$(RTL)/ncr53c96.sv \
	$(RTL)/adb.sv \
	$(RTL)/scc.v \
	$(RTL)/uart/txuart.v \
	$(RTL)/uart/rxuart.v \
	$(AP)/ap040_core.v \
	$(AP)/ap040_bus_timeout.v \
	$(AP)/ap040_regfile.v \
	$(AP)/ap040_alu.v \
	$(AP)/ap040_muldiv.v \
	$(AP)/ap040_mmu.v \
	$(AP)/ap040_cache.v \
	$(AP)/ap040_fpu.v \
	$(RTL)/dpram.v

C_SRC = \
	sim_main.cpp \
	sim/sim_console.cpp sim/sim_video.cpp sim/sim_input.cpp sim/sim_clock.cpp \
	sim/sim_audio.cpp sim/sim_blkdevice.cpp \
	sim/m68kdasm.c sim/m68k_dasm_stubs.cpp \
	sim/imgui/imgui_impl_sdl.cpp sim/imgui/imgui_impl_opengl2.cpp \
	sim/imgui/imgui_draw.cpp sim/imgui/imgui_widgets.cpp \
	sim/imgui/imgui_tables.cpp sim/imgui/imgui.cpp \
	sim/imgui/ImGuiFileDialog.cpp sim/imgui/implot.cpp sim/imgui/implot_items.cpp

VOUT = obj_dir/Vemu.cpp

all: $(EXE) quadra800.rom.hex

# ROM image as $readmemh words (big-endian: file order = byte order)
quadra800.rom.hex: ../releases/quadra800.rom
	xxd -p -c4 $< > $@

# sim-only fast-boot ROM: NOP the RAM-test warm gate at file offset
# $47344 (docs/quadra800-ram-test.md) so the ~1.5G-cycle pattern test
# is skipped; run with +rom=quadra800-fastboot.rom.hex
fastboot: quadra800-fastboot.rom.hex
quadra800-fastboot.rom.hex: ../releases/quadra800.rom ../docs/tools/make-fastboot-rom.sh
	sh ../docs/tools/make-fastboot-rom.sh $< .fastboot.tmp.rom
	xxd -p -c4 .fastboot.tmp.rom > $@
	rm .fastboot.tmp.rom

$(VOUT): $(V_SRC) $(C_SRC) Makefile
	$V -cc $(V_OPT) -LDFLAGS "$(LDFLAGS)" -exe --trace --Mdir ./obj_dir \
		$(V_DEFINE) $(V_INC) $(TOP) -CFLAGS "$(CFLAGS)" $(V_SRC) $(C_SRC)
	@touch $(VOUT)

$(EXE): $(VOUT)
	@# verilator's Vemu.mk has no dep tracking for our C sources: evict
	@# any object older than its source before the inner make.
	@for f in $(C_SRC); do o=obj_dir/$$(basename $${f%.*}).o; \
		[ -e $$o ] && [ $$f -nt $$o ] && rm -f $$o obj_dir/Vemu || true; done
	(cd obj_dir; make -f Vemu.mk)

# Directed unit test for the EASC (rtl/easc.sv). Runs in seconds and does not
# need a ROM or a disk, which is the point: the machine only touches the sound
# chip's FIFO billions of cycles into a boot.
#   make tb_easc && ./obj_dir_tb/tb_easc
tb_easc:
	$V --binary --timing -Wno-fatal -Wno-WIDTH -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNSIGNED -Wno-CMPCONST -Wno-DECLFILENAME +define+SIMULATION=1 --top-module tb_easc --Mdir ./obj_dir_tb -o tb_easc tb_easc.sv $(RTL)/easc.sv
	./obj_dir_tb/tb_easc

# Directed unit test for the SDRAM beat bridge (rtl/sdram_beat32.sv) and the
# controller under it, driven against a behavioural chip model. The GUI sim
# backs RAM with a plain array, so this is the only place the burst capture,
# the posted write, the two clock crossings and the chip protocol are checked.
#   make tb_sdram
tb_sdram:
	$V --binary --timing -Wno-fatal -Wno-WIDTH -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNSIGNED -Wno-CMPCONST -Wno-DECLFILENAME +define+SIMULATION=1 --top-module tb_sdram --Mdir ./obj_dir_tb -o tb_sdram tb_sdram.sv $(RTL)/sdram_beat32.sv $(RTL)/sdram.sv altddio_out_stub.v
	./obj_dir_tb/tb_sdram

# Directed unit test for the 53C96 SCSI target (rtl/ncr53c96.sv), driven in
# BOTH driver dialects: the Quadra 800 ROM's DMA-form selects and a Unix
# ncr53c9x-class driver's FIFO-preloaded $41/$42/$43/$46.  A/UX's own c94
# driver is the second kind, so this is where widening the model for it is
# checked against the ROM path that already boots Mac OS.
#   make tb_ncr53c96
tb_ncr53c96:
	$V --binary --timing -Wno-fatal -Wno-WIDTH -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNSIGNED -Wno-CMPCONST -Wno-DECLFILENAME -Wno-CASEINCOMPLETE -Wno-BLKSEQ +define+SIMULATION=1 +define+VERILATOR=1 --top-module tb_ncr53c96 --Mdir ./obj_dir_tb -o tb_ncr53c96 tb_ncr53c96.sv $(RTL)/ncr53c96.sv
	./obj_dir_tb/tb_ncr53c96

clean:
	rm -rf obj_dir obj_dir_tb
