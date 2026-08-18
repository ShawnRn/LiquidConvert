# LiquidConvert 版本管理

## 版本号格式

LiquidConvert 使用**语义化版本号** (Semantic Versioning) 系统：

```
版本号格式: Major.Minor.Patch.Build
示例: 1.0.0.1 或 1.2.3.456
```

### 版本号组成

1. **Marketing Version** (用户看到的版本): `Major.Minor.Patch`
   - **Major** (主版本号): 重大架构更新、不兼容的API变更
   - **Minor** (次版本号): 新功能添加、向后兼容
   - **Patch** (补丁版本号): Bug修复、小改进

2. **Build Number** (构建号): 每次构建自动递增的编号
   - 用于内部跟踪
   - 可在"关于"面板中显示完整版本

### 当前版本

- **Marketing Version**: `3.5.2`
- **Build Number**: `2026081801`
- **完整版本**: `3.5.2 (2026081801)`

---

## 版本更新规则

### 何时增加版本号

| 变更类型 | 示例 | 版本号变化 |
|---------|------|-----------|
| 🔴 **重大更新** | 完全重写、架构变更 | `1.0.0` → `2.0.0` |
| 🟡 **功能添加** | 新增Dock拖拽功能 | `1.0.0` → `1.1.0` |
| 🟢 **Bug修复** | 修复转换错误 | `1.0.0` → `1.0.1` |
| ⚪ **每次构建** | 任何代码改动 | Build `1` → `2` |

### 版本号示例

```
1.0.0 (1)   - 初始发布
1.0.1 (2)   - 修复图片缩放bug
1.1.0 (3)   - 新增视频转换功能
1.1.1 (4)   - 修复通知显示
2.0.0 (5)   - 重大架构升级
```

---

## 如何更新版本

### 方法一：在 Xcode 中手动更新

1. 打开 Xcode 项目
2. 选择项目 → Target "LiquidConvert"
3. General Tab → Identity
   - **Version**: 修改 Marketing Version (如 `1.0.0` → `1.1.0`)
   - **Build**: 自动递增或手动修改

### 方法二：直接编辑项目文件

编辑 `LiquidConvert.xcodeproj/project.pbxproj`:

```
MARKETING_VERSION = 1.0.0;
CURRENT_PROJECT_VERSION = 1;
```

### 方法三：使用脚本自动递增 (推荐)

创建 Build Phase 脚本自动递增 Build Number：

```bash
#!/bin/bash
buildNumber=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "${INFOPLIST_FILE}")
buildNumber=$(($buildNumber + 1))
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $buildNumber" "${INFOPLIST_FILE}"
```

---

## 版本历史

### v3.2.1 (Build 2026051901) - 2026-05-19
#### 修复与集成
- ✨ **新增 LiquidConvert CLI**：App 首次启动会检测 `liquidconvert` 命令是否已安装，未安装时提示安装，方便 Codex 或终端直接把 URL、PDF、Office、HTML、文本和图片转换为 Markdown。
- 🐞 **修复 CLI 网页提取崩溃**：命令行模式不再初始化 `WKWebView`，URL 提取改走 MarkItDown 安全路径，避免无 UI 进程触发 WebKit 崩溃。
- 🔧 **补强自动化工作流**：CLI 支持 `--output`、`--cli-status` 与 `--install-cli`，便于外部自动化检测和调用。

### v3.1.9 (Build 2026042703) - 2026-04-27
#### 新功能与优化
- ✨ **微信解析内置化**：彻底内置 `wx` CLI 脚本，通过 App 自带的 Python 环境运行，实现任何 Mac 开箱即用，无需安装额外依赖。
- ✨ **超大图性能优化**：在图片拼接中加入 16k 像素安全限制，自动处理内存风险，防止超高分辨率图片导致的崩溃。
- ✨ **生命周期修复**：彻底解决 ⌘+W 后点击 Dock 无法唤醒及状态残留的顽疾，窗口重开自动回到首页。
- ✨ **OCR 性能提升**：针对长图实现自动切片并行识别，显著提升 AI 文档转换的准确度与效率。
- 🎨 **UI/UX 精简**：优化了视频剪辑、图片拼接的交互计算，响应更迅捷。
- 🔧 **统一后缀**：所有自动生成的图片文件后缀统一为 `.jpg`。

### v1.0.0 (Build 1) - 2025-12-17
#### 新功能
- ✨ Dock图标拖拽转换
- ✨ 自动转换为50%质量JPG
- ✨ 智能图片缩放（短边>1080自动压缩）
- ✨ 自动删除源文件
- ✨ 完全静默后台处理
- ✨ 未运行时拖入文件后自动退出

#### 技术细节
- 支持格式: JPG, PNG, HEIC, WEBP, TIFF, BMP, GIF, RAW
- 输出格式: JPG (固定)
- 压缩质量: 50%
- 缩放策略: 短边>1080 → 1080px

---

## 发布检查清单

发布新版本前，确保完成以下步骤：

- [ ] 更新 `MARKETING_VERSION` 到新版本号
- [ ] 更新本文档的版本历史
- [ ] 测试所有核心功能
- [ ] 检查 Console 无严重错误
- [ ] 更新 README.md (如果有)
- [ ] 创建 Git Tag: `git tag v1.0.0`
- [ ] 构建 Release 版本
- [ ] Archive 并导出 .app

---

## 在应用中显示版本号

可以在"关于"窗口或设置中显示完整版本信息：

```swift
let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"
let fullVersion = "\(version) (\(build))"
// 显示: "1.0.0 (1)"
```

---

## 参考资料

- [语义化版本 2.0.0](https://semver.org/lang/zh-CN/)
- [Apple版本号管理](https://developer.apple.com/documentation/bundleresources/information_property_list/cfbundleversion)
