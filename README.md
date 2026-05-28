# VOXALIGN

Align Takes 

A high-performance, asynchronous time-alignment script for REAPER. Designed for vocal and instrument multi-take alignment, this tool combines Dynamic Time Warping (DTW), Melodyne-style segmentation, and sub-frame parabolic interpolation to deliver incredibly transparent and phase-coherent results.

Authors: Acrosonus Mastering & Gemini
🚀 Key Features

    Asynchronous Processing: Powered by an async state machine to keep REAPER's UI responsive during heavy processing.

    Step 1: Smart Macro-Alignment: Automatically shifts items based on a consensus between audio fingerprinting, waveform cross-correlation, and envelope matching. Includes a "Rigid Align" option to physically move items before stretching.

    Step 1.5: Melodyne-Style Segmentation: Maps vocal "blobs" intelligently. Uses Zero-Crossing Rate (ZCR) and transient flux to differentiate tonal audio from noise/consonants, ensuring stretch markers are only placed where they belong.

    Step 2: Next-Gen DTW (Dynamic Time Warping): * Anti-Staircase Penalty: Enforces a slope penalty to prevent unnatural, robotic time-warping.

        Smart Anchors: Filters out unreliable mapping points using local confidence scoring.

        Sub-Frame Precision: Uses parabolic interpolation to find peaks between actual samples, achieving micro-alignment without digital artifacts.

    Click-Free Stretching: Automatically snaps stretch markers to the nearest zero-crossing.

📋 Requirements

    REAPER: Version 7.0 or higher.

    ReaImGui: Version 0.9.3 or higher (available via ReaPack).

🛠 Installation

    Make sure you have ReaPack installed in REAPER.

    Install the ReaImGui extension via ReaPack.

    Download the align 13.lua file.

    In REAPER, go to Actions > Show action list.

    Click on New action > Load ReaScript... and select the downloaded .lua file.

📖 How to Use

The workflow is divided into capturing your sources and applying the alignment.
1. Capture Sources

    Select your Reference media item (the guide track) and click "Capturer RÉFÉRENCE".

    Select your Dub media item(s) (the takes to be aligned) and click "Capturer DUBS".

2. Configure Parameters

    Étape 1 (Macro): Enable this to calculate the global offset between the files. Enable Rigid Align to physically move the dub items on the timeline before applying stretch markers.

    Étape 1.5 (Segmentation): Restricts stretching to active vocal "blobs". You can tweak the ZCR Max (tonality), Transient Sensitivity, and Gap Bridging (minimum distance between blobs).

    Étape 2 (Micro-Alignment): Fine-tune the localized stretch markers.

        Confiance locale minimum: Filters out bad DTW anchors.

        Anti-escalier DTW: Forces a natural fluid stretch instead of brutal shifts.

        Force d'alignement: Blend knob (0.1 to 1.0) for the alignment strength.

3. Process

    Click "ALIGNER".

    You can easily revert the process using the REAPER Undo history or by clicking "Supprimer stretch markers" within the script UI.

🔍 Diagnostic Output

The script features a built-in diagnostic log window at the bottom of the UI. It provides real-time feedback on synchronization methods used, the number of vocal blobs detected, threshold levels, and how many stretch markers were successfully placed or rejected.
