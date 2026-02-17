# IRConvolverPro - Dual Build & Deployment Script (CLI + GUI)
# This script automates the release for both editions.

$ProjectCLI = "IRConvolverPro"
$ProjectGUI = "IRConvolverPro-GUI"
$ReleaseDir = ".\Release_Full_Package"
$ZipName = "IRConvolverPro_v1.2_Full_Win64.zip"

Write-Host "[*] Initializing Dual Deployment..." -ForegroundColor Cyan

# 1. Cleanup
if (Test-Path $ReleaseDir) { Remove-Item -Recurse -Force $ReleaseDir }
New-Item -ItemType Directory -Path $ReleaseDir | Out-Null

# 2. Build CLI Version
Write-Host "[*] Building CLI Edition..." -ForegroundColor Yellow
& lazbuild --build-mode=Release "$ProjectCLI.lpi"
if ($LastExitCode -eq 0) {
    Copy-Item ".\$ProjectCLI.exe" -Destination $ReleaseDir
    Write-Host "[+] CLI Build Success." -ForegroundColor Green
} else {
    Write-Host "[!] CLI Build Failed!" -ForegroundColor Red; exit 1
}

# 3. Build GUI Version
Write-Host "[*] Building GUI Edition..." -ForegroundColor Yellow
& lazbuild --build-mode=Release "$ProjectGUI.lpi"
if ($LastExitCode -eq 0) {
    Copy-Item ".\$ProjectGUI.exe" -Destination $ReleaseDir
    Write-Host "[+] GUI Build Success." -ForegroundColor Green
} else {
    Write-Host "[!] GUI Build Failed!" -ForegroundColor Red; exit 1
}

# 4. Copy Shared Assets (DLLs, Licenses, Config)
$Assets = @("libpffft.dll", "r8bsrc.dll", "libsoxr.dll", "finalcd.exe", "settings.ini", "LICENSE", "README.md")
foreach ($asset in $Assets) {
    if (Test-Path $asset) {
        Copy-Item $asset -Destination $ReleaseDir
        Write-Host "[+] Asset included: $asset" -ForegroundColor Gray
    }
}

# 5. Create Final ZIP
if (Test-Path $ZipName) { Remove-Item $ZipName }
Write-Host "[*] Packaging into $ZipName..." -ForegroundColor Cyan
Compress-Archive -Path "$ReleaseDir\*" -DestinationPath $ZipName

Write-Host "[*] ALL TASKS COMPLETED. Exit Code: 0" -ForegroundColor Green
