# Align Takes — Async v13.0.0

> **Hybrid high-precision temporal alignment for REAPER**
> Multi-feature DTW · Parabolic sub-frame interpolation · Melodyne-style vocal segmentation

---

## Overview

**Align Takes** is a REAPER script (Lua + ReaImGui) designed to automatically align vocal takes (dubs, overdubs, ADR) to a reference take. It combines three complementary analysis methods to produce precise, musically natural alignment — without robotic-sounding artifacts.

The script places **Stretch Markers** directly on target audio items, with **sub-frame precision** achieved through parabolic interpolation.

---

## Features

### Step 1 — Global Macro-Alignment
Detects and corrects the global time offset between the reference and each dub using a voting system across three methods:

- **Fingerprint** — acoustic fingerprinting via envelope peak hashing
- **Waveform** — normalized cross-correlation (NCC) with sub-sample parabolic interpolation
- **Envelope** — multi-band RMS envelope correlation

**AUTO** mode automatically selects the most reliable method by consensus. `FINGERPRINT`, `WAVEFORM`, and `ENVELOPE` modes allow forcing a specific method.

### Step 1.5 — Vocal Segmentation (Melodyne-style)
Identifies active tonal regions ("Blobs") in the vocal signal by combining:

- **RMS** with an adaptive threshold based on the noise floor
- **ZCR** (Zero Crossing Rate) to distinguish tonal sounds from noise
- **Spectral Flux** to detect consonants and transients
- **Gap Bridging** to merge nearby blobs into continuous regions

Only valid signal zones participate in DTW alignment, preventing erratic anchors on silences or breaths.

### Step 2 — DTW Micro-Alignment (Dynamic Time Warping)
Asynchronous chunked DTW with multi-feature analysis, including:

- **Slope Penalty** to prevent staircase artifacts and force smooth, natural warping paths
- **Per-anchor confidence scoring** (`flux_score + energy_score`) to reject unreliable warp points
- **Dynamic micro-alignment windows** based on attack type (ONSET / START / END)
- **Sub-frame parabolic interpolation** on Spectral Flux for positioning finer than a single hop
- **Optional Zero Crossing** snapping to place markers exactly at zero-crossings (click prevention)
- **Adjustable alignment strength** (0–100%) for a natural blend between original and target

---

## Requirements

| Dependency | Minimum Version |
|---|---|
| REAPER | 7.0+ |
| [ReaImGui](https://github.com/cfillion/reaimgui) | 0.9.3+ |

---

## Installation

1. Copy `align_13.lua` into your REAPER Scripts folder:
   - Windows: `%APPDATA%\REAPER\Scripts\`
   - macOS: `~/Library/Application Support/REAPER/Scripts/`
2. In REAPER: **Actions → Show action list → Load…** → select the file
3. Assign a keyboard shortcut or run it directly from the action list

---

## Usage

1. **Select all items** to align (reference + dubs)
2. Click **Capture REFERENCE** — the first selected item becomes the reference
3. Click **Capture DUBS** — all other selected items are registered as targets
4. Adjust parameters as needed (see below)
5. Click **ALIGN** — Stretch Markers are placed automatically
6. If the result is unsatisfactory: **Remove stretch markers** to revert

> The **ALIGN** button hooks into REAPER's native Undo system. `Ctrl+Z` restores the previous state.

---

## Parameters

### Macro-Alignment
| Parameter | Description |
|---|---|
| `Enable Macro-Alignment` | Enables / disables Step 1 |
| `Rigid Align` | Physically moves the item in the project timeline in addition to markers |
| `max_shift_sec` | Maximum offset searched (in seconds) |
| `method` | AUTO / FINGERPRINT / WAVEFORM / ENVELOPE |

### Segmentation
| Parameter | Description |
|---|---|
| `ZCR Max (Tonality)` | Zero Crossing Rate threshold — lower values restrict alignment to vowels only |
| `Consonant Sensitivity (Flux)` | Sensitivity to consonants and transients |
| `Gap Bridging (ms)` | Maximum silence duration between two blobs before merging them |

### DTW & Micro-Alignment
| Parameter | Description |
|---|---|
| `Minimum local confidence` | Minimum score for an anchor to be kept (0 = keep all, 0.5 = very selective) |
| `DTW Anti-staircase` | Slope penalty to force smooth and natural DTW paths |
| `Max stretch ratio` | Maximum allowed stretch ratio per segment |
| `Alignment strength` | 1.0 = full alignment, 0.5 = halfway between original and target |
| `Dynamic micro-alignment` | Enables adaptive windows based on attack type |
| `Zero Crossing` | Snaps markers to zero-crossings to prevent clicks |

---

## Technical Architecture

```
align_13.lua
├── Fingerprint Engine     — acoustic fingerprinting via peak hashing
├── Waveform Correlator    — NCC with sub-sample parabolic interpolation
├── Envelope Correlator    — multi-band RMS correlation
├── Adaptive Selector      — automatic consensus between the 3 methods
├── Blob Segmenter         — adaptive detection of active vocal regions
├── DTW Engine (chunked)   — asynchronous DTW with slope penalty
├── Anchor Extractor       — confidence filtering + sub-frame refinement
└── Stretch Marker Writer  — final placement with ZCR snapping and ratio validation
```

DTW computation is **chunked and asynchronous** (via `reaper.defer`) to keep the UI responsive during processing.

---

## Author

**Acrosonus Mastering**

---

## License

Free for personal and professional use. Redistribution with attribution required.
