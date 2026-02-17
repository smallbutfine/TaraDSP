Changelog: IRConvolverPro v1.2 (Integrated Edition)
New Features

    GUI Edition Integrated: Introducing IRConvolverPro-GUI.exe, a full-featured graphical user interface for comfortable single-file processing.
    Hardware Truncation (-l / --len): Added a sample-accurate truncation feature. IRs can now be capped at fixed lengths (e.g., 1024 or 2048 samples) specifically for hardware modelers like Valeton GP-200, Line6 Helix, or Quad Cortex.
    Micro-Fade-Out Logic: Automated 20-sample micro-fade applied during truncation to eliminate digital clicks and ensure smooth signal termination.
    Dual-Mode Processing: The engine now operates in two modes:
        Convolution Mode: Combines two signals (requires -i1 and -i2).
        Utility/Mastering Mode: Processes a single file (requires only -i1). Ideal for re-sampling, bit-depth conversion, and mastering-grade dithering.

DSP & Engine Improvements

    Triple-Engine SRC: Enhanced resampling logic with prioritized fallback: FinalCD (External) > r8brain-free-src (DLL) > libsoxr (DLL) > Linear (Internal).
    Mastering Dither v2: Improved 2nd-order psychoacoustic noise shaping with uncorrelated TPDF dither per channel to preserve stereo image integrity.
    Phase Alignment: Improved Minimum Phase Transform accuracy for time-aligning multi-mic IR setups.

System & UI

    Unified Configuration: Both CLI and GUI editions now share the same settings.ini for consistent branding (Artist, Studio Comments) and default DSP settings.
    Real-time Logging: The GUI now features a dedicated console window to display processing steps, performance metrics, and waveform previews.
    New Deployment Pipeline: Optimized build scripts (deploy-ALL.ps1) for automated packaging of both CLI and GUI editions into a single Win64 distribution.

