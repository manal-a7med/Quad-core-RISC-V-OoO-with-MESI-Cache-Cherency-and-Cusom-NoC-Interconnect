@echo off
REM ============================================================================
REM run_all_tests.bat — Run All Testbenches for RISC-V OoO Quad-Core SoC
REM ============================================================================
REM Requires: Icarus Verilog (iverilog, vvp) on PATH
REM Install: Download from https://bleyer.org/icarus/
REM ============================================================================

echo ============================================================
echo  RISC-V OoO Quad-Core SoC — Test Suite
echo ============================================================
echo.

set PROJECT_DIR=%~dp0..
set RTL_DIR=%PROJECT_DIR%\rtl
set TB_DIR=%PROJECT_DIR%\tb
set SIM_DIR=%PROJECT_DIR%\sim
set PASS_COUNT=0
set FAIL_COUNT=0

REM Create output directory
if not exist "%SIM_DIR%\out" mkdir "%SIM_DIR%\out"

REM ---- Test 1: MESI Coherence Protocol ----
echo [1/5] Running MESI Coherence Protocol Test...
iverilog -DSIM -o "%SIM_DIR%\out\mesi_test.vvp" ^
    -I "%RTL_DIR%\core" ^
    -I "%RTL_DIR%\cache" ^
    -I "%RTL_DIR%\coherence" ^
    "%TB_DIR%\tb_mesi_coherence.v" ^
    "%RTL_DIR%\coherence\mesi_protocol.v" ^
    2>"%SIM_DIR%\out\mesi_compile.log"
if %ERRORLEVEL% EQU 0 (
    vvp "%SIM_DIR%\out\mesi_test.vvp" > "%SIM_DIR%\out\mesi_test.log" 2>&1
    echo     Output: sim\out\mesi_test.log
    echo     Waveform: mesi_coherence.vcd
) else (
    echo     COMPILE ERROR — see sim\out\mesi_compile.log
)
echo.

REM ---- Test 2: Bus Arbiter ----
echo [2/5] Running Bus Arbiter Test...
iverilog -DSIM -o "%SIM_DIR%\out\arbiter_test.vvp" ^
    -I "%RTL_DIR%\core" ^
    -I "%RTL_DIR%\cache" ^
    -I "%RTL_DIR%\coherence" ^
    "%TB_DIR%\tb_bus_arbiter.v" ^
    "%RTL_DIR%\coherence\bus_arbiter.v" ^
    2>"%SIM_DIR%\out\arbiter_compile.log"
if %ERRORLEVEL% EQU 0 (
    vvp "%SIM_DIR%\out\arbiter_test.vvp" > "%SIM_DIR%\out\arbiter_test.log" 2>&1
    echo     Output: sim\out\arbiter_test.log
    echo     Waveform: bus_arbiter.vcd
) else (
    echo     COMPILE ERROR — see sim\out\arbiter_compile.log
)
echo.

REM ---- Test 3: Cache Unit Test ----
echo [3/5] Running Cache Unit Test...
iverilog -DSIM -o "%SIM_DIR%\out\cache_test.vvp" ^
    -I "%RTL_DIR%\core" ^
    -I "%RTL_DIR%\cache" ^
    -I "%RTL_DIR%\coherence" ^
    "%TB_DIR%\tb_cache.v" ^
    "%RTL_DIR%\cache\l1_dcache.v" ^
    "%RTL_DIR%\cache\l1_icache.v" ^
    "%RTL_DIR%\cache\cache_controller.v" ^
    "%RTL_DIR%\coherence\mesi_protocol.v" ^
    2>"%SIM_DIR%\out\cache_compile.log"
if %ERRORLEVEL% EQU 0 (
    vvp "%SIM_DIR%\out\cache_test.vvp" > "%SIM_DIR%\out\cache_test.log" 2>&1
    echo     Output: sim\out\cache_test.log
    echo     Waveform: cache_test.vcd
) else (
    echo     COMPILE ERROR — see sim\out\cache_compile.log
)
echo.

