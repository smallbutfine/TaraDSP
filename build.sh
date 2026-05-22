#!/bin/bash
echo "[*] Building TaraDSP (Release Mode)..."

# Prüfen ob lazbuild installiert ist
if ! command -v lazbuild &> /dev/null
then
    echo "[!] lazbuild konnte nicht gefunden werden. Bitte installieren Sie Lazarus/fpc."
    exit 1
fi

# Kompilieren
lazbuild --build-mode=Release TaraDSP.lpi

if [ $? -eq 0 ]; then
    echo "[*] Build erfolgreich abgeschlossen."
    
    # Manuelles Strippen nur auf Linux ausführen, da macOS sonst fehlschlägt.
    # (Lazarus macht das über die .lpi aber ohnehin schon automatisch für dich)
    if [ "$(uname)" = "Linux" ] && command -v strip &> /dev/null; then
        strip TaraDSP 2>/dev/null || true
    fi
else
    echo "[!] Fehler beim Kompilieren!"
    exit 1
fi
