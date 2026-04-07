# 性能审计与架构心得 (2026-02) 🚀

## 1. SwiftUI 渲染隔离 (View Isolation)
- **核心原则**：高频更新的 UI 元素（如播放头、Minimap）必须提取为独立子 View。
- **实践经验**：
    - `VideoTrimView` 中，`PlayheadView` 和 `SkimmerView` 的隔离将主时间轴重绘开销降低了 90%。
    - `ImageStitchingView` 中，Minimap 的隔离确保了主画布缩放时导航栏不卡顿。

## 2. 超大图内存管理 (High-Res Image Safety)
- **处理极限**：对于超过 10000px 的图片，禁止使用 `CGContext` 物理绘图（易导致 `IOSurface` 创建失败）。
- **优化方案**：
    - 采用 ImageIO 的 `CGImageSourceCreateThumbnailAtIndex` 进行流式缩放。
    - 严格限制超采样（Supersampling）触发阈值（Target * 2 > 4096px 时跳过）。
    - 关键路径（如 `createResizedImage`）必须手动管理内存释放或缓存复用。

## 3. 异步并发 I/O
- **列表丝滑度**：所有涉及文件系统 I/O（如加载图标/缩略图）的操作，必须移至 `Task.detached`，并在主线程回调。
- **缓存策略**：优先使用 `NSCache` 而非原生 `Dictionary`，以利用系统自动内存回收机制。

## 4. 排序与交互逻辑
- **自然排序**：文件名拼接必须使用 `compare(_:options:.numeric)` 实现自然排序（1, 2, 10...）。
- **计算节流 (Throttle)**：鼠标高频交互（如矩形选框碰撞检测）应引入时间戳节流，建议频率 ≤ 20fps。

## 5. Swift 6 & macOS 15 现代化
- **并发隔离**：`nonisolated` 静态方法禁止同步调用 `@MainActor` 隔离的方法，必须异步包装。
- **API 淘汰**：全面淘汰 `AVAsset(url:)`，启用异步异步 `load(.duration)` 等现代化调用。
