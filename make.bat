@echo off
REM ============================================================================
REM make.bat — Windows wrapper for Makefile (uses gmake if available, or direct)
REM Usage:
REM   .\make animate
REM   .\make gui
REM   .\make sim
REM   .\make all
REM ============================================================================

set "PATH=C:\iverilog\bin;%PATH%"
set "GMAKE_EXE=C:\Program Files\MATLAB\R2024b\bin\win64\gmake.exe"

if exist "%GMAKE_EXE%" (
    "%GMAKE_EXE%" %*
    exit /b %ERRORLEVEL%
)

where make >nul 2>nul
if %ERRORLEVEL%==0 (
    make %*
    exit /b %ERRORLEVEL%
)

REM Fallback direct execution if GNU make is not found
set "TARGET=%1"
if "%TARGET%"=="" set "TARGET=all"

if "%TARGET%"=="animate" (
    python scripts/mesi_visualizer.py --verify-rtl --cli --gif docs/mesi_coherence_animation.gif
    exit /b %ERRORLEVEL%
)
if "%TARGET%"=="gui" (
    python scripts/mesi_visualizer.py --gui
    exit /b %ERRORLEVEL%
)
if "%TARGET%"=="all" (
    python scripts/mesi_visualizer.py --verify-rtl --cli --gif docs/mesi_coherence_animation.gif
    exit /b %ERRORLEVEL%
)
echo Unknown target: %TARGET%. Use: animate, gui, sim, all, clean
