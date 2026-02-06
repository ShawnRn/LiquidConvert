<div align="center">

<img src="AppIconSet/icon_512x512@2x.png" alt="LiquidConvert Icon" width="128" style="border-radius: 22px">

# LiquidConvert

**一款采用 "Liquid Glass" 风格的原生 macOS 媒体工厂。**  
*智能拼接、智慧压缩、全能转换。*

[简体中文](./README-CN.md) | [English](./README.md)

</div>

---

## 📖 简介

**LiquidConvert** 不仅仅是一个格式转换器，它是一个基于 SwiftUI 构建的智能化媒体处理中心。它能够感知你的文件上下文：当你拖入多张截图时，它会自动识别并拼接成长图；当你需要通过微信分享大图时，它能智能地将其压缩到 5MB 以内并保持最佳画质。

> **开发初衷**  
> 这最初是我为自己开发的工具。在日常文档编辑工作中，我厌倦了（Tired of）为了简单的图片压缩和拼接而反复打开庞大的 Photoshop。为了解决这个痛点，我开发并不断迭代了这个项目，最终将其打磨成如今拥有完美 "Liquid Glass" 原生界面的 macOS 应用。

应用采用极具现代感的 "Liquid Glass" 设计语言，利用 macOS 原生的视觉效果 (`NSVisualEffectView`)，呈现出半透明、流体般的精致外观。

## ✨ 核心功能

### 1. 🧩 智能长图拼接
告别繁琐的画布设置，一切全自动。
- **智能方向识别**: 算法自动分析图片比例。如果是横屏截图，自动启用**垂直拼接**；如果是竖屏照片或方形图，则建议**水平拼接**。
- **统一比例**: 自动将所有图片缩放到统一宽度（或高度），消除拼接时的丑陋留白。
- **自动优化**: 拼接完成后，自动对超大图像进行智能压缩（目标 < 5MB），方便即时分享。

### 2. ⚡ 智慧压缩引擎
基于底层的 `ImageIO` 框架构建。
- **智能目标控制 ("Auto 5MB")**: 专为社交媒体分享设计。算法会迭代调整压缩质量 (0.9 → 0.3) 和分辨率 (最低至 1080p)，确保文件体积小于 **5MB** 的同时保持最佳肉眼观感。
- **智能跳过**: 如果文件已经达标，则直接跳过处理，避免重复压缩导致的画质劣化。
- **GIF 深度优化**: 支持通过**抽帧**（Frame Sampling）、分辨率调整和颜色量化（Quantization）来大幅减小 GIF 体积。
- **多格式支持**: 完美支持 JPG, PNG, HEIC, WebP, TIFF 互转。

### 3. 🎬 视频 & GIF 实验室
- **Video 转 GIF**:
  - **变速控制**: 支持 0.5x 慢动作到 2.0x 延时摄影效果。
  - **倒放模式 (Reverse)**: 一键制作鬼畜或回旋镖效果的 GIF。
  - 自定义 FPS 和分辨率限制。
- **GIF 转 Video**: 将低效的 GIF 转换为 H.264 编码的 MP4/MOV，提升兼容性。
- **通用转换**: 支持 MP4, MOV, MKV 容器互转。

### 4. 📦 图标工厂 (Icon Factory)
- **一键生成**: 只需拖入一张 1024x1024 的 PNG，自动生成包含所有尺寸（16x16 至 512x512@2x）的标准 macOS `.icns` 文件。
- **资源提取**: 支持反向解包 `.icns` 文件，提取内部的所有图标资源。

### 5. 🎵 音频提取
- 从视频文件中无损提取音频，支持导出为 MP3, FLAC, WAV, M4A。
- 支持批量拖拽处理。

## 🎨 设计与体验

- **Liquid Glass UI**: 深度定制的界面图层，结合原生材质 (`.underWindowBackground`) 与微调的阴影和渐变，带来通透的视觉体验。
- **Dock 智能交互**: 把文件直接拖到 Dock 图标上：
    - 拖入多张图片 → 直接进入**自动拼接**模式
    - 拖入单张图片 → 按默认设置**快速转换**
- **隐私至上**: 所有处理逻辑均在本地运行，无需上传云端。

---

## 📸 截图展示

<div align="center">
  <img src="https://via.placeholder.com/800x500?text=App+Screenshot+Placeholder" alt="Main Interface" width="800">
</div>

---

## ⌨️ 开发构建

### 环境要求
- **macOS 26.0+** (本项目仅在 macOS 26 进行构建测试)
- **Xcode 17.0+**

### 技术栈
- **SwiftUI**: 100% 声明式 UI 构建。
- **AppKit**: 用于窗口管理 (`NSWindow`)、视觉特效 (`NSVisualEffectView`) 和 Dock 交互逻辑。
- **ImageIO / CoreGraphics**: 高性能图片编解码处理。
- **AVFoundation**: 硬件加速的音视频处理。

### 编译运行
1. 克隆仓库:
   ```bash
   git clone https://github.com/ShawnRn/LiquidConvert.git
   ```
2. 使用 Xcode 打开 `LiquidConvert.xcodeproj`.
3. 选择开发团队（或在本地调试时禁用签名）.
4. 运行 (⌘R).

---

## 📜 开源协议

本项目基于 [MIT License](./LICENSE) 开源。

Copyright (c) 2026 Shawn Rain.
