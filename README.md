# TaraDSP

**Professional Audio Convolution & Mastering** — a FreePascal/Lazarus project
that applies FFT-based convolution with impulse responses, resamples audio,
and applies mastering-grade dithering and fades.

## What it does

- **FFT Convolution** — High-speed convolution using the PFFFT library
  (Pretty Fast FFT). Convolve any audio signal with cabinet impulse responses,
  reverb IRs, or custom filters.
- **Mastering Dither** — TPDF (Triangular Probability Density Function) dithering
  with error feedback for transparent 16-bit and 24-bit output.
- **Resampling** — High-quality sample rate conversion via SoX Resampler
  (libsoxr) with fallback to linear interpolation.
- **Minimum Phase** — Convert linear-phase impulse responses to minimum phase
  for lower latency and more natural sound.
- **Fades & Trimming** — Apply fade-in/fade-out and trim silence from IRs.
- **Cross-platform** — Windows (x86_64), macOS (Intel + Apple Silicon) and
  Linux (x86_64 + ARM)
- **GUI + CLI** — Both a command-line tool for batch processing and a GUI
  for interactive use

## Downloads

Prebuilt binaries are attached to every
[GitHub Release](https://github.com/smallbutfine/TaraDSP/releases):

| Platform | Artifact |
|---|---|
| Windows 64-bit | `TaraDSP_<version>_Setup.exe` (installer) |
| macOS Intel | `TaraDSP_gui<version>-macos-intel.zip` |
| macOS Apple Silicon | `TaraDSP_gui<version>-macos-aarch64.zip` |
| Linux x86_64 | `TaraDSP<version>-linux-x64.tar.gz` |
| Linux ARM | `TaraDSP<version>-linux-arm.tar.gz` |

Unzip the macOS archive and drag `TaraDSP_gui.app` to `/Applications`.
The app is not code-signed, so on first launch use **right-click → Open**
(or `xattr -dr com.apple.quarantine` on the terminal).

## Installation / Build

### Prerequisites

- FreePascal Compiler (FPC) 3.2.2+ or Lazarus IDE 3.0+
- Lazarus/LCL for the GUI
- For a full multi-platform build: the FPC cross-compilers
  (`ppcrossx64`, `ppcrossa64`, `ppcrossarm`) and Inno Setup 6
- Python 3 (for `tools/zip_app.py` — macOS bundle zipping with correct Unix modes)
- Zig (auto-downloaded by `build_all.bat` for Linux C cross-compilation)

### Build everything (all platforms)

From the repository root, in Git Bash or `cmd.exe`:

```bash
./build_all.bat            # all 5 targets + packages into Deploy/
./build_all.bat --check    # verify the toolchain only, build nothing
```

The script builds every target (CLI + GUI), then writes the release artifacts
to `Deploy/`. It exits non-zero if any target fails and prints a summary.

Useful environment variables:

| Variable | Effect |
|---|---|
| `FPC_DIR`, `LAZBUILD`, `CROSS_BIN_DIR`, `ISCC`, `TAR` | override the toolchain paths |
| `NO_VERSION_BUMP=1` | build the version already in `Assets/version.txt` without incrementing it |
| `CI=true` or `NO_PAUSE=1` | never pause at the end |

### Build a single program

```bash
# CLI
fpc -O2 -Fusrc -Sg -Sc TaraDSP.lpr

# GUI
lazbuild --build-all gui/TaraDSP_gui.lpi
```

### Cross-compile for a specific target

```bash
# macOS Intel (x86_64)
ppcrossx64 -Tdarwin -Px86_64 -O2 -XPx86_64-apple-darwin19- -Fusrc -FEdist/macos-intel TaraDSP.lpr

# macOS Apple Silicon (aarch64)
ppcrossa64 -Tdarwin -Paarch64 -O2 -XPaarch64-apple-darwin19- -Fusrc -FEdist/macos-aarch64 TaraDSP.lpr

# Linux x86_64
ppcrossx64 -Tlinux -Px86_64 -O2 -XPx86_64-linux-gnu- -Fusrc -FEdist/linux-x64 TaraDSP.lpr

# Linux ARM
ppcrossarm -Tlinux -Parm -O2 -CaEABIHF -XParm-linux-gnueabihf- -Fusrc -FEdist/linux-arm TaraDSP.lpr
```

## CLI Usage

```bash
# Basic convolution
TaraDSP -x input.wav -y impulse_response.wav -o output.wav

# Mastering (no IR, just dither + normalize)
TaraDSP -x mix.wav -o master.wav -b 16

# Resampling
TaraDSP -x input.wav -y ir.wav -o output.wav -r 48000

# Minimum phase conversion
TaraDSP -x input.wav -y linear_ir.wav -o output.wav --min

# Trim silence and apply fade
TaraDSP -x input.wav -y ir.wav -o output.wav -t -60 -f 50

# Mono output
TaraDSP -x stereo.wav -y ir.wav -o mono.wav -m

# Truncate for modelers
TaraDSP -x input.wav -y ir.wav -o output.wav -l 1024
```

### CLI Options

| Option | Long form | Value | Description |
|---|---|---|---|
| `-x` | `--in1` | `<file>` | Input WAV file |
| `-y` | `--in2` | `<file>` | Impulse response WAV (optional) |
| `-o` | `--output` | `<file>` | Output WAV file |
| `-b` | `--bits` | `16\|24\|32` | Output bit depth (default: 24) |
| `-r` | `--rate` | `<Hz>` | Target sample rate |
| `-l` | `--length` | `<samples>` | Truncate output length |
| `-t` | `--trim` | `<dB>` | Trim silence below threshold |
| `-f` | `--fade` | `<ms>` | Fade-out duration |
| `-m` | `--mono` | (flag) | Force mono output |
| | `--min` | (flag) | Minimum phase conversion |
| `-h` | `--help` | (flag) | Show help |

## GUI

The GUI provides the same functionality as the CLI in a window:

- Source file and IR file pickers
- Output file with browse button
- Bit depth (16/24/32) and sample rate selectors
- Truncate length, fade duration, trim threshold
- Mono and minimum phase checkboxes
- Log output with per-step progress

## Project structure

```
TaraDSP/
├── NAME                        # Project name (read by build_all.bat)
├── LICENSE                     # BSD-3-Clause license
├── CONTRIBUTING.md             # Contribution guidelines
├── AGENTS.md                   # Working principles for AI agents
├── README.md                   # This file
├── build_all.bat               # Multi-platform build script
├── .gitignore
├── .github/workflows/ci.yml    # GitHub Actions CI
├── Assets/version.txt          # Version number
├── src/                        # Pascal source files (shared units)
├── gui/                        # Lazarus GUI project (.lpi, .lpr, forms)
├── tools/                      # Helper tools and scripts
│   └── zip_app.py              # macOS .app zip with correct Unix modes
├── installer/
│   └── installer.iss           # Inno Setup script (Windows installer)
├── config/                     # Runtime configuration
├── docs/                       # GitHub Pages site
├── dist/                       # Build output (gitignored)
└── Deploy/                     # Release artifacts (gitignored)
```

## GitHub Actions CI

The workflow in `.github/workflows/ci.yml` builds all five targets on a
**Windows runner**:

1. Installs a bootstrap FPC from the official installer
2. Builds the `fpcup` CLI tool from the fpcupdeluxe repository
5. Uses `fpcup` to install FPC, Lazarus, and cross-compilers for
   `x86_64-darwin`, `aarch64-darwin`, and `arm-linux` (including the
   macOS SDK via `--autotools`)
4. Runs `build_all.bat` to build and package all targets (CLI + GUI)
5. Uploads all artifacts

Trigger it manually via **Actions → CI / Cross-Platform Build → Run workflow**.

## License

BSD-3-Clause — see [LICENSE](LICENSE).