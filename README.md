
# VoxAlign v1

![REAPER Version](https://img.shields.io/badge/REAPER-v7.0%2B-007ACC?style=for-the-badge&logo=cockos)
![ReaImGui Version](https://img.shields.io/badge/ReaImGui-v0.9.3%2B-4BC51D?style=for-the-badge)
![Language](https://img.shields.io/badge/Language-Lua%205.3-blueviolet?style=for-the-badge&logo=lua)
![License](https://img.shields.io/badge/License-MIT-green?style=for-the-badge)

**VoxAlign** is an advanced, open-source audio alignment ReaScript for **Cockos REAPER**. It provides studio-grade vocal and instrument alignment directly inside REAPER—without requiring external plugins, third-party executables, or DLL dependencies.

Powered by a **3-Level Pyramidal FastDTW engine**, **4-band spectral Biquad analysis**, and **psychoacoustic breath protection**, VoxAlign automatically synchronizes double-tracked vocals, backing choirs, acoustic instruments, and percussive takes with sub-frame accuracy.

---

## ✨ Features

* **100% Pure Lua Engine**: Lightweight, fully open-source, and cross-platform (Windows, macOS, Linux).
* **Pyramidal FastDTW Search (Module B)**: Hierarchical 3-level resolution matrix ($1/16 \to 1/4 \to 1/1$) delivering $O(N)$ quasi-linear performance on long items.
* **Psychoacoustic Breath Protection (Module C)**: Identifies inhalations via high-frequency Air energy vs. Sub-bass ratios, preventing time-stretch artifacts and unnatural breath distortion.
* **4-Band Spectral DSP**: Direct Form I Biquad Butterworth filters divide signals into Sub, Mid, Presence, and Air bands for precise feature correlation.
* **Macro Pre-Alignment Engine**: Combines Audio Fingerprinting (peak-pair hashes) and WLNCC cross-correlation to physically shift Dub items before micro-alignment begins.
* **Itakura Slope Parallelogram**: Geometrically constrains time warping to prevent unnatural time compression or "staircase" artifacts.
* **Asynchronous Non-Blocking UI**: Slices heavy DSP matrix calculations into 12ms time budgets via `reaper.defer`, ensuring REAPER's GUI never freezes.
* **Click-Free Processing**: Snaps stretch markers to source zero-crossings and applies customizable stretch fades.

---

## 📸 Screenshots

<img width="800" height="427" alt="2026-08-1310-31-09-ezgif com-video-to-gif-converter(1)" src="https://github.com/user-attachments/assets/ec005d19-20e1-447d-9104-a4b64b536e6c" />

---

## 🛠️ Requirements & Installation

### Requirements
* **Cockos REAPER** v7.0 or higher.
* **ReaImGui** extension v0.9.3 or higher (available via ReaPack).

---
Manual Installation

1. Download `VoxAlign_v14.15.0.lua` from the [Latest Releases](https://www.google.com/search?q=https://github.com/YOUR_USERNAME/YOUR_REPOSITORY/releases).
2. Open REAPER and open the Action List (**Actions** $\to$ **Show action list...** or press `?`).
3. Click **New action...** $\to$ **New ReaScript...**
4. Select `VoxAlign_v1.lua` and save it.

---

## 🚀 Quick Start Guide

```
+-----------------------------------------------------------------------------------+
|  1. Select Reference Item  -->  Click [ Capture REFERENCE ]                       |
|  2. Select Dub Item(s)     -->  Click [ Capture DUBS ]                            |
|  3. Select Preset          -->  Choose preset (e.g. Double Tracking)             |
|  4. Align                  -->  Click [ ALIGN ]                                   |
+-----------------------------------------------------------------------------------+

```

1. **Capture Reference**: Select the master timing track item and click **Capture REFERENCE**.
2. **Capture Dubs**: Select one or more target items you wish to align and click **Capture DUBS**.
3. **Select a Preset**: Choose a preset tailored to your audio material:
* **`2 Mics / Same Take`**: Phase-alignment only (rigid shift, no stretch markers).
* **`Double Tracking`**: Tight alignment (90% strength) for overdubbed lead vocals.
* **`Backing Vocals`**: Flexible alignment (80% strength) for natural multi-singer harmonies.
* **`Harmonic Instrument`**: Tuned for acoustic guitars, pianos, and string sections.
* **`Percussive / Bass`**: High transient sensitivity for drums and plucked bass.


4. **Execute**: Click **ALIGN**.

---

## 🧠 Algorithmic Workflow

```
+-----------------------------------------------------------------------+
|                         AUDIO INPUT (Ref & Dubs)                      |
+-----------------------------------------------------------------------+
                                    |
                                    v
+-----------------------------------------------------------------------+
| STEP 1: MACRO ALIGNMENT (Fingerprint / WLNCC Cross-Correlation)       |
| -> Calculates global time offset -> Performs Rigid Item Shift         |
+-----------------------------------------------------------------------+
                                    |
                                    v
+-----------------------------------------------------------------------+
| STEP 1.5: 4-BAND DSP & FEATURE EXTRACTION                             |
| -> Biquad Filters: Low (<300Hz), Mid (300-2.5k), High (2.5k-6k), Air (>6k)|
| -> Extracts RMS, ZCR, High-Frequency Spectral Flux, Delta RMS          |
| -> SegmentBlobs: Vocal Blob Mapping & Gap Bridging                    |
| -> Module C: Psychoacoustic Breath Protection Marking                 |
+-----------------------------------------------------------------------+
                                    |
                                    v
+-----------------------------------------------------------------------+
| STEP 2: FASTDTW PYRAMIDAL WARPING ENGINE (Module B)                   |
| -> Level 3 (1/16 Resolution): Coarse global path search              |
| -> Level 2 (1/4 Resolution): Corridor-guided refinement               |
| -> Level 1 (1/1 Resolution): Fine alignment + Itakura Constraint Band |
+-----------------------------------------------------------------------+
                                    |
                                    v
+-----------------------------------------------------------------------+
| POST-PROCESSING & MARKER PLACEMENT                                    |
| -> Smart Anchor Filtering (Confidence, Physical Drift Check, Breaths) |
| -> Sub-Frame Micro-Alignment & Zero-Crossing Snapping                 |
| -> Apply Stretch Markers to Take                                      |
+-----------------------------------------------------------------------+

```

---

## 📊 Preset Overview

| Preset Name | Target Material | Rigid Shift | Stretch Markers | Align Strength | Drift Limit | Breath Protect |
| --- | --- | --- | --- | --- | --- | --- |
| **`2 Mics / Same Take`** | Phase alignment (2 mics, 1 take) | Yes | No | N/A | $0.060\text{s}$ | Disabled |
| **`Double Tracking`** | Overdubbed lead vocals | Yes | Yes | 90% | $0.120\text{s}$ | **Enabled** |
| **`Backing Vocals`** | Multi-vocal choirs & harmonies | Yes | Yes | 80% | $0.150\text{s}$ | **Enabled** |
| **`Harmonic Instrument`** | Guitars, pianos, strings | Yes | Yes | 85% | $0.150\text{s}$ | Disabled |
| **`Percussive / Bass`** | Drums, percussion, bass guitar | Yes | Yes | 95% | $0.100\text{s}$ | Disabled |


---

## 📜 License

VoxAlign is open-source software distributed under the terms of the GNU General Public License v3.0.

```text
VoxAlign — Advanced Temporal Alignment ReaScript for REAPER
Copyright (C) 2026 Acrosonus Mastering & Contributors

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program. If not, see <https://www.gnu.org/licenses/>.

```


---

## 🙏 Acknowledgments

* **Cockos REAPER Team** for providing an extraordinary API and ReaScript ecosystem.
* **cfillion** for maintaining ReaImGui and ReaPack.
* The REAPER Community for testing and feedback.

```


```
