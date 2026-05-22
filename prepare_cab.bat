@echo off
:: Aligns to Sample 0, Truncates to 1024, High-Pass at 80Hz, Normalizes
TaraDSP.exe -i1 "raw_cabinet.wav" -o "GP200_Ready.wav" -l 1024 --min --hp 80 -b 24
echo IR is now hardware-ready!
pause
