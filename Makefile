# =============================================================================
# Makefile: Quad-Core Out-of-Order RISC-V Processor with MESI coherence
# =============================================================================
#   make sim         Run all RTL testbenches (fails if any check fails)
#   make sim-<name>  Run one testbench (mesi arbiter cache core dep corner quad repro)
#   make isa         rv32ui riscv-tests + system tests on one core (RISCV_TESTS=<checkout>)
#   make soc-isa     the same programs on the full 4-core SoC with caches (after make isa)
#   make sw          Build the demo programs in sw/ (hello, parsum) to build/sw/
#   make soc-run PROG=hello   Run a demo program on the full SoC (UART printed)
#   make fpga-sim PROG=hello  Board-level simulation of fpga_top (UART decoded from the pin)
#   make fpga PROG=hello      Vivado bitstream for the Nexys A7-100T (CLKOUT_DIV=20: 50 MHz)
#   make program              Load build/vivado/fpga_top.bit onto the board
#   make lint        Verilator lint of the core (errors fail; warnings listed)
#   make lint-soc    Verilator lint of quad_core_top (errors fail)
#   make synth       Yosys generic synthesis of one core (fast check, used by CI)
#   make synth-soc   Yosys generic synthesis of quad_core_top
#   make synth-fpga  Yosys synth_xilinx of fpga_top (about 15 min), prints LUT/FF/BRAM
#                    use against the XC7A100T
#   make synth-fpga-core  Artix-7 LUT/FF estimate for one core (used by results)
#   make results     Regenerate docs/results/index.html (RISCV_TESTS=<checkout>)
#   make animate     MESI terminal walkthrough + animated GIF
#   make gui         Interactive MESI animation window
#   make clean       Remove build outputs
#
# Tools come from PATH. On Windows override, e.g.
#   make IVERILOG=C:/iverilog/bin/iverilog.exe VVP=C:/iverilog/bin/vvp.exe sim
# =============================================================================

IVERILOG ?= iverilog
VVP      ?= vvp
VERILATOR ?= verilator
YOSYS    ?= yosys
PYTHON   ?= python3

INC_FLAGS = -g2012 -DSIM -I rtl/core -I rtl/cache -I verif
OUT_DIR   = build
GIF_OUT   = docs/mesi_coherence_animation.gif
CHECK     = sh scripts/check_log.sh

