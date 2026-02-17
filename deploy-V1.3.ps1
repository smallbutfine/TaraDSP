# IRConvolverPro v1.3 - Hybrid Build & Deployment Script
# Static Linking for PFFFT | Dynamic Linking for r8brain

$ProjectCLI = "IRConvolverPro-CLI"
$ProjectGUI = "IRConvolverPro-GUI"
$ReleaseDir = ".\Release_v1.3"
$ZipName = "IRConvolverPro_v1.3_Hybrid_Win64.zip"

Write-Host "[*] Starting Hybrid Deployment (Static PFFFT + Dynamic r8brain)..." -ForegroundColor Cyan

# 1. Clean and Prepare
if (Test-Path $ReleaseDir) { Remove-Item -Recurse -Force $ReleaseDir }
New-Item -ItemType Directory -Path $ReleaseDir | Out-Null

# 2. Build PFFFT static object via Makefile
Write-Host "[*] Compiling C-backend (PFFFT)..." -ForegroundColor Yellow
& make pffft.obj
if ($LastExitCode -ne 0) {
    Write-Host "[!] C-Compilation failed. Ensure GCC is in PATH." -ForegroundColor Red; exit 1
}

# 3. Build Pascal Editions (Lazbuild)
# The static pffft.obj is now linked directly into the executables.
foreach ($proj in @($ProjectCLI, $ProjectGUI)) {
    Write-Host "[*] Building $proj..." -ForegroundColor Yellow
    & lazbuild --build-mode=Release "$proj.lpi"
    if ($LastExitCode -eq 0) {
        Copy-Item ".\$proj.exe" -Destination $ReleaseDir
    } else {
        Write-Host "[!] Build failed for $proj!" -ForegroundColor Red; exit 1
    }
}

# 4. Critical Dependency Check (r8brain DLL)
# Since r8brain is NOT static, this file MUST be present.
if (!(Test-Path ".\r8bsrc.dll")) {
    Write-Host "[!] ERROR: r8bsrc.dll is missing! Deployment aborted." -ForegroundColor Red
    exit 1
}
Copy-Item ".\r8bsrc.dll" -Destination $ReleaseDir

# 5. Copy Assets & Documentation
$Assets = @("libsoxr.dll", "finalcd.exe", "settings.ini", "LICENSE", "README.md")
foreach ($asset in $Assets) {
    if (Test-Path $asset) { Copy-Item $asset -Destination $ReleaseDir }
}

# 6. Final Packaging
if (Test-Path $ZipName) { Remove-Item $ZipName }
Write-Host "[*] Creating final package $ZipName..." -ForegroundColor Cyan
Compress-Archive -Path "$ReleaseDir\*" -DestinationPath $ZipName

Write-Host "[*] DEPLOYMENT COMPLETE. Ready for distribution." -ForegroundColor Green
