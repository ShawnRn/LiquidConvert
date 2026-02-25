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

### 5. 高性能图片处理 (10000px+ 级)

- **内存缩放安全**：对于中间尺寸（TargetSize * 2）超过 **4096px** 的场景，**必须**跳过超采样（Supersampling）流程，直接使用单次高质量缩放，以防止 `IOSurface` 创建失败。
- **零 I/O 估算**：体积测试逻辑应优先使用内存 `NSMutableData`，避免产生磁盘 I/O 性能瓶颈。

## 发布流程约定 (Release Workflow)

> [!CAUTION]
> **`appcast.xml` 必须是全流程中最后一个被 `push` 到远程仓库的文件。**

1. **更新代码并推送 (不包含 `appcast.xml`)**：提交业务修改和版本号更新，推送到 GitHub。
2. **创建 GitHub Release**：创建 tag 并上传 `LiquidConvert_x.x.x.dmg`。
3. **运行发布脚本更新本地 `appcast.xml`**：运行 `./scripts/release.sh <version>`。
4. **单独推送 `appcast.xml` (最后一步)**：推送该文件以激活 Sparkle 更新。
