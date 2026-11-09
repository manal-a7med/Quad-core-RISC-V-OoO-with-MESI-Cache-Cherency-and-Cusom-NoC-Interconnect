# =============================================================================
# Makefile — Quad-Core Out-of-Order RISC-V Processor & MESI Coherence Animator
# =============================================================================
# Targets:
#   make all       : Run all 7 Verilog RTL testbenches + generate MESI animation
#   make animate   : Verify RTL, run terminal animation, and export animated GIF
#   make gui       : Launch interactive desktop MESI Coherence animation window
#   make sim       : Compile and run all 7 Verilog testbenches
#   make clean     : Remove compiled simulation binaries (.vvp) and logs
# =============================================================================

IVERILOG  ?= C:/iverilog/bin/iverilog.exe
VVP       ?= C:/iverilog/bin/vvp.exe
PYTHON    ?= python

INC_FLAGS  = -DSIM -I rtl/core -I rtl/cache
OUT_DIR    = sim/out
GIF_OUT    = docs/mesi_coherence_animation.gif

CORE_RTL   = $(wildcard rtl/core/*.v)
CACHE_RTL  = $(wildcard rtl/cache/*.v)
COH_RTL    = $(wildcard rtl/coherence/*.v)
MEM_RTL    = $(wildcard rtl/memory/*.v)
TOP_RTL    = rtl/top/quad_core_top.v

.PHONY: all animate gui sim sim-mesi sim-arbiter sim-cache sim-core sim-dep sim-corner sim-quad clean help

all: sim animate

help:
	@echo "=========================================================================="
	@echo " Quad-Core RISC-V OoO SoC & MESI Coherence Automation Targets"
	@echo "=========================================================================="
	@echo "  make animate   - Run terminal walkthrough + generate animated GIF ($(GIF_OUT))"
	@echo "  make gui       - Open interactive desktop MESI animation (Play/Pause/Step)"
	@echo "  make sim       - Compile and run all 7 Verilog hardware testbenches"
	@echo "  make all       - Run full RTL verification suite + MESI animation"
	@echo "  make clean     - Clean simulation binaries and temporary files"
	@echo "=========================================================================="

# -----------------------------------------------------------------------------
# Python Visual Coherence Animation Targets
# -----------------------------------------------------------------------------
animate:
	$(PYTHON) scripts/mesi_visualizer.py --verify-rtl --cli --gif $(GIF_OUT)

gui:
	$(PYTHON) scripts/mesi_visualizer.py --gui

# -----------------------------------------------------------------------------
# Verilog RTL Simulation Targets
# -----------------------------------------------------------------------------
sim: sim-mesi sim-arbiter sim-cache sim-core sim-dep sim-corner sim-quad

sim-mesi:
	$(IVERILOG) $(INC_FLAGS) -o $(OUT_DIR)/mesi_test.vvp rtl/coherence/mesi_protocol.v tb/tb_mesi_coherence.v
	$(VVP) $(OUT_DIR)/mesi_test.vvp

sim-arbiter:
	$(IVERILOG) $(INC_FLAGS) -o $(OUT_DIR)/arbiter_test.vvp rtl/coherence/bus_arbiter.v tb/tb_bus_arbiter.v
	$(VVP) $(OUT_DIR)/arbiter_test.vvp

sim-cache:
	$(IVERILOG) $(INC_FLAGS) -o $(OUT_DIR)/cache_test.vvp rtl/cache/l1_dcache.v tb/tb_cache.v
	$(VVP) $(OUT_DIR)/cache_test.vvp

sim-core:
	$(IVERILOG) $(INC_FLAGS) -o $(OUT_DIR)/core_test.vvp $(CORE_RTL) tb/tb_ooo_core.v
	$(VVP) $(OUT_DIR)/core_test.vvp

sim-dep:
	$(IVERILOG) $(INC_FLAGS) -o $(OUT_DIR)/dep_arith_test.vvp $(CORE_RTL) tb/tb_ooo_dependent_arith.v
	$(VVP) $(OUT_DIR)/dep_arith_test.vvp

sim-corner:
	$(IVERILOG) $(INC_FLAGS) -o $(OUT_DIR)/corner_cases_test.vvp $(CORE_RTL) tb/tb_ooo_corner_cases.v
	$(VVP) $(OUT_DIR)/corner_cases_test.vvp

sim-quad:
	$(IVERILOG) $(INC_FLAGS) -o $(OUT_DIR)/quad_test.vvp $(CORE_RTL) $(CACHE_RTL) $(COH_RTL) $(MEM_RTL) $(TOP_RTL) tb/tb_quad_core.v
	$(VVP) $(OUT_DIR)/quad_test.vvp

clean:
	$(PYTHON) -c "import glob, os; [os.remove(f) for f in glob.glob('sim/out/*.vvp') + glob.glob('*.vvp') if os.path.exists(f)]"
