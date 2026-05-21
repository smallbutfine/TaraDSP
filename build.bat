@echo off
echo [*] Baue IRConvolverPro (Release Mode)...

:: Nutzt lazbuild aus dem PATH (auf GitHub) oder lokal
set LAZ_PATH=lazbuild

:: Kompiliere das Projekt mit der Release-Konfiguration
%LAZ_PATH% --build-mode=Release IRConvolverPro.lpi

if %ERRORLEVEL% NEQ 0 (
    echo [!] Fehler beim Kompilieren!
    if not defined GITHUB_ACTIONS pause
    exit /b %ERRORLEVEL%
)

echo [*] Build erfolgreich abgeschlossen.

:: Nur pausieren, wenn es lokal auf deinem PC ausgeführt wird
if not defined GITHUB_ACTIONS pause
