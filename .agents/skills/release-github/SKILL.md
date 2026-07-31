---
name: release-github
description: LiquidConvert macOS 双架构 Release 发布流程（本地 Xcode 编译打包、GitHub Release、Sparkle appcast）。
version: 2.1.0
changelog: "v2.1.0: 废弃 GitHub Actions 发版，统一采用本地 Xcode 编译打 DMG 包、生成 Sparkle 双架构签名并发布至 GitHub Release。"
---

# Release GitHub

用于在本地使用 Xcode 编译打包 LiquidConvert 新版本发布到 GitHub Release，并确保 App 内 Sparkle “检查更新”可正常选择 arm64 / x86_64 安装包。

## 前置条件

- `gh auth status` 已登录并具备 `repo` 权限。
- 本地使用完整 Xcode：`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`。
- 本地具备 `SPARKLE_PRIVATE_KEY` / Sparkle Keychain 签名私钥。
- 业务代码已验证通过。

## 标准流程

> [!IMPORTANT]
> **发布统一使用本地 Xcode 编译打双架构 DMG 包后发布至 GitHub Release。**

1. 确认已在 Xcode 中或使用 `sed` 将 `MARKETING_VERSION` 与 `CURRENT_PROJECT_VERSION` 更新。Build 号使用日期序号 `YYYYMMDDNN`，必须大于旧版本的 build 号。
2. 提交并推送业务代码、版本号等变更到 `main` 分支。
3. 本地打包双架构 DMG：
   ```bash
   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/build.sh release
   ```
4. 上传安装包并创建 GitHub Release：
   ```bash
   VERSION="<YOUR_NEW_VERSION>"
   gh release create "v$VERSION" "releases/LiquidConvert_${VERSION}_arm64.dmg" "releases/LiquidConvert_${VERSION}_x86_64.dmg" \
     --title "LiquidConvert $VERSION" \
     --notes "在此输入更新日志"
   ```
5. 本地运行 `release.sh` 以远端真实资产生成 Sparkle `appcast.xml` 并提交推送：
   ```bash
   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/release.sh "$VERSION"
   xmllint --noout appcast.xml
   git add appcast.xml
   git commit -m "Update appcast for $VERSION"
   git push origin main
   ```

## Sparkle 关键校验

- `SUFeedURL` 应指向 `https://raw.githubusercontent.com/ShawnRn/LiquidConvert/main/appcast.xml`。
- `SUPublicEDKey` 必须与使用的 EdDSA 私钥匹配。
- **多设备无 Keychain 依赖签名**：可设置 `export SPARKLE_PRIVATE_KEY="<base64_ed25519_private_key>"`。`release.sh` 检测到该变量时会自动绕过 macOS 钥匙串进行签名，适合在多台 Mac 或 CI/CD 环境中使用。
- `release.sh` 必须优先下载 GitHub Release 上的远端 DMG，并以远端字节生成 `length` 与 `sparkle:edSignature`。
- 每个版本的 appcast item 必须包含两个 enclosure：`sparkle:nativeArchitecture="arm64"` 与 `"x86_64"`。
