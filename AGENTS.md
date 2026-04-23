# 仓库指南 (LiquidConvert)

## 项目结构与模块详细说明

### 1. 核心应用 (`LiquidConvert/`)
- `LiquidConvertApp.swift`: **应用程序入口**。
    - 维护全局状态 `AppState` (Tab 导航、保存拦截、设置同步)。
    - `AppDelegate`: 处理关键的 macOS 系统交互，包括：
        - **Dock 拖放**: 智能识别拖入文件（单张转换 vs 多张拼接）。
        - **静默模式**: 支持后台无感启动处理文件后自动退出。
        - **通知管理**: 转换完成的横幅提示。
- `ContentView.swift`: **主界面框架**。
    - 使用原生 `NavigationSplitView` 实现侧边栏胶囊布局。
    - 集成 `TrafficLightManager` 精确控制红绿灯位置以符合设计语言。
- `Video/GIF 实验室`:
    - `VideoGifFunctionView.swift`: 批量转换 UI，支持剪辑预览、参数调节。
    - `VideoGifConverter.swift`: 适配 AVFoundation 的高性能帧提取与 FFmpeg 级别的 GIF 编码。
    - `VideoTrimView.swift`: **专业级剪辑器**。Final Cut Pro 风格的时间轴，支持多点缩略图和实时 Seek。
- `图片拼接与处理`:
    - `ImageStitchingView.swift` / `ImageStitcher.swift`: 提供智能方向算法和多分辨率对齐。
    - `ImageCompressionView.swift` / `ImageCompressor.swift`: 核心「Auto 5 MB」算法，基于 ImageIO 反复迭代优化体积。
- `Icons & 提取`:
    - `IconFunctionView.swift` / `IconConverter.swift`: .icns 标准转换与全尺寸生成。
- `Utilities/`:
    - `Utils.swift`: 全局辅助函数（文件路径处理、字符串扩展）。

### 2. 构建与自动化 (`scripts/`)
- `build.sh`: **自动化构建核心**。自动同步版本号: 脚本会自动从 Xcode 项目文件提取 `Version` 和 `Build` 号，确保命令行构建产物与 Xcode 设置完全一致。
- `compile_and_run.sh`: **推荐的开发辅助脚本**。采用结构化日志输出，包含自动化构建、清理旧进程、启动新包。
- `release.sh`: 生产打包脚本，处理 Sparkle 更新 (`appcast.xml`)、签名与发布。

## 业务逻辑约束 (Development Guidelines)

### 1. 交互规范
- **沉浸式剪辑**: 新增视频拖入后，如果只有单文件，应自动弹出 `VideoTrimView`。
- **保存守卫**: 图片拼接页面如果存在修改，侧边栏切换需触发拦截逻辑。

### 2. 性能与资源
- 所有耗时操作（转换、提取帧、拼接）**必须**在 `Task.detached` 或 `Task` 异步上下文中执行，禁止阻塞 UI 线程。
- 视频处理使用硬件加速编码，缩略图生成使用 `AVAssetImageGenerator`。

### 3. 构建验证
- 进行任何功能迭代后，务必在终端执行 `./scripts/compile_and_run.sh` 验证应用启动和基本逻辑流。

### 4. Swift 6 & macOS 15 并发与 API 规范

- **隔离一致性**：`nonisolated` 静态方法禁止同步调用 `@MainActor` 隔离的方法（如 `FileSafeHandler.safeTrashItem`），必须包装在 `Task { @MainActor in ... }` 中。
- **现代化 AVFoundation**：
    - 废弃 `AVAsset(url:)` -> 选用 `AVURLAsset(url:)`。
    - 废弃 `copyCGImage(at:actualTime:)` -> 选用异步的 `generator.image(at:)`。
- **并发安全**：严禁在异步 Task 中直接读写共享的可变状态（如 `Array.append`），必须切换回 `@MainActor` 执行。

### 6. 核心技术沉淀 (Knowledge Index)

- [性能审计与架构心得 (2026-02)](file:///.agent/PERFORMANCE_AUDIT.md): 深度记录了关于 SwiftUI 渲染隔离、超大图内存管理及自然排序的核心规准。
- [并发与 API 规范](file:///.agent/CONCURRENCY_&_API.md): 详细记录了针对 Swift 6 和 macOS 15 的现代化适配规则。
- [Release 发布约定](file:///.agent/RELEASE_RULES.md): 规范了版本号同步、DMG 封装及 Sparkle 更新的全流程。

## 发布流程约定 (Release Workflow)

> [!CAUTION]
> **`appcast.xml` 必须是全流程中最后一个被 `push` 到远程仓库的文件。**

1. **更新代码并推送 (不包含 `appcast.xml`)**：提交业务修改和版本号更新，推送到 GitHub。
2. **创建 GitHub Release**：使用 GitHub CLI (`gh`) 自动化创建 Release 并上传产物（请一并上传 `arm64` 和 `x86_64` 两个安装包）。例如：
   ```bash
   # 请将 $VERSION 替换为实际版本号，如 1.0.1
   gh release create "v$VERSION" "releases/LiquidConvert_${VERSION}_arm64.dmg" "releases/LiquidConvert_${VERSION}_x86_64.dmg" \
     --title "LiquidConvert $VERSION" \
     --notes "在此输入更新日志"
   ```
3. **运行发布脚本更新本地 `appcast.xml`**：运行 `./scripts/release.sh <version>`。该脚本会优先下载 GitHub Release 上“实际可被用户下载到”的 DMG，并以远端资产为准生成 Sparkle 的 `length` 与 `edSignature`。
4. **单独推送 `appcast.xml` (最后一步)**：推送该文件以激活 Sparkle 双架构自适应更新。

### Sparkle 额外铁律
- **禁止**在未创建 GitHub Release 的情况下先生成或推送 `appcast.xml`。
- **禁止**假设“本地 DMG == GitHub 上可下载到的 DMG”；必须以 `release.sh` 下载回来的远端资产为准生成 Sparkle 签名。
- 如果需要“替换最新更新”，优先保持同一版本号并原地替换对应 Release / appcast，不要额外新开一个用户可见版本去掩盖签名事故。
- **禁止**带着脏工作区直接发版。发版前必须先确认 `git status --short` 为空，或者至少明确只有本次要发布的改动被 stage/commit。
- 新模块上线前，必须检查入口链路已经入库：`TabIdentifier` / `ContentView` 侧边栏入口 / 主视图路由 / 依赖声明（如 License）要一起进入同一个 release 提交；不能只把实现文件留在仓库里却漏掉入口注册。
- **禁止**从 tag 工作流的 detached HEAD 直接硬推 `appcast.xml` 到 `main`。GitHub Actions 或手动热修提交 appcast 前，必须先 `fetch origin main`，基于最新 `origin/main` 重新应用生成好的 appcast，再提交推送。
- 如果手动热修和 Release Actions 同时更新 `appcast.xml`，应比较生成结果与远端 `appcast.xml` 的 SHA；内容已经一致时必须视为成功并跳过提交，不能因为 `fetch first` / non-fast-forward 把发布流程标红。
- 替换最新 release 时，推荐顺序是：推代码与版本 build -> 重建/替换 GitHub Release 资产 -> 运行 `release.sh` 用远端资产生成 appcast -> 单独提交 appcast。不要让 CI 和本地同时各自生成不同时间戳的 appcast 后抢推 `main`。