REM ---- Test 4: Single Core OoO Test ----
echo [4/5] Running Single Core OoO Test...
iverilog -DSIM -o "%SIM_DIR%\out\core_test.vvp" ^
    -I "%RTL_DIR%\core" ^
    -I "%RTL_DIR%\cache" ^
    "%TB_DIR%\tb_ooo_core.v" ^
    "%RTL_DIR%\core\riscv_ooo_core.v" ^
    "%RTL_DIR%\core\fetch_unit.v" ^
    "%RTL_DIR%\core\decode_unit.v" ^
    "%RTL_DIR%\core\rename_unit.v" ^
    "%RTL_DIR%\core\issue_queue.v" ^
    "%RTL_DIR%\core\alu.v" ^
    "%RTL_DIR%\core\branch_unit.v" ^
    "%RTL_DIR%\core\reorder_buffer.v" ^
    "%RTL_DIR%\core\load_store_unit.v" ^
    "%RTL_DIR%\core\register_file.v" ^
    2>"%SIM_DIR%\out\core_compile.log"
if %ERRORLEVEL% EQU 0 (
    vvp "%SIM_DIR%\out\core_test.vvp" > "%SIM_DIR%\out\core_test.log" 2>&1
    echo     Output: sim\out\core_test.log
    echo     Waveform: ooo_core.vcd
) else (
    echo     COMPILE ERROR — see sim\out\core_compile.log
)
echo.

REM ---- Test 5: Full Quad-Core System Test ----
echo [5/5] Running Full Quad-Core System Test...
iverilog -DSIM -o "%SIM_DIR%\out\quad_test.vvp" ^
    -I "%RTL_DIR%\core" ^
    -I "%RTL_DIR%\cache" ^
    -I "%RTL_DIR%\coherence" ^
    -I "%RTL_DIR%\memory" ^
    -I "%RTL_DIR%\top" ^
    "%TB_DIR%\tb_quad_core.v" ^
    "%RTL_DIR%\top\quad_core_top.v" ^
    "%RTL_DIR%\core\riscv_ooo_core.v" ^
    "%RTL_DIR%\core\fetch_unit.v" ^
    "%RTL_DIR%\core\decode_unit.v" ^
    "%RTL_DIR%\core\rename_unit.v" ^
    "%RTL_DIR%\core\issue_queue.v" ^
    "%RTL_DIR%\core\alu.v" ^
    "%RTL_DIR%\core\branch_unit.v" ^
    "%RTL_DIR%\core\reorder_buffer.v" ^
    "%RTL_DIR%\core\load_store_unit.v" ^
    "%RTL_DIR%\core\register_file.v" ^
    "%RTL_DIR%\cache\l1_icache.v" ^
    "%RTL_DIR%\cache\l1_dcache.v" ^
    "%RTL_DIR%\cache\cache_controller.v" ^
    "%RTL_DIR%\cache\l2_cache.v" ^
    "%RTL_DIR%\coherence\mesi_protocol.v" ^
    "%RTL_DIR%\coherence\bus_arbiter.v" ^
    "%RTL_DIR%\coherence\snoop_controller.v" ^
    "%RTL_DIR%\coherence\coherence_bus.v" ^
    "%RTL_DIR%\memory\memory_controller.v" ^
    "%RTL_DIR%\memory\main_memory.v" ^
    2>"%SIM_DIR%\out\quad_compile.log"
if %ERRORLEVEL% EQU 0 (
    vvp "%SIM_DIR%\out\quad_test.vvp" > "%SIM_DIR%\out\quad_test.log" 2>&1
    echo     Output: sim\out\quad_test.log
    echo     Waveform: quad_core.vcd
) else (
    echo     COMPILE ERROR — see sim\out\quad_compile.log
)
echo.

echo ============================================================
echo  Test Suite Complete
echo  Check sim\out\ for detailed logs and VCD waveforms
echo  View waveforms with GTKWave: gtkwave [filename].vcd
echo ============================================================
pause
