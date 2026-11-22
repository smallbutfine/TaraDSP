@echo off
call :do_test "win64"
echo Back from call
goto :eof

:do_test
set "T_OS=%~1"
set "TD=%CD%\dist\win64"
if not exist "%TD%" mkdir "%TD%"
echo [C] Compiling PFFFT shared library...
"C:/mingw64/bin/gcc.exe" -O3 -msse -mfpmath=sse -shared -o "%TD%\libpffft.dll" "%CD%/pffft.c" "%CD%/fftpack.c"
if errorlevel 1 goto :target_failed
echo   OK: libpffft.dll
goto :eof

:target_failed
echo TARGET FAILED
goto :eof
