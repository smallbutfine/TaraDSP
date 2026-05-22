🌐 TaraDSP Documentation (v1.2)
Welcome to the official documentation for TaraDSP, the professional high-performance FFT toolkit for audio / Impulse Response (IR) processing, developed in Free Pascal.
1. Introduction
TaraDSP is designed for audio engineers and hardware modeler users (e.g., Valeton GP-200, Line6 Helix) who require surgical precision, high-speed batch processing, and mastering-grade output quality.
Key Technologies

    Engine: SIMD-accelerated PFFFT (
    complexity).
    Resampling: Triple-Engine Sinc Interpolation (FinalCD > r8brain > libsoxr).
    Mastering: 2nd-Order Psychoacoustic Noise Shaping & Uncorrelated TPDF Dither.

2. Editions
We provide two distinct editions to suit your workflow:
Edition	Purpose	Best For
CLI Edition	Automation & Scripting	Batch processing entire IR libraries.
GUI Edition	Visual & Quick Edits	Single file mastering and visual waveform check.
3. Command Line Interface (CLI) Reference
Run TaraDSP -h to see all options.
Basic Syntax
bash

TaraDSP -i1 <source> [-i2 <ir_file>] -o <output> [options]


Essential Flags

    -i1 <file>: Source audio file (WAV).
    -i2 <file>: (Optional) Impulse Response for convolution.
    -o <file>: Output destination.
    -b <16|24|32>: Output bit depth (default: 24).
    -l <samples>: Hardware Mode. Truncates IR to fixed length with micro-fade.
    -m: Force mono mixdown (sums all channels).

4. Professional Features
💎 Mastering-Grade Dithering
When exporting to 16-bit, TaraDSP applies uncorrelated TPDF dither per channel. This preserves stereo width and depth. The integrated 2nd-Order Noise Shaper pushes quantization noise into the ultra-high frequency range (>16kHz), ensuring an "inky black" background.
⚡ Hardware Optimization
Targeting a hardware modeler? Use the -l 1024 or -l 2048 flag. Our engine applies a 20-sample micro-fade before the cut to eliminate digital clicks, ensuring your hardware loads the IR seamlessly.
📐 Minimum Phase Transform
Use --min to align the impulse energy to Sample 0. This is crucial for Time-Alignment when mixing multiple microphone IRs to avoid phase cancellation.
5. Configuration (settings.ini)
Customize the toolkit behavior globally. The settings.ini is shared between CLI and GUI.
ini

[Metadata]
Artist=Your Studio Name     ; Embedded in the IART tag
[Audio]
TargetBits=24               ; Default bit depth
DefaultGain=-0.1            ; Safety headroom in dB

6. System Requirements & Binaries

    OS: Windows 10/11 (64-bit recommended).
    CPU: AVX2 support highly recommended for maximum FFT speed.
    Libraries: Ensure libpffft.dll, r8bsrc.dll, and libsoxr.dll are in the application folder.

7. License
TaraDSP is released under the BSD 3-Clause License. You are free to use, modify, and distribute the software as long as the original copyright notice is preserved.
