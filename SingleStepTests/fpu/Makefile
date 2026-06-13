V       = verilator
TOP     = --top-module fpu_tests
RTL     = ../../rtl

SIM_INC = ../../verilator/sim
V_INC   = +incdir+$(RTL) +incdir+$(RTL)/mc68881

V_DEFINE = +define+SIMULATION=1 \
           -CFLAGS "-I.. -I$(SIM_INC) -g" \
           --timescale-override 1ps/1ps \
           -Wno-TIMESCALEMOD -Wno-fatal \
           -Wno-WIDTH -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-IMPLICIT \
           -Wno-PINMISSING -Wno-UNUSEDSIGNAL -Wno-UNOPTFLAT \
           -Wno-CASEINCOMPLETE -Wno-UNSIGNED -Wno-CMPCONST \
           -Wno-LATCH -Wno-UNDRIVEN -Wno-MISINDENT -Wno-COMBDLY \
           -Wno-INITIALDLY -Wno-SYNCASYNCNET -Wno-ALWNEVER

# fpu_lite is the only Verilog form available — VHDL is blocked on
# ghdl-synth limitations (see CLAUDE.md MC68881 notes).
V_SRC = \
  fpu_tests.v \
  $(RTL)/mc68881/fpu_lite/mc68881_top.v

C_SRC = sim_main.cpp \
        $(SIM_INC)/m68kdasm.c \
        $(SIM_INC)/m68k_dasm_stubs.cpp

V_OPT = --x-assign fast --x-initial fast --noassert
EXE   = ./obj_dir/Vfpu_tests
VOUT  = obj_dir/Vfpu_tests.cpp

all: $(EXE)

$(VOUT): $(V_SRC) Makefile
	$V -cc $(V_OPT) -exe --Mdir ./obj_dir $(V_DEFINE) $(V_INC) $(TOP) \
	   $(V_SRC) $(C_SRC)

$(EXE): $(VOUT) $(C_SRC)
	cd obj_dir && $(MAKE) -f Vfpu_tests.mk OBJCACHE=

run: $(EXE)
	$(EXE)

clean:
	rm -rf obj_dir
