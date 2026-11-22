@echo off
setlocal enabledelayedexpansion
call :do_test "win64"
echo Back from call
goto :eof

:do_test
set "T_OS=%~1"
set "TD=%CD%\dist\win64"
if not exist "%TD%" mkdir "%TD%"
echo In do_test, T_OS=%T_OS%

REM Inline C compilation - no goto
echo [C] Compiling PFFFT shared library...
"C:/mingw64/bin/gcc.exe" -O3 -msse -mfpmath=sse -shared -o "%TD%\libpffft.dll" "%CD%/pffft.c" "%CD%/fftpack.c"
set "GCC_ERR=!errorlevel!"
echo GCC exit code: !GCC_ERR!
if !GCC_ERR! neq 0 (
    echo   ERROR: PFFFT C compilation failed (win64)
    goto :target_failed
)
echo   OK: libpffft.dll
goto :eof

:target_failed
echo TARGET FAILED
goto :eof
