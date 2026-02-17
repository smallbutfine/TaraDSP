# IRConvolverPro Test Suite
# Tests CLI functionality, Hardware Truncation, and Mastering Mode

$Exe = ".\IRConvolverPro-CLI.exe"
$TestData = ".\Test_Data"
$Results = ".\Test_Results"

Write-Host "[*] Starting IRConvolverPro Test Suite..." -ForegroundColor Cyan

# Ensure clean test environment
if (Test-Path $Results) { Remove-Item -Recurse -Force $Results }
New-Item -ItemType Directory -Path $Results | Out-Null

# TEST 1: Basic Convolution & 24-bit Output
Write-Host "[Test 1] Standard Convolution (24-bit)..." -NoNewline
& $Exe -i1 "$TestData\source.wav" -i2 "$TestData\cab_ir.wav" -o "$Results\test1_conv.wav" -b 24
if ($LASTEXITCODE -eq 0) { Write-Host " PASS" -ForegroundColor Green } else { Write-Host " FAIL" -ForegroundColor Red }

# TEST 2: Hardware Truncation (1024 samples)
Write-Host "[Test 2] Hardware Truncation (1024)..." -NoNewline
& $Exe -i1 "$TestData\source.wav" -i2 "$TestData\cab_ir.wav" -o "$Results\test2_hardware.wav" -l 1024
$size = (Get-Item "$Results\test2_hardware.wav").Length
# Check if file size is roughly correct for 1024 samples (approx 4KB for 24-bit mono)
if ($size -lt 10000) { Write-Host " PASS" -ForegroundColor Green } else { Write-Host " FAIL (Size too large)" -ForegroundColor Red }

# TEST 3: Mastering Mode (No -i2) + Dither to 16-bit
Write-Host "[Test 3] Mastering Mode & 16-bit Dither..." -NoNewline
& $Exe -i1 "$TestData\source.wav" -o "$Results\test3_master.wav" -b 16
if ($LASTEXITCODE -eq 0) { Write-Host " PASS" -ForegroundColor Green } else { Write-Host " FAIL" -ForegroundColor Red }

# TEST 4: Batch Processing Simulation
Write-Host "[Test 4] Batch Mode Simulation..." -NoNewline
if (!(Test-Path "$Results\Batch_Out")) { New-Item -ItemType Directory -Path "$Results\Batch_Out" | Out-Null }
& $Exe -i1 "$TestData\Batch_In\" -i2 "$TestData\cab_ir.wav" -o "$Results\Batch_Out\" -b 24
if ($LASTEXITCODE -eq 0) { Write-Host " PASS" -ForegroundColor Green } else { Write-Host " FAIL" -ForegroundColor Red }

Write-Host "[*] Test Suite Finished." -ForegroundColor Cyan
