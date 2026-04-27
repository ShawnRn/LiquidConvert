---
description: 自动化提取归档、打 DMG 包、生成 Sparkle 双架构签名并发布至 GitHub Release
---

# `LiquidConvert` 自动化打包与发布流程

本工作流将帮助您自动化执行 macOS 应用的新版本构建、创建不同架构(`x86_64` / `arm64`) 的 DMG 安装包，更新 `appcast.xml`（插入两种 CPU 架构各自的下载地址及安全签名），以及提交新包到 GitHub Release。

## 前置要求
1. **GitHub CLI (`gh`)**：确保您已经登录（`gh auth status`）。
2. **发布环境准备完毕**：请确认业务逻辑代码已暂存提交。

## 执行步骤

### 第一步：更新流水号
修改 Xcode 项目里的新版本号（`MARKETING_VERSION`）及构建流水号（`CURRENT_PROJECT_VERSION`）。

### 第二步：触发自动打包双份 DMG
运行以下编译归档脚本，自动调用 `xcodebuild archive` 对 `arm64` 及 `x86_64` 进行构建并交由 `create-dmg` 对它们进行包装，最终将放置于 `releases/` 下。

// turbo
```bash
./scripts/build.sh release
```

### 第三步：推送文件至 GitHub Release
发布您的二进制安装产物。
*(⚠️ 同样需要在执行本命令内指明真实版本号)*

```bash
VERSION="<YOUR_NEW_VERSION>"
gh release create "v$VERSION" "releases/LiquidConvert_${VERSION}_arm64.dmg" "releases/LiquidConvert_${VERSION}_x86_64.dmg" \
  --title "LiquidConvert $VERSION" \
  --notes "在此输入更新日志"
```

### 第四步：用远端资产生成 Sparkle appcast
GitHub Release 创建并确认两个 DMG 都能下载后，再调用发布脚本生成 `appcast.xml`。该脚本会优先重新下载 GitHub Release 上真实可被用户下载到的资产，并以远端字节生成 `length` 与 `sparkle:edSignature`。

如果本机没有 `SPARKLE_PRIVATE_KEY` 或 Sparkle Keychain 私钥，不要继续生成本地 appcast。先确认 `release.sh` 会在签名失败时退出，再手动触发 GitHub `Release` workflow 并勾选 `update_appcast`，让 Actions 使用仓库 secret 生成 appcast。

// turbo
```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/release.sh "$VERSION"
xmllint --noout appcast.xml
```

### 第五步：最后单独提交 Appcast
在以上步骤完全跑通且 GitHub Release 能正常访问您的归档后，单独提交并推送 `appcast.xml`，这是 Sparkle 更新对用户生效的最后一步。

// turbo
```bash
git add appcast.xml
git commit -m "Update appcast for $VERSION"
git push origin main
```

### 第六步：验证 App 内检查更新

```bash
curl -fsSL "https://raw.githubusercontent.com/ShawnRn/LiquidConvert/main/appcast.xml" | xmllint --noout -
curl -I "https://github.com/ShawnRn/LiquidConvert/releases/download/v$VERSION/LiquidConvert_${VERSION}_arm64.dmg"
curl -I "https://github.com/ShawnRn/LiquidConvert/releases/download/v$VERSION/LiquidConvert_${VERSION}_x86_64.dmg"
```

确认 raw `appcast.xml` 顶部 `<sparkle:shortVersionString>`、`<sparkle:version>`、两个 DMG URL、`length`、`sparkle:edSignature` 都对应本次 GitHub Release 后，应用端就能够通过“检查更新”接收到双架构更新包。
如果 `sparkle:edSignature` 里出现 `ERROR`、`Signing key not found` 或 XML 无法通过 `xmllint`，必须视为发布失败，禁止提交或推送该 appcast。
