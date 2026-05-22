# Erstellt den Testdaten-Ordner, falls er fehlt
$TestData = ".\Test_Data"
if (!(Test-Path $TestData)) { New-Item -ItemType Directory -Path $TestData | Out-Null }

# Hilfsfunktion zum Erzeugen einer minimalen 24-Bit-WAV-Datei (44.1 kHz, Mono)
function Create-DummyWav ($Filename, $NumSamples, $IsImpulse) {
    $Stream = [System.IO.File]::Create($Filename)
    $Writer = [System.IO.BinaryWriter]::new($Stream)

    # 1. RIFF Header
    $Writer.Write([char[]]"RIFF")
    $Writer.Write([int32](36 + $NumSamples * 3)) # Dateigröße - 8
    $Writer.Write([char[]]"WAVE")

    # 2. fmt-Chunk
    $Writer.Write([char[]]"fmt ")
    $Writer.Write([int32]16)       # Chunk-Größe
    $Writer.Write([int16]1)        # Format (PCM = 1)
    $Writer.Write([int16]1)        # Kanäle (Mono = 1)
    $Writer.Write([int32]44100)    # Sample Rate
    $Writer.Write([int32](44100 * 3)) # Bytes pro Sekunde
    $Writer.Write([int16]3)        # Block Align (1 Kanal * 3 Bytes)
    $Writer.Write([int16]24)       # Bits pro Sample

    # 3. data-Chunk
    $Writer.Write([char[]]"data")
    $Writer.Write([int32]($NumSamples * 3))

    # 4. Audio-Daten generieren (24-Bit benötigt 3 Bytes pro Sample)
    for ($i = 0; $i -lt $NumSamples; $i++) {
        $Value = 0
        if ($IsImpulse) {
            # Impuls-Antwort: Das allererste Sample ist maximal laut, danach Stille
            if ($i -eq 0) { $Value = 8388607 }
        } else {
            # Normaler Sound: Einfache 440Hz Sinuswelle
            $Value = [int32]([math]::Sin(2 * [math]::PI * 440 * $i / 44100) * 8388607)
        }
        
        # Schreibe 3 Bytes für 24-Bit PCM
        $Writer.Write([byte]($Value -and 0xFF))
        $Writer.Write([byte](($Value -shr 8) -and 0xFF))
        $Writer.Write([byte](($Value -shr 16) -and 0xFF))
    }

    # Ordner für Batch-Test simulieren
    $BatchIn = "$TestData\Batch_In"
    if (!(Test-Path $BatchIn)) { New-Item -ItemType Directory -Path $BatchIn | Out-Null }
    
    $Writer.Close()
    $Stream.Close()
}

# Erzeuge die benötigten Testdateien (sehr kurz, ca. 200 Millisekunden)
Create-DummyWav -Filename "$TestData\source.wav" -NumSamples 8820 -IsImpulse $false
Create-DummyWav -Filename "$TestData\cab_ir.wav" -NumSamples 4096 -IsImpulse $true
# Datei für den Batch-Ordner-Test kopieren
Copy-Item "$TestData\source.wav" "$TestData\Batch_In\source_copy.wav"

Write-Host "[*] Test data successfully created!" -ForegroundColor Green
