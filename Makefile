# =============================================================================
# Makefile: Quad-Core Out-of-Order RISC-V Processor with MESI coherence
# =============================================================================
#   make sim         Run all RTL testbenches (fails if any check fails)
#   make sim-<name>  Run one testbench (mesi arbiter cache core dep corner quad repro)
#   make isa         rv32ui riscv-tests on the core (RISCV_TESTS=<checkout>)
#   make synth       Yosys generic synthesis of one core (fast check, used by CI)
#   make synth-soc   Yosys generic synthesis of quad_core_top (slow until the
#                    caches and memory map to BRAM in P2)
#   make synth-fpga  Yosys synth_xilinx of fpga_top, prints a resource report
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
SOC_RTL   = $(CORE_RTL) $(CACHE_RTL) $(COH_RTL) $(MEM_RTL) rtl/top/quad_core_top.v

TESTS = mesi arbiter cache core dep corner quad

.PHONY: all sim $(addprefix sim-,$(TESTS)) sim-repro isa synth synth-soc synth-fpga results animate gui clean help

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

synth: | $(OUT_DIR)
	$(YOSYS) -q -l $(OUT_DIR)/synth.log -p "read_verilog -DSYNTHESIS -I rtl/core $(CORE_RTL); synth -top riscv_ooo_core; stat"
	@! grep -E "^Latch inferred|ERROR" $(OUT_DIR)/synth.log
	@grep -A3 "design hierarchy" $(OUT_DIR)/synth.log | tail -1; grep "Number of cells" $(OUT_DIR)/synth.log | tail -1

synth-soc: | $(OUT_DIR)
	$(YOSYS) -q -l $(OUT_DIR)/synth_soc.log -p "read_verilog -DSYNTHESIS -I rtl/core -I rtl/cache $(SOC_RTL); synth -top quad_core_top; stat" 

synth-fpga: | $(OUT_DIR)
	$(YOSYS) -q -l $(OUT_DIR)/synth_fpga.log -p "read_verilog -DSYNTHESIS -I rtl/core -I rtl/cache $(SOC_RTL) rtl/top/fpga_top.v; synth_xilinx -family xc7 -top fpga_top; stat"

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
