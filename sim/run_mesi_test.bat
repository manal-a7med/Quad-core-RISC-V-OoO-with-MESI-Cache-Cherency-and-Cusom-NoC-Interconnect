@echo off
REM Run MESI Coherence Test Only
set PROJECT_DIR=%~dp0..
set RTL_DIR=%PROJECT_DIR%\rtl
set TB_DIR=%PROJECT_DIR%\tb

echo Running MESI Coherence Protocol Test...
iverilog -DSIM -o "%~dp0out\mesi_test.vvp" ^
    -I "%RTL_DIR%\core" ^
    -I "%RTL_DIR%\cache" ^
    -I "%RTL_DIR%\coherence" ^
    "%TB_DIR%\tb_mesi_coherence.v" ^
    "%RTL_DIR%\coherence\mesi_protocol.v"
if %ERRORLEVEL% EQU 0 (
    vvp "%~dp0out\mesi_test.vvp"
) else (
    echo Compilation failed!
)
pause
