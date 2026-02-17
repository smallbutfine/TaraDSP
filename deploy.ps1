# IRConvolverPro - Professional Deployment Script (English)
# Use this to build the Release version and package all DLLs.

$ProjectName = "IRConvolverPro"
$BuildDir = ".\Release_Build"
$ZipName = "$ProjectName`_Win64_v1.0.zip"

# 1. Define required 64-bit binaries
$Binaries = @(
    "libpffft.dll", 
    "libsoxr.dll", 
    "r8bsrc.dll", 
    "finalcd.exe"
)

Write-Host "[*] Initializing Build for $ProjectName..." -ForegroundColor Cyan

# 2. Cleanup old builds
if (Test-Path $BuildDir) { Remove-Item -Recurse -Force $BuildDir }
New-Item -ItemType Directory -Path $BuildDir | Out-Null

# 3. Compile via lazbuild (Release Mode / O3)
Write-Host "[*] Compiling with Lazarus (lazbuild)..." -ForegroundColor Yellow
& lazbuild --build-mode=Release "$ProjectName.lpi"

if ($LastExitCode -ne 0) {
    Write-Host "[!] Compilation failed. Check your Lazarus path." -ForegroundColor Red
    exit 1
}

# 4. Copy Executable and DLLs
Copy-Item ".\$ProjectName.exe" -Destination $BuildDir
foreach ($bin in $Binaries) {
    if (Test-Path $bin) {
        Copy-Item $bin -Destination $BuildDir
        Write-Host "[+] Included: $bin" -ForegroundColor Green
    } else {
        Write-Host "[!] Warning: Optional binary $bin not found." -ForegroundColor Gray
    }
}

# 5. Copy Documentation & Config
$Docs = @("README.md", "LICENSE", "settings.ini")
foreach ($doc in $Docs) {
    if (Test-Path $doc) { Copy-Item $doc -Destination $BuildDir }
}

# 6. Create final ZIP package
if (Test-Path $ZipName) { Remove-Item $ZipName }
Write-Host "[*] Packaging into $ZipName..." -ForegroundColor Yellow
Compress-Archive -Path "$BuildDir\*" -DestinationPath $ZipName

Write-Host "[*] DEPLOYMENT SUCCESSFUL!" -ForegroundColor Cyan
Write-Host "[*] Exit Code: 0" -ForegroundColor Green
