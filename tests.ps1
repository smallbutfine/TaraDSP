# TaraDSP Test Suite
# Tests CLI functionality, Hardware Truncation, and Mastering Mode

$Exe = ".\taradsp.exe"
$TestData = ".\Test_Data"
$Results = ".\Test_Results"

Write-Host "[*] Starting TaraDSP Test Suite..." -ForegroundColor Cyan

# Sicherstellen, dass die Umgebung sauber ist
if (Test-Path $Results) { Remove-Item -Recurse -Force $Results }
New-Item -ItemType Directory -Path $Results | Out-Null

# Variable zum Tracken des globalen Testerfolgs
$GlobalPass = $true

# TEST 1: Basic Convolution & 24-bit Output
Write-Host "[Test 1] Standard Convolution (24-bit)... " -NoNewline
& $Exe -i1 "$TestData\source.wav" -i2 "$TestData\cab_ir.wav" -o "$Results\test1_conv.wav" -b 24
if ($LASTEXITCODE -eq 0 -and (Test-Path "$Results\test1_conv.wav")) { 
    Write-Host "PASS" -ForegroundColor Green 
} else { 
    Write-Host "FAIL" -ForegroundColor Red
    $GlobalPass = $false
}

# TEST 2: Hardware Truncation (1024 samples)
Write-Host "[Test 2] Hardware Truncation (1024)... " -NoNewline
& $Exe -i1 "$TestData\source.wav" -i2 "$TestData\cab_ir.wav" -o "$Results\test2_hardware.wav" -l 1024

if (Test-Path "$Results\test2_hardware.wav") {
    $size = (Get-Item "$Results\test2_hardware.wav").Length
    # Prüfen, ob die Dateigröße für das Kürzen grob passt
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

# TEST 3: Mastering Mode (No -i2) + Dither to 16-bit
Write-Host "[Test 3] Mastering Mode & 16-bit Dither... " -NoNewline
& $Exe -i1 "$TestData\source.wav" -o "$Results\test3_master.wav" -b 16
if ($LASTEXITCODE -eq 0 -and (Test-Path "$Results\test3_master.wav")) { 
    Write-Host "PASS" -ForegroundColor Green 
} else { 
    Write-Host "FAIL" -ForegroundColor Red 
    $GlobalPass = $false
}

# TEST 4: Batch Processing Simulation
Write-Host "[Test 4] Batch Mode Simulation... " -NoNewline
if (!(Test-Path "$Results\Batch_Out")) { New-Item -ItemType Directory -Path "$Results\Batch_Out" | Out-Null }
& $Exe -i1 "$TestData\Batch_In\" -i2 "$TestData\cab_ir.wav" -o "$Results\Batch_Out\" -b 24
if ($LASTEXITCODE -eq 0) { 
    Write-Host "PASS" -ForegroundColor Green 
} else { 
    Write-Host "FAIL (Optional Feature)" -ForegroundColor Yellow 
    # Wir markieren Batch hier nicht als globalen Fehlschlag, da CLI oft Einzeldateien erzwingt
}

Write-Host "[*] Test Suite Finished." -ForegroundColor Cyan

# === GitHub Actions Signalisierung ===
if ($GlobalPass -eq $false) {
    Write-Host "[!] Test Suite FAILED: Core features are broken." -ForegroundColor Red
    exit 1
}

exit 0
