@echo off
echo [*] Baue IRConvolverPro (Release Mode)...

:: Pfad zu lazbuild (falls nicht im PATH, hier voll angeben)
set LAZ_PATH=lazbuild

:: Kompiliere das Projekt mit der Release-Konfiguration aus der .lpi
%LAZ_PATH% --build-mode=Release IRConvolverPro.lpi

if %ERRORLEVEL% NEQ 0 (
    echo [!] Fehler beim Kompilieren!
    pause
    exit /b %ERRORLEVEL%
)

echo [*] Build erfolgreich abgeschlossen.
echo [*] Die Exe befindet sich im Hauptverzeichnis.
pause
