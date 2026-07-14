# LiquidConvert Contributor Guide

## Repository layout

- `LiquidConvert/` — the existing SwiftUI macOS application.
- `LiquidConvert.Windows/` — the Windows x64 application built with WinUI 3 and Windows App SDK.
- `installer/` — Inno Setup definition for the Windows installer.
- `scripts/` — repeatable local build and packaging commands.

## Windows development

- Target: Windows x64 only, .NET 10, WinUI 3, Windows App SDK 2.2.
- Keep `WindowsPackageType=None`, `SelfContained=true`, and `WindowsAppSDKSelfContained=true`: the installed app must not require end users to install .NET or the Windows App Runtime.
- Run `dotnet build LiquidConvert.Windows/LiquidConvert.Windows.csproj -c Debug -r win-x64` after every Windows change.
- Preserve per-monitor V2 DPI awareness and the window minimum size. The default and minimum window size are both 1376 × 936.
- Use the high-resolution PNG logo in in-app UI. Keep `Assets/AppIcon.ico` and the package logo assets in sync when changing the application icon.
- The executable must keep `<ApplicationIcon>Assets\AppIcon.ico</ApplicationIcon>` so Start Menu and shortcut icons use the same multi-size asset as the title bar.
- Lark2Pad must support clipboard import, Markdown import and drag-and-drop, Etherpad HTML, rich-text copying for WeChat Official Accounts, file export, and authenticated Pad synchronization.

## Windows release process

1. Run `scripts/build_windows_installer.ps1` from PowerShell.
2. Verify the generated `artifacts/windows/LiquidConvert-Setup-x64-v<version>.exe` on a clean user profile when possible.
3. Commit source, installer script, and documentation. Never commit `bin/`, `obj/`, or generated installer artifacts.
4. Push to `main`, then create/upload the release with GitHub CLI.

The Inno Setup installer always creates a Start Menu entry. It offers optional desktop shortcut creation and optional launch at the final page, includes Simplified Chinese and English installer languages, and bundles Microsoft's x64 WebView2 offline runtime for Lark2Pad.
