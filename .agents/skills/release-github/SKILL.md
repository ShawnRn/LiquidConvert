---
name: release-github
description: LiquidConvert macOS 双架构 Release 发布流程（本地构建、GitHub Release、Sparkle appcast）。
version: 2.0.0
changelog: "v2.0.0: 修正为 LiquidConvert 专用流程，明确 appcast 必须在 GitHub Release 资产发布后最后推送。"
---

# Release GitHub

用于发布 LiquidConvert 新版本到 GitHub，并确保 App 内 Sparkle “检查更新”可正常选择 arm64 / x86_64 安装包。

## 前置条件

- `gh auth status` 已登录并具备 `repo` / `workflow` 权限。
- 本地可使用完整 Xcode：`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`。
- 业务代码已验证：至少运行 `./scripts/compile_and_run.sh`。
- 发布前不要带着未确认的脏工作区；`appcast.xml` 不得和业务代码同一次推送。

## 标准流程

1. 更新 `MARKETING_VERSION` 与 `CURRENT_PROJECT_VERSION`。Build 号使用日期序号 `YYYYMMDDNN`，必须大于 appcast 中最新 `<sparkle:version>`。
2. 提交并推送业务代码、版本号、文档和工作流变更，但排除 `appcast.xml`。
3. 本地构建双架构 DMG：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/build.sh release
```

4. 创建 GitHub Release 并上传两个 DMG：

```bash
VERSION="<version>"
gh release create "v$VERSION" \
  "releases/LiquidConvert_${VERSION}_arm64.dmg" \
  "releases/LiquidConvert_${VERSION}_x86_64.dmg" \
  --target main \
  --title "LiquidConvert $VERSION" \
  --notes "<中文更新日志>"
```

5. Release 资产上传完成后，再生成 appcast：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/release.sh "$VERSION"
xmllint --noout appcast.xml
```

6. 单独提交并推送 appcast：

```bash
git add appcast.xml
git commit -m "Update appcast for $VERSION"
git push origin main
```

7. 验证：

```bash
curl -fsSL "https://raw.githubusercontent.com/ShawnRn/LiquidConvert/main/appcast.xml" | xmllint --noout -
curl -I "https://github.com/ShawnRn/LiquidConvert/releases/download/v$VERSION/LiquidConvert_${VERSION}_arm64.dmg"
curl -I "https://github.com/ShawnRn/LiquidConvert/releases/download/v$VERSION/LiquidConvert_${VERSION}_x86_64.dmg"
gh release view "v$VERSION"
gh run list --limit 5
```

## GitHub Actions 约束

- `.github/workflows/release.yml` 是手动 `workflow_dispatch` 兜底，不再由 tag push 自动发布，避免本地流程与 Actions 同时写 Release / appcast。
- 如果手动 workflow 生成 appcast，必须先 snapshot，再 restore dirty appcast，切到最新默认分支后重新应用 snapshot 再 commit。
- 正常发布时，`appcast.xml` 只能有一个写入者。优先使用本地终端流程；如果本机没有 Sparkle 私钥，则让手动 workflow 使用 `SPARKLE_PRIVATE_KEY` secret 写入。

## Sparkle 关键校验

- `SUFeedURL` 应指向 `https://raw.githubusercontent.com/ShawnRn/LiquidConvert/main/appcast.xml`。
- `SUPublicEDKey` 必须与本地/Actions 使用的 EdDSA 私钥匹配。
- `release.sh` 必须优先下载 GitHub Release 上的远端 DMG，并以远端字节生成 `length` 与 `sparkle:edSignature`。
- `release.sh` 必须在 `sign_update` 失败、输出为空、输出含 `ERROR`、或 `xmllint` 失败时立即退出。绝不能把签名错误文本写入 `sparkle:edSignature`。
- 每个版本的 appcast item 必须包含两个 enclosure：`sparkle:nativeArchitecture="arm64"` 与 `"x86_64"`。
