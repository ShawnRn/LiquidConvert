# 并发与现代 API 开发准则 (LiquidConvert)

为了确保应用在 macOS 15+ 上的稳定性和 Swift 6 的严格安全性，必须遵守以下准则：

## 1. Swift 6 并发与隔离

- **MainActor 强制隔离**：凡是涉及 UI 状态更新（如 `thumbnails` 数组、`files` 列表）或资源删除（`safeTrashItem`）的操作，必须通过 `@MainActor` 隔离。
- **跨隔离调用**：在 `nonisolated` 方法中调用 `@MainActor` 方法时，必须使用异步包装：
  ```swift
  Task { @MainActor in 
      try? FileSafeHandler.safeTrashItem(at: url) 
  }
  ```
- **数据竞争防护**：禁止在并行 Task 中读写共享数组，应使用局部变量收集结果后再切回 `@MainActor` 赋值。

## 2. macOS 15.0+ 现代 API

- **AVFoundation**:
  - 禁止使用 `AVAsset(url:)` -> 使用 `AVURLAsset(url:)`。
  - 禁止使用同步的 `copyCGImage(at:actualTime:)` -> 使用 `generator.image(at:time)` 异步 API。

## 3. 超大图内存保护

- **IOSurface 安全阈值**：处理 > 8000px 的原始图片时，如果中间超采样尺寸（Double Scale）超过 **4096px**，必须降级为高效的“单次高质量缩放”，严禁开启超采样模式以防止系统显存分配失败。
- **内存 I/O**: `estimateFileSize` 严禁使用临时文件，必须通过内存数据流进行。
