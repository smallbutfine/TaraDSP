# TaraDSP — The Producer's Manual

**A comprehensive guide to convolution, impulse responses, and mastering-grade audio processing with TaraDSP.**

Written for musicians, audio engineers, mastering engineers, and producers.

---

## Table of Contents

1. [What is TaraDSP?](#1-what-is-taradsp)
2. [The Science of Convolution](#2-the-science-of-convolution)
3. [Impulse Responses: The Sonic DNA](#3-impulse-responses-the-sonic-dna)
4. [The Processing Chain](#4-the-processing-chain)
5. [Mastering Dither](#5-mastering-dither)
6. [Minimum Phase](#6-minimum-phase)
7. [Resampling](#7-resampling)
8. [Fades and Trimming](#8-fades-and-trimming)
9. [Practical Workflows](#9-practical-workflows)
10. [Tips from the Trenches](#10-tips-from-the-trenches)
11. [Technical Reference](#11-technical-reference)

---

## 1. What is TaraDSP?

TaraDSP is a professional audio processing tool that does one thing exceptionally well: **FFT-based convolution**. If you've ever used a guitar cabinet simulator, a convolution reverb, or a mastering chain with analog-modeled EQ, you've used convolution.

TaraDSP gives you that power in a lightweight, cross-platform package. Windows, macOS, Linux. CLI for batch processing, GUI for interactive work.

---

## 2. The Science of Convolution

### What convolution does

Convolution applies the sonic characteristics of one signal (the **impulse response**) to another (your audio). When you play a dry guitar through a cabinet, the cabinet colors the sound — resonances, frequency response, decay. Convolution mathematically applies that coloring.

### Why FFT?

Direct convolution is O(n²) — billions of operations for a 1-second file. The FFT reduces this to O(n log n) via the **convolution theorem**:

> Convolution in time = Multiplication in frequency

1. FFT both signals → frequency domain
2. Multiply them → one multiply per bin
3. Inverse FFT → back to time domain

**5000× speedup.** PFFFT further accelerates with SIMD (SSE/NEON) — 4-8 samples per instruction.

---

## 3. Impulse Responses: The Sonic DNA

An impulse response is a recording of a click through a system, capturing its complete sonic fingerprint.

| Type | Captures | Length | Use case |
|---|---|---|---|
| Cabinet IR | Speaker + cab + mic | 0.5–2s | Guitar/bass cab sim |
| Room IR | Room acoustics | 1–4s | Convolution reverb |
| Hardware IR | EQ, compressor, tape | 0.1–1s | Analog gear emulation |
| Plate/Spring IR | Mechanical reverb | 1–3s | Vintage reverb |

**Where to find them:** Free IR libraries (Guitar Hack, God's Cab, Seacow), commercial (Celestion, Redwirez, York Audio), or DIY (click through your cab, record with a mic).

---

## 4. The Processing Chain

When you run TaraDSP, audio passes through this chain. Each step is optional.

### Step 1: Load Input
Reads WAV (8/16/24/32-bit PCM or float), converts to 32-bit float internally.

### Step 2: Load IR (optional)
If no IR specified → passthrough mode (mastering only: dither, normalize, fades).

### Step 3: Trim Silence (optional)
`-t <dB>` — removes silence below threshold from IR. Typical: -60 dB.

### Step 4: Apply Fades (optional)
`-f <ms>` — fade-out on IR. Always applies 1ms fade-in (click prevention).

### Step 5: Resample (optional)
`-r <Hz>` — resamples input + IR to target rate. Engine priority: SoX (libsoxr) → R8Brain → FinalCD → linear.

### Step 6: Convolve
FFT convolution via PFFFT. Output length = input + IR - 1 samples.

### Step 7: Minimum Phase (optional)
`--min` — removes pre-ringing, reduces latency. Uses real cepstrum method.

### Step 8: Normalize
Peak normalize to 1.0 (0 dBFS).

### Step 9: Truncate (optional)
`-l <samples>` — limit output length. For modelers: 1024 (GP-200), 2048 (Helix).

### Step 10: Dither and Save
`-b <16|24|32>` — 16-bit gets TPDF dither + error feedback. 24/32-bit: no dither.

---

## 5. Mastering Dither

### The problem
Quantizing 24-bit to 16-bit without dither creates harmonic distortion at low levels.

### The solution: TPDF
Adds 2 LSB of triangular noise before quantization. Converts distortion to a constant noise floor — less audible, more natural.

TaraDSP's implementation:
- **TPDF noise**: Two random values summed (triangular distribution)
- **Error feedback**: Quantization error fed back, shaping the noise spectrum
- **Signal-dependent scaling**: 70% dither at very low levels (< -90 dBFS)

### When to use
- **Always dither for 16-bit** — always better than truncation
- **Never dither for 24/32-bit** — quantization error is below the noise floor
- **Dither once** — at the final output stage only

---

## 6. Minimum Phase

### Pre-ringing
Linear-phase IRs have symmetric energy — before AND after the main impulse. The energy before is **pre-ringing**, which sounds unnatural (in nature, sound arrives after, never before).

### What minimum phase does
Transforms a linear-phase IR into minimum phase:
- No pre-ringing
- Lower latency
- Same frequency response (magnitude unchanged)

### Algorithm
Real cepstrum method: FFT → log magnitude → inverse FFT (cepstrum) → fold → FFT → complex spectrum → inverse FFT.

### When to use
- **Always for cabinet simulation** — removes the "hollow" sound
- **Always for real-time** — lower latency
- **Optional for reverb** — some prefer linear-phase spaciousness

---

## 7. Resampling

### Why
- Mismatched rates (44.1k IR, 48k project)
- Target device expects specific rate
- CD release (44.1k)

### Aliasing
Downsampling without filtering causes frequencies above Nyquist to fold back as metallic artifacts.

### Engine priority
1. **SoX Resampler (libsoxr)** — VHQ, proper anti-aliasing. Best option.
2. **R8Brain** — VHQ, used when libsoxr unavailable.
3. **FinalCD** — external tool.
4. **Linear interpolation** — fallback, no anti-aliasing.

Install libsoxr for best results. Ships as `libsoxr.dll` / `.dylib` / `.so.0`.

---

## 8. Fades and Trimming

### Trim silence
IRs often have silence at start/end. Trim removes it:
- `-60` — typical for IRs
- `-80` — aggressive
- `0` — disabled

### Fades
- **Fade-in**: Always 1ms (automatic) — prevents start clicks
- **Fade-out**: User-specified (`-f <ms>`) — prevents end clicks

Linear gain ramp: 1.0 → 0.0 (fade-out) or 0.0 → 1.0 (fade-in).

---

## 9. Practical Workflows

### Guitar Cabinet Simulation
```bash
TaraDSP -x guitar_di.wav -y cab_57.wav -o guitar_amped.wav --min -l 2048 -b 24
```

### Convolution Reverb
```bash
TaraDSP -x vocal_dry.wav -y concert_hall.wav -o vocal_reverb.wav -f 100 -b 24
```

### Mastering with Dither
```bash
TaraDSP -x mix_24bit.wav -o master_16bit.wav -b 16
```

### Sample Rate Conversion
```bash
TaraDSP -x recording_96k.wav -o master_44k1.wav -r 44100 -b 16
```

### Batch Processing
```bash
for %f in (*.wav) do TaraDSP -x "%f" -y cab_ir.wav -o "processed_%f" --min -b 24
```

---

## 10. Tips from the Trenches

### IR selection
- **Shorter = tighter**: 0.5s IR has less low-end rumble than 2s
- **Mic position matters**: on-axis = bright, off-axis = dark
- **Distance adds room**: close-miked = dry, room-miked = spacious
- **Minimum phase is almost always better for cabs**

### Level management
- **Normalize after convolution**, not before
- **Use 24-bit throughout** — dither only at final output
- **Check mono compatibility** — stereo IRs can have phase issues

### Common mistakes
- **Linear-phase IRs for cabs** — always use `--min`
- **Dithering multiple times** — dither once, at the end
- **Forgetting to normalize** — convolution can boost 6-12 dB
- **16-bit for intermediate files** — use 24-bit or 32-bit

---

## 11. Technical Reference

### CLI Options

| Option | Long form | Value | Description |
|---|---|---|---|
| `-x` | `--in1` | `<file>` | Input WAV file |
| `-y` | `--in2` | `<file>` | IR WAV (optional) |
| `-o` | `--output` | `<file>` | Output WAV |
| `-b` | `--bits` | `16\|24\|32` | Bit depth (default: 24) |
| `-r` | `--rate` | `<Hz>` | Target sample rate |
| `-l` | `--length` | `<samples>` | Truncate length |
| `-t` | `--trim` | `<dB>` | Trim silence threshold |
| `-f` | `--fade` | `<ms>` | Fade-out duration |
| `-m` | `--mono` | (flag) | Mono output |
| | `--min` | (flag) | Minimum phase |
| `-h` | `--help` | (flag) | Show help |

### Configuration File

```ini
[Metadata]
Artist=Your Studio Name

[Audio]
TargetBits=24
DitherAmount=1.0

[Hardware]
TruncateLen=0
```

### Exit Codes

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | Error |

---

## Glossary

| Term | Definition |
|---|---|
| Convolution | Applying one signal's characteristics to another |
| IR | Impulse response — sonic fingerprint of a system |
| FFT | Fast Fourier Transform |
| PFFFT | Pretty Fast FFT — audio-optimized FFT library |
| Minimum Phase | No pre-ringing, energy at and after impulse |
| Linear Phase | Symmetric pre- and post-ringing |
| Pre-ringing | Energy before the main impulse |
| TPDF | Triangular PDF dither — converts distortion to noise |
| Error Feedback | Feeding quantization error back to shape noise |
| Aliasing | High frequencies folding back as artifacts |
| Nyquist | Half the sample rate — highest representable frequency |
| Normalization | Scaling peak to 0 dBFS |
| Cepstrum | Inverse FFT of log magnitude — for minimum phase |