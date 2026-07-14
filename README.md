> This is a vibe-coded project. Developed with ❤️ using Antigravity.

<div align="center">

<img src="pics/icon.png" alt="LiquidConvert Icon" width="128" style="border-radius: 22px">

# LiquidConvert

**A native, "Liquid Glass" design media tool for macOS.**  
*Smart stitching, intelligent compression, and seamless format conversion.*

[简体中文](./README-CN.md) | [English](./README.md)

</div>

---

## 📖 Introduction

**LiquidConvert** is a modern macOS utility built entirely with **SwiftUI**. It goes beyond simple format conversion by integrating "smart context" algorithms: simply **drag screenshots to the Dock icon**, and it automatically determines the best layout for stitching; or drag photos, and it intelligently compresses them to meet file size limits (e.g., <5MB) without visible quality loss.

> **The Story**  
> I built this tool originally for myself. As I frequently edit documentation, I grew tired of launching Photoshop just to stitch screenshots or compress images. What started as a need for efficiency evolved into this application—now featuring a perfect "Liquid Glass" native macOS interface.

Designed with a premium "Liquid Glass" aesthetic, it utilizes standard macOS visual effects (`NSVisualEffectView`) to provide a translucent, native feel that blends perfectly with your workspace.

## Windows x64 edition

LiquidConvert now includes a native Windows x64 edition in [`LiquidConvert.Windows`](./LiquidConvert.Windows). It is built with WinUI 3, Windows App SDK 2.2, per-monitor DPI awareness, and a self-contained runtime.

- Image conversion, compression, stitching, icon creation, audio extraction, video-to-GIF, and document-to-Markdown tools.
- Lark2Pad with clipboard and Markdown import, drag-and-drop, Etherpad export/sync, and rich-text copying for WeChat Official Accounts.
- A bilingual (English / Simplified Chinese) Windows installer that creates a Start Menu shortcut by default and offers desktop shortcut and launch-on-finish choices.

For development and installer instructions, see [the Windows README](./LiquidConvert.Windows/README.md).

## ✨ Core Features

### 1. 🧩 Smart Image Stitching
Stop worrying about canvas sizes or alignment.
- **Auto-Direction**: Intelligent algorithm analyzes your selected images. If it detects mostly landscape screenshots, it stitches logically vertically. If it sees portrait photos, it suggests a horizontal layout.
- **Unified Scale**: Automatically scales all input images to a unified width (or height) to eliminate ugly white borders.
- **Auto Optimize**: The final stitched image is automatically optimized to ensure it doesn't become a massive, share-unfriendly file (Targeting < 5MB).

### 2. ⚡ Intelligent Compression
Powerful compression engine built on `ImageIO`.
- **Target Size Strategy**: The "Auto Compress" mode intelligently targets a **5MB** limit (perfect for WeChat/Email sharing) by iteratively adjusting quality (0.9 → 0.3) and resolution (downscaling to 1080p if necessary).
- **Smart Skip**: If a file is already optimized, it skips processing to prevent re-compression artifacts.
- **GIF Optimization**: Advanced GIF compression with frame sampling (dropping frames), resolution scaling, and color quantization.
- **Formats**: Support for JPG, PNG, HEIC, WebP, and TIFF.

### 3. 🎬 Video & GIF Lab
- **Video to GIF**:
  - Control playback speed (0.5x slo-mo to 2.0x timelapse).
  - **Reverse Playback**: Create fun "boomerang" style looping GIFs.
  - Custom FPS and resolution controls.
- **GIF to Video**: Convert GIFs back to MP4/MOV (H.264) for easier sharing on modern platforms.
- **Format Conversion**: Convert between MP4, MOV, and MKV containers.

### 4. 📦 Icon Factory
- **One-Click Generation**: Drag in a 1024x1024 PNG, get a standard macOS `.icns` file containing all required sizes (16x16 to 512x512@2x).
- **Reverse Engineering**: Drop an existing `.icns` file to extract all internal image resources.

### 5. 🎵 Audio Extraction
- Convert video files to pure audio (MP3, FLAC, WAV, M4A).
- Simple drag-and-drop batch processing.

## 🎨 Design & Experience
- **Liquid Glass UI**: A custom interface layer that uses native macOS materials (`.underWindowBackground`) combined with subtle gradients and shadows.
- **Dock Integration**: Drag files directly to the LiquidConvert icon in the Dock. It intelligently routes them:
    - Multiple images → **Auto Stitch**
    - Single image → **Quick Convert** (based on default settings)
- **Privacy First**: All processing happens locally on your device. No cloud uploads.

---

## 📸 Screenshots

<div align="center">
  <img src="pics/Screenshot-1.png" alt="Main Interface" width="100%" style="border-radius: 8px; box-shadow: 0 4px 8px rgba(0,0,0,0.1);">
  <br><br>
  <img src="pics/Screenshot-2.png" alt="Feature Preview 1" width="48%" style="border-radius: 8px; box-shadow: 0 4px 8px rgba(0,0,0,0.1);">
  <img src="pics/Screenshot-3.png" alt="Feature Preview 2" width="48%" style="border-radius: 8px; box-shadow: 0 4px 8px rgba(0,0,0,0.1);">
</div>

---

## ⌨️ Development

### Requirements
- **macOS 26.0+** (Built and tested on macOS 26)
- **Xcode 26.0+**

### Tech Stack
- **SwiftUI**: 100% Declarative UI.
- **AppKit**: Bridged for window management (`NSWindow`), Visual Effects (`NSVisualEffectView`), and Dock interactions (`AppDelegate`).
- **ImageIO / CoreGraphics**: High-performance, low-level image processing.
- **AVFoundation**: Hardware-accelerated video/audio processing.

### Building
1. Clone the repository:
   ```bash
   git clone https://github.com/ShawnRn/LiquidConvert.git
   ```
2. Open `LiquidConvert.xcodeproj` in Xcode.
3. Ensure signing team is selected (or disable signing for local run).
4. Build and Run (⌘R).

---

## 📜 License

This project is licensed under the [MIT License](./LICENSE).

Copyright (c) 2026 Shawn Rain.
