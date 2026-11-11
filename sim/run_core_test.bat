@echo off
REM Run Single Core OoO Test Only
set PROJECT_DIR=%~dp0..
set RTL_DIR=%PROJECT_DIR%\rtl
set TB_DIR=%PROJECT_DIR%\tb

echo Running Single Core OoO Test...
iverilog -DSIM -o "%~dp0out\core_test.vvp" ^
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
    "%RTL_DIR%\core\register_file.v"
if %ERRORLEVEL% EQU 0 (
    vvp "%~dp0out\core_test.vvp"
) else (
    echo Compilation failed!
)
pause
