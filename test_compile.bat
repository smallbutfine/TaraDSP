@echo off
setlocal enabledelayedexpansion
set "ROOT=%CD%"
set "TD=%ROOT%\dist\win64"
if not exist "%TD%" mkdir "%TD%"
echo [C] Compiling PFFFT shared library...
"C:/mingw64/bin/gcc.exe" -O3 -msse -mfpmath=sse -shared -o "%TD%\libpffft.dll" "%ROOT%/pffft.c" "%ROOT%/fftpack.c" 2>&1
if errorlevel 1 (
    echo   ERROR: PFFFT C compilation failed (win64)
) else (
    echo   OK: libpffft.dll
)
