@echo off
setlocal enabledelayedexpansion
call :do_test "win64"
echo Back from call
goto :eof

:do_test
set "T_OS=%~1"
echo In do_test, T_OS=%T_OS%
if "%T_OS%"=="win64" goto :compile_c_win64
echo Should not reach here
goto :compile_c_done

:compile_c_win64
echo In compile_c_win64
"C:/mingw64/bin/gcc.exe" -O3 -msse -mfpmath=sse -shared -o "%CD%\dist\win64\libpffft.dll" "%CD%/pffft.c" "%CD%/fftpack.c" 2>&1
if errorlevel 1 (
    echo   ERROR: PFFFT C compilation failed (win64)
    goto :target_failed
)
echo   OK: libpffft.dll
goto :compile_c_done

:compile_c_done
echo Done with C compilation
goto :eof

:target_failed
echo TARGET FAILED
goto :eof