CORE_RTL  = $(sort $(wildcard rtl/core/*.v))
CACHE_RTL = $(sort $(filter-out rtl/cache/cache_controller.v,$(wildcard rtl/cache/*.v)))
COH_RTL   = $(sort $(filter-out rtl/coherence/mesi_protocol.v,$(wildcard rtl/coherence/*.v)))
MEM_RTL   = $(sort $(wildcard rtl/memory/*.v))
IO_RTL    = $(sort $(wildcard rtl/io/*.v))
SOC_RTL   = $(CORE_RTL) $(CACHE_RTL) $(COH_RTL) $(MEM_RTL) $(IO_RTL) rtl/top/quad_core_top.v

TESTS = mesi arbiter cache core dep corner quad

.PHONY: all sim $(addprefix sim-,$(TESTS)) sim-repro isa synth soc-isa sw soc-run fpga-sim fpga program lint lint-soc synth-soc synth-fpga results animate gui clean help

all: sim

help:
	@sed -n '2,15p' Makefile

$(OUT_DIR):
	@mkdir -p $(OUT_DIR)

# run(name, sources): compile, simulate inside build/ (VCDs land there), check log
define run
	$(IVERILOG) $(INC_FLAGS) -o $(OUT_DIR)/$(1).vvp $(2)
	cd $(OUT_DIR) && $(VVP) -n $(1).vvp | tee $(1).log
	$(CHECK) $(OUT_DIR)/$(1).log
endef

sim: $(addprefix sim-,$(TESTS))
	@echo "All testbenches passed."

sim-mesi: | $(OUT_DIR)
	$(call run,mesi,rtl/coherence/mesi_protocol.v tb/tb_mesi_coherence.v)
sim-arbiter: | $(OUT_DIR)
	$(call run,arbiter,rtl/coherence/bus_arbiter.v tb/tb_bus_arbiter.v)
sim-cache: | $(OUT_DIR)
	$(call run,cache,rtl/cache/l1_dcache.v tb/tb_cache.v)
sim-core: | $(OUT_DIR)
	$(call run,core,$(CORE_RTL) tb/tb_ooo_core.v)
sim-dep: | $(OUT_DIR)
	$(call run,dep,$(CORE_RTL) tb/tb_ooo_dependent_arith.v)
sim-corner: | $(OUT_DIR)
	$(call run,corner,$(CORE_RTL) tb/tb_ooo_corner_cases.v)
sim-quad: | $(OUT_DIR)
	$(call run,quad,$(SOC_RTL) tb/tb_quad_core.v)
sim-repro: | $(OUT_DIR)
	cp review/prog.hex $(OUT_DIR)/
	$(call run,repro,$(CORE_RTL) review/tb_repro.v)

# rv32ui riscv-tests (needs riscv64-unknown-elf-gcc and a riscv-tests checkout)
RISCV_TESTS ?= ../riscv-tests
isa:
	sh verif/riscv-tests/run.sh $(RISCV_TESTS)

LINT = $(VERILATOR) --lint-only -Wall -Wno-fatal -Irtl/core -Irtl/cache
lint: | $(OUT_DIR)
	$(LINT) --top-module riscv_ooo_core $(CORE_RTL) > $(OUT_DIR)/lint.log 2>&1 || true
	@! grep "^%Error" $(OUT_DIR)/lint.log
	@echo "lint: `grep -c '^%Warning' $(OUT_DIR)/lint.log` warnings, 0 errors (see $(OUT_DIR)/lint.log)"

lint-soc: | $(OUT_DIR)
	$(LINT) --top-module quad_core_top $(SOC_RTL) > $(OUT_DIR)/lint_soc.log 2>&1 || true
	@! grep "^%Error" $(OUT_DIR)/lint_soc.log

soc-isa:
	sh scripts/soc_isa.sh

# Demo programs (C, bare metal, all four harts). Each builds to
#   build/sw/<prog>.hex       one 32-bit word per line (simulation)
#   build/sw/<prog>.line.hex  one 256-bit line per line (FPGA memory image)
RV_CC      ?= riscv64-unknown-elf-gcc
RV_OBJCOPY ?= riscv64-unknown-elf-objcopy
RV_OBJDUMP ?= riscv64-unknown-elf-objdump
RV_CFLAGS   = -march=rv32i_zicsr -mabi=ilp32 -O2 -ffreestanding -fno-builtin -nostdlib -nostartfiles \
              -Wl,--no-warn-rwx-segments -Isw/common -T sw/common/link.ld
SW_PROGS    = $(notdir $(filter-out sw/common,$(wildcard sw/*)))
PROG       ?= hello

sw: $(foreach p,$(SW_PROGS),$(OUT_DIR)/sw/$(p).line.hex)

$(OUT_DIR)/sw/%.line.hex: sw/%/*.c sw/common/*
	@mkdir -p $(OUT_DIR)/sw
	$(RV_CC) $(RV_CFLAGS) sw/common/crt0.S sw/$*/*.c -lgcc -o $(OUT_DIR)/sw/$*.elf
	$(RV_OBJDUMP) -d $(OUT_DIR)/sw/$*.elf > $(OUT_DIR)/sw/$*.dis
	$(RV_OBJCOPY) -O binary $(OUT_DIR)/sw/$*.elf $(OUT_DIR)/sw/$*.bin
	od -An -v -tx4 -w4 $(OUT_DIR)/sw/$*.bin | tr -d ' ' > $(OUT_DIR)/sw/$*.hex
	$(PYTHON) scripts/hex2line.py $(OUT_DIR)/sw/$*.hex $@

$(OUT_DIR)/soc.vvp: $(SOC_RTL) verif/soc/tb_soc.v | $(OUT_DIR)
	$(IVERILOG) $(INC_FLAGS) -o $@ $(SOC_RTL) verif/soc/tb_soc.v

# Board-level simulation of fpga_top: program baked into memory, UART decoded
# from the serial pin, 7-segment display read back from the pins
fpga-sim: $(OUT_DIR)/sw/$(PROG).line.hex
	$(IVERILOG) $(INC_FLAGS) -DNO_UART_ECHO -DMEM_INIT_FILE=\"$(OUT_DIR)/sw/$(PROG).line.hex\" -o $(OUT_DIR)/fpga_$(PROG).vvp \
	    $(SOC_RTL) rtl/top/fpga_top.v verif/soc/tb_fpga.v
	$(VVP) -n $(OUT_DIR)/fpga_$(PROG).vvp | tee $(OUT_DIR)/sw/$(PROG).fpga.log
	@grep -q "RESULT PASS" $(OUT_DIR)/sw/$(PROG).fpga.log
	@if [ -f sw/$(PROG)/expect.txt ]; then $(PYTHON) scripts/check_uart.py sw/$(PROG)/expect.txt $(OUT_DIR)/sw/$(PROG).fpga.log; fi

# Vivado build for the Nexys A7-100T (bitstream with PROG preloaded), and
# programming the board over USB (needs Vivado on PATH)
VIVADO ?= vivado
CLKOUT_DIV ?= 20
fpga: $(OUT_DIR)/sw/$(PROG).line.hex
	$(VIVADO) -mode batch -nojournal -log $(OUT_DIR)/vivado.log -source synth/build.tcl \
	    -tclargs $(OUT_DIR)/sw/$(PROG).line.hex $(CLKOUT_DIV)
program:
	$(VIVADO) -mode batch -nojournal -nolog -source synth/program.tcl -tclargs $(OUT_DIR)/vivado/fpga_top.bit

soc-run: $(OUT_DIR)/sw/$(PROG).line.hex $(OUT_DIR)/soc.vvp
	$(VVP) -n $(OUT_DIR)/soc.vvp +hex=$(OUT_DIR)/sw/$(PROG).hex | tee $(OUT_DIR)/sw/$(PROG).log
	@grep -q "RESULT PASS" $(OUT_DIR)/sw/$(PROG).log
	@if [ -f sw/$(PROG)/expect.txt ]; then $(PYTHON) scripts/check_uart.py sw/$(PROG)/expect.txt $(OUT_DIR)/sw/$(PROG).log; fi

synth: | $(OUT_DIR)
	$(YOSYS) -q -l $(OUT_DIR)/synth.log -p "read_verilog -DSYNTHESIS -I rtl/core $(CORE_RTL); synth -top riscv_ooo_core; stat"
	@! grep -E "^Latch inferred|ERROR" $(OUT_DIR)/synth.log
	@grep -A3 "design hierarchy" $(OUT_DIR)/synth.log | tail -1; grep "Number of cells" $(OUT_DIR)/synth.log | tail -1

synth-soc: | $(OUT_DIR)
	$(YOSYS) -q -l $(OUT_DIR)/synth_soc.log -p "read_verilog -DSYNTHESIS -I rtl/core -I rtl/cache $(SOC_RTL); synth -top quad_core_top; stat" 

synth-fpga: | $(OUT_DIR)
	$(YOSYS) -q -l $(OUT_DIR)/synth_fpga.log -p "read_verilog -DSYNTHESIS -I rtl/core -I rtl/cache $(SOC_RTL) rtl/top/fpga_top.v; synth_xilinx -family xc7 -top fpga_top; stat"
	@$(PYTHON) scripts/fpga_report.py $(OUT_DIR)/synth_fpga.log

results:
	sh scripts/viz/collect.sh $(RISCV_TESTS)
	$(PYTHON) scripts/viz/make_results.py build/viz docs/results/index.html

synth-fpga-core: | $(OUT_DIR)
	$(YOSYS) -q -l $(OUT_DIR)/synth_fpga_core.log -p "read_verilog -DSYNTHESIS -I rtl/core $(CORE_RTL); synth_xilinx -family xc7 -top riscv_ooo_core; stat"

animate:
	$(PYTHON) scripts/mesi_visualizer.py --verify-rtl --cli --gif $(GIF_OUT)
gui:
	$(PYTHON) scripts/mesi_visualizer.py --gui

clean:
	rm -rf $(OUT_DIR) *.vcd *.vvp
