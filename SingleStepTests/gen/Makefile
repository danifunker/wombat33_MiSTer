# Test corpus generators.
#
#   make gen_fpu          # SELF-CONTAINED 68040 FPU oracle (host IEEE math,
#                         #   no Musashi); ./gen_fpu fpu_corpus.json
#   make gen              # CPU corpus generator (links Musashi @ MUSASHI_DIR;
#                         #   alternate to the canonical MAME macqd800 capture)
#
# The MAME macqd800 captures (mame_cpu_capture.lua / mame_mmu_capture.lua)
# are the canonical CPU/MMU oracles; `gen` is an alternate that needs the
# standalone Musashi checkout (kstenerud/Musashi has M68K_CPU_TYPE_68040)
# built first so m68kops.c/h are generated:
#     make -C $(MUSASHI_DIR)
#     make gen && ./gen ../tg68k/corpus 0xC0FFEE01

MUSASHI_DIR ?= $(HOME)/repos/Musashi

CC      = gcc
CFLAGS  = -O2 -g -Wall -Wno-unused-parameter -I$(MUSASHI_DIR)

# Musashi object files (built by `make -C $(MUSASHI_DIR)`)
MUSASHI_OBJS = \
  $(MUSASHI_DIR)/m68kcpu.o \
  $(MUSASHI_DIR)/m68kops.o \
  $(MUSASHI_DIR)/m68kdasm.o \
  $(MUSASHI_DIR)/softfloat/softfloat.o

all: gen_fpu

# Self-contained FPU oracle — no Musashi, just host IEEE math.
gen_fpu: gen_fpu.c
	$(CC) -O2 -w -o $@ gen_fpu.c -lm

# Force Musashi to be built first if its .o files are missing.
$(MUSASHI_OBJS):
	$(MAKE) -C $(MUSASHI_DIR)

gen: gen.c $(MUSASHI_OBJS)
	$(CC) $(CFLAGS) -o $@ gen.c $(MUSASHI_OBJS) -lm

clean:
	rm -f gen gen_fpu

.PHONY: all clean
