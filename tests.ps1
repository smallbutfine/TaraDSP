# TaraDSP Test Suite
# Automatischer Suchmodus für Compiler-Ausgaben (beachtet Case Sensitivity)

$TestData = ".\Test_Data"
$Results = ".\Test_Results"

Write-Host "[*] Starting TaraDSP Test Suite..." -ForegroundColor Cyan

# === AUTOMATISCHE EXE-SUCHE UND REPARATUR ===
Write-Host "[*] Searching for compiled TaraDSP-noAVX2.exe..."
$FoundExe = Get-ChildItem -Recurse -Filter "TaraDSP-noAVX2.exe" | Select-Object -First 1

if ($FoundExe) {
    $RealExePath = $FoundExe.FullName
    Write-Host "[+] Found executable at: $RealExePath" -ForegroundColor Green
    # Kopiert nur, wenn die Datei nicht schon im Hauptverzeichnis liegt
    if ($RealExePath -ne "$(Get-Location)\TaraDSP.exe") {
        Copy-Item -Path $RealExePath -Destination ".\TaraDSP.exe" -Force
    }
} else {
    # Fallback, falls die Datei ohne den Suffix erzeugt wurde
    $FoundFallback = Get-ChildItem -Recurse -Filter "TaraDSP.exe" | Select-Object -First 1
    if ($FoundFallback) {
        $RealFallbackPath = $FoundFallback.FullName
        Write-Host "[+] Found fallback executable at: $RealFallbackPath" -ForegroundColor Green
        # Kopiert nur, wenn die Quell-Datei nicht schon am Ziel-Ort liegt (Behebt den Fehler!)
        if ($RealFallbackPath -ne "$(Get-Location)\TaraDSP.exe") {
            Copy-Item -Path $RealFallbackPath -Destination ".\TaraDSP.exe" -Force
        }
    } else {
        Write-Host "[!] CRITICAL ERROR: No TaraDSP executable found anywhere!" -ForegroundColor Red
        exit 1
    }
}

$Exe = ".\TaraDSP.exe"

# Sicherstellen, dass die Umgebung sauber ist
if (Test-Path $Results) { Remove-Item -Recurse -Force $Results }
New-Item -ItemType Directory -Path $Results | Out-Null

$GlobalPass = $true

# TEST 1: Basic Convolution & 24-bit Output
Write-Host "[Test 1] Standard Convolution (24-bit)... " -NoNewline
& $Exe -x "$TestData\source.wav" -y "$TestData\cab_ir.wav" -o "$Results\test1_conv.wav" -b 24
if ($LASTEXITCODE -eq 0 -and (Test-Path "$Results\test1_conv.wav")) { 
    Write-Host "PASS" -ForegroundColor Green 
} else { 
    Write-Host "FAIL" -ForegroundColor Red
    $GlobalPass = $false
}

# TEST 2: Hardware Truncation (1024 samples)
Write-Host "[Test 2] Hardware Truncation (1024)... " -NoNewline
& $Exe -x "$TestData\source.wav" -y "$TestData\cab_ir.wav" -o "$Results\test2_hardware.wav" -l 1024

if (Test-Path "$Results\test2_hardware.wav") {
    $size = (Get-Item "$Results\test2_hardware.wav").Length
    if ($size -lt 50000) { 
        Write-Host "PASS" -ForegroundColor Green 
    } else { 
        Write-Host "FAIL (Size too large: $size Bytes)" -ForegroundColor Red 
        $GlobalPass = $false
    }
} else {
    Write-Host "FAIL (File not generated)" -ForegroundColor Red
    $GlobalPass = $false
}

# TEST 3: Mastering Mode (No -y) + Dither to 16-bit
Write-Host "[Test 3] Mastering Mode & 16-bit Dither... " -NoNewline
& $Exe -x "$TestData\source.wav" -o "$Results\test3_master.wav" -b 16
if ($LASTEXITCODE -eq 0 -and (Test-Path "$Results\test3_master.wav")) { 
    Write-Host "PASS" -ForegroundColor Green 
} else { 
    Write-Host "FAIL" -ForegroundColor Red 
    $GlobalPass = $false
}

# TEST 4: Batch Processing Simulation
Write-Host "[Test 4] Batch Mode Simulation... " -NoNewline
if (!(Test-Path "$Results\Batch_Out")) { New-Item -ItemType Directory -Path "$Results\Batch_Out" | Out-Null }
& $Exe -x "$TestData\Batch_In\source_copy.wav" -y "$TestData\cab_ir.wav" -o "$Results\Batch_Out\batch_success.wav" -b 24
if ($LASTEXITCODE -eq 0 -and (Test-Path "$Results\Batch_Out\batch_success.wav")) { 
    Write-Host "PASS" -ForegroundColor Green 
} else { 
    Write-Host "FAIL" -ForegroundColor Red 
    $GlobalPass = $false
}

Write-Host "[*] Test Suite Finished." -ForegroundColor Cyan

if ($GlobalPass -eq $false) {
    Write-Host "[!] Test Suite FAILED: Core features are broken." -ForegroundColor Red
    exit 1
}

exit 0
