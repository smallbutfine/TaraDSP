#!/bin/bash
echo "[*] Baue IRConvolverPro (Release Mode)..."

# Prüfen ob lazbuild installiert ist
if ! command -v lazbuild &> /dev/null
then
    echo "[!] lazbuild konnte nicht gefunden werden. Bitte installieren Sie Lazarus/fpc."
    exit 1
fi

# Kompilieren
lazbuild --build-mode=Release IRConvolverPro.lpi

if [ $? -eq 0 ]; then
    echo "[*] Build erfolgreich abgeschlossen."
    # Optional: Symbole entfernen um die Datei kleiner zu machen
    strip IRConvolverPro
else
    echo "[!] Fehler beim Kompilieren!"
    exit 1
fi
