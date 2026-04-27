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
- **AI 文档提取必须开箱即用**：`MarkItDown` 运行时不得依赖用户预装 Homebrew 或 Python 3.10+。如果系统 Python 不满足版本要求，App 必须自动准备受控的兼容 Python 运行时，再创建 venv 并安装固定版本的文档提取依赖。
- **AI 文档 OCR 插入规则**：拖入图片文件时必须直接使用 Vision OCR 提取文字，禁止把图片交给 MarkItDown 后得到空结果；拖入 Word / PPT / Excel / PDF / HTML / 网页时，正文仍由 MarkItDown 或专用网页提取器负责，图片 OCR 结果必须插入到 Markdown 中对应图片位置附近，而不是统一追加到文末。
- **AI 文档 OCR 排版规则**：OCR 输出需做基础段落归并，尽量合并同一视觉段落里被 Vision 拆碎的短行；列表、明显段落间距和标题结构应保留，避免把整张图粗暴拼成一行。

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
> **本地禁止手动物理打包发布。所有发版强制走 GitHub Actions。**

1. **更新代码与版本号**：完成所有业务修改，确保代码能够通过本地编译 (`./scripts/compile_and_run.sh`)。
2. **确认版本与 Build 号**：在 Xcode 项目设置中更新 `MARKETING_VERSION` 与 `CURRENT_PROJECT_VERSION`。如果是替换或热修同版本，必须提升 `CURRENT_PROJECT_VERSION`。
3. **提交并推送至 GitHub**：推送包含版本号更新的提交到远端 `main`。
4. **触发 GitHub Actions 发包**：使用 GitHub CLI 触发 release 流程。
   ```bash
   gh workflow run release.yml
   ```
5. **等待并验证**：GitHub Actions 会自动在云端构建双架构 DMG、上传至 GitHub Release，并根据生成的远端资产自动更新、签名和推送 `appcast.xml`。发版完成后，可通过 `gh run list` 和 `git pull` 校验远端 `appcast.xml` 更新情况。

### Sparkle 额外铁律
- 同一用户可见版本内替换有问题的更新时，必须提升 `CURRENT_PROJECT_VERSION`，否则已安装旧 build 的设备不会识别到修复包。
- **禁止**带着脏工作区直接推代码。发版前必须先确认工作区整洁。
- 新模块上线前，必须检查入口链路已经入库：`TabIdentifier` / `ContentView` 侧边栏入口 / 主视图路由 / 依赖声明（如 License）要一起进入同一个 release 提交。
