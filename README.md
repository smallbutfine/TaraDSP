🚀 Release: TaraDSP v1.0.0 (Mastering Edition)
We are proud to announce the first stable release of TaraDSP, a high-performance, command-line driven toolkit for professional Impulse Response (IR) processing. Built with Free Pascal, it combines mathematical precision with mastering-grade audio aesthetics.
🌟 Key Features
1. High-Performance Convolution Engine

    FFT Powered: Utilizes the PFFFT (SIMD-accelerated) library for
    efficiency.
    Zero-Latency Processing: Handles large IRs (up to several seconds) in milliseconds.
    Minimum Phase Transform: Optional time-alignment via Real Cepstrum to align various IRs to Sample 0.

2. Mastering-Grade Resampling & Dithering

    Triple-Engine SRC: Seamless integration of FinalCD (Ultra-VHQ), libsoxr (VHQ), and r8brain-free-src (VHQ) for aliasing-free sample rate conversion.
    Advanced Dithering: 2nd-Order Psychoacoustic Noise Shaping with Uncorrelated TPDF Dither (per channel) to preserve stereo width and depth at 16-bit.
    Dynamic Scaling: Intelligent dither amplitude modulation based on signal energy.

3. Professional DSP Suite

    Surgical Filters: 12dB/octave Butterworth High-Pass and Low-Pass filters.
    Stereo Management: Full Mid-Side (MS) width control and linear Stereo-to-Mono mixdown.
    Signal Integrity: Sample-accurate silence trimming, linear fades (In/Out), and phase inversion.

4. Technical Excellence

    Clean WAV Export: Automatic Chunk Stripping for 100% compatibility with hardware modelers (Helix, Kemper, Quad Cortex).
    Metadata Branding: Embed your studio info (Artist, Title, Comments) directly into the RIFF headers.
    CLI & Automation: Optimized for batch processing with a standardized exit-code system (Industrial Standard).

📦 Installation (Windows 64-bit)

    Download the TaraDSP_Win64_v1.0.zip from the assets below.
    Extract all files (including libpffft.dll, libsoxr.dll, and r8bsrc.dll) into a single folder.
    Open your terminal and type TaraDSP -h to see all available options.

🛠 Build from Source

    Requirements: Lazarus 2.2.0+ or FPC 3.2.2+.
    Run the provided deploy.ps1 script to build the optimized release version.

📜 License & Credits

    License: BSD 3-Clause License
    Credits: Special thanks to Julien Pommier (PFFFT), Aleksey Vaneev (r8brain-free-src), and the libsoxr team.


    Final Note: The binary package is optimized for AVX2-capable CPUs. For older systems, please recompile using the -CfSSE3 flag in the provided .lpi file. BSD-3-Clause License r8brain-free-src Documentation PFFFT Pascal Binding



## Build Instructions
1. Ensure the `lazbuild` utility (Lazarus/FPC) is in your system PATH.
2. Place `libpffft.dll` (Windows) or `libpffft.so` (Linux) in the project root.
3. Run the provided build scripts:
   - Windows: `build.bat`
   - Linux: `./build.sh`

## CLI Usage
```bash
./TaraDSP -i1 [input_file_or_dir] -i2 [master_ir] -o [output] -b 24
