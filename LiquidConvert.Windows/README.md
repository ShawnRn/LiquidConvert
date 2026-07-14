# LiquidConvert for Windows

Native Windows x64 edition of LiquidConvert, built with WinUI 3 and the self-contained Windows App SDK runtime.

## Included tools

- Image conversion, JPEG target-size compression, and vertical image stitching.
- Audio extraction and video-to-GIF conversion through FFmpeg.
- Windows `.ico` generation.
- Text/HTML-to-Markdown export.
- Lark2Pad: clipboard import, Markdown/TXT import or drag-and-drop, Markdown/Etherpad/WeChat rich-text copying, Etherpad HTML export, and authenticated Pad sync.

## Development

Requirements: Windows 10 1809 or later, .NET 10 SDK, and FFmpeg on `PATH` for media operations.

```powershell
dotnet run --project LiquidConvert.Windows/LiquidConvert.Windows.csproj -r win-x64
```

The application opens at 1376 × 936 and intentionally cannot be resized below that design size. It is per-monitor DPI aware and bundles the Windows App SDK runtime for release builds. The installer also includes Microsoft's x64 WebView2 Evergreen offline runtime so Lark2Pad login works on PCs that do not already have WebView2 installed.

The built-in Settings panel persists the theme preference, an optional default output folder, and lets users clear the saved Lark2Pad Etherpad session.

## Build an installer

Install [Inno Setup](https://jrsoftware.org/isinfo.php), then run:

```powershell
./scripts/build_windows_installer.ps1
```

The generated installer is placed in `artifacts/windows/`. It creates a Start Menu shortcut by default and offers a desktop shortcut and launch-on-finish option. The installer supports English and Simplified Chinese.
