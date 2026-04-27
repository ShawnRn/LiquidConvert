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

> [!CAUTION]
> **本地禁止手动物理打包发布。所有发版强制走 GitHub Actions。**

1. 确认已在 Xcode 中或使用 `sed` 将 `MARKETING_VERSION` 与 `CURRENT_PROJECT_VERSION` 更新。Build 号使用日期序号 `YYYYMMDDNN`，必须大于旧版本的 build 号。
2. 提交并推送业务代码、版本号等变更到 `main` 分支。
3. 触发 GitHub Actions Release：

```bash
gh workflow run release.yml
```

4. 等待 GitHub Actions 执行完成。它会自动：
   - 构建 arm64 与 x86_64 两个 DMG。
   - 创建或更新对应 tag 的 GitHub Release 并上传资产。
   - 生成 Sparkle 的 `appcast.xml` 并自动将其提交推送到仓库 `main` 分支。

5. 验证执行结果与 `appcast` 是否生效：

```bash
gh run list --limit 3
git pull
curl -fsSL "https://raw.githubusercontent.com/ShawnRn/LiquidConvert/main/appcast.xml" | xmllint --noout -
```

## GitHub Actions 约束

- 正常发布时统一使用 `workflow_dispatch` 触发 `.github/workflows/release.yml`，该工作流利用 Repo Secret 中的 `SPARKLE_PRIVATE_KEY` 生成并推送包含 `edSignature` 的 `appcast.xml`。

## Sparkle 关键校验

- `SUFeedURL` 应指向 `https://raw.githubusercontent.com/ShawnRn/LiquidConvert/main/appcast.xml`。
- `SUPublicEDKey` 必须与本地/Actions 使用的 EdDSA 私钥匹配。
- `release.sh` 必须优先下载 GitHub Release 上的远端 DMG，并以远端字节生成 `length` 与 `sparkle:edSignature`。
- `release.sh` 必须在 `sign_update` 失败、输出为空、输出含 `ERROR`、或 `xmllint` 失败时立即退出。绝不能把签名错误文本写入 `sparkle:edSignature`。
- 每个版本的 appcast item 必须包含两个 enclosure：`sparkle:nativeArchitecture="arm64"` 与 `"x86_64"`。
