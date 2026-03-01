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

### 第三步：写入签名与发布描述
接着调用发布脚本对两份 DMG 进行 EdDSA 提取并通过正则替换自动组合好针对多架构的 Sparkle 发布 `<enclosure>` 节点。
*(⚠️ 执行前请把 `<YOUR_NEW_VERSION>` 替换为您正在发布的新版本。如 1.0.0)*

```bash
./scripts/release.sh <YOUR_NEW_VERSION>
```

### 第四步：推送文件至 GitHub Release
发布您的二进制安装产物。
*(⚠️ 同样需要在执行本命令内指明真实版本号)*

```bash
VERSION="<YOUR_NEW_VERSION>"
gh release create "v$VERSION" "releases/LiquidConvert_${VERSION}_arm64.dmg" "releases/LiquidConvert_${VERSION}_x86_64.dmg" \
  --title "LiquidConvert $VERSION" \
  --notes "在此输入更新日志"
```

### 第五步：连同 Appcast 提交生效
在以上步骤完全跑通且 GitHub Release 能正常访问您的归档后：

// turbo
```bash
git add appcast.xml
git commit -m "chore: release LiquidConvert v$VERSION with dual architecture builds"
git push
```
执行完毕后，应用端就能够接收到相应体积更精简的更新包了。
