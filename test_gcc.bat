@echo off
setlocal enabledelayedexpansion
echo Testing gcc...
where gcc
gcc --version 2>&1 | head -1
echo Errorlevel after gcc: %errorlevel%
if errorlevel 1 (
    echo GCC FAILED
) else (
    echo GCC OK
)
