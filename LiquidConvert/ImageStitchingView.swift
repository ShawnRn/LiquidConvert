//
//  ImageStitchingView.swift
//  LiquidConvert
//
//  Created by Shawn Rain.
//  Optimized for "Pure Gesture" interaction - No System Ghosting
//

import SwiftUI
import UniformTypeIdentifiers
import AppKit

// MARK: - Caching

struct ImageStitchingView: View, Sendable {
    // Data
    @State private var files: [URL] = []
    
    // Global State
    @EnvironmentObject var appState: AppState
    
    // Settings
    @AppStorage("stitch_direction") private var directionStr = "vertical"
    @AppStorage("stitch_quality") private var quality: Double = 0.9
    @AppStorage("stitch_target_format") private var targetFormat: ImageConverter.TargetFormat = .jpeg
    @AppStorage("stitch_mobile_optimize") private var mobileOptimize: Bool = false
    
    var direction: StitchDirection {
        get { directionStr == "horizontal" ? .horizontal : .vertical }
        set { directionStr = newValue == .horizontal ? "horizontal" : "vertical" }
    }
    
    // UI State
    @State private var isProcessing = false
    @State private var isImporting = false
    @State private var isTargeted = false // For external drops
    
    // 🔥 纯手势拖拽的核心状态
    @State private var activeDirection: StitchDirection = .vertical // 🔥 Local State for smooth animation
    @State private var draggingURL: URL? // 当前正在拖拽的文件 (Data Source)
    @State private var dragLocation: CGPoint = .zero // 拖拽的全局坐标 (Visual Source)
    @State private var initialDragIndex: Int? // 拖拽开始时的索引 (计算基准)
    
    // 🔍 Zoom & Minimap State
    @State private var zoomScale: CGFloat = 1.0
    @State private var lastZoomScale: CGFloat = 1.0 // ✨ Added missing state
    @State private var contentSize: CGSize = .zero
    @State private var currentScrollOffset: CGPoint = .zero
    @State private var itemSizes: [URL: CGSize] = [:] // 📏 存储每个卡片的精确尺寸，用于完美 Overlay 同步
    
    // 🖐️ Space-Pan State
    @State private var isSpacePressed = false
    @State private var isPanning = false
    @State private var panStartOffset: CGPoint?
    @State private var keyMonitor: Any? // 🧹 Monitor cleanup

    // 🖱️ Selection & Marquee State
    @State private var selection: Set<URL> = [] // Selected Items
    @State private var selectionRect: CGRect = .zero // Marquee Box
    @State private var isMarqueeSelecting = false // Is Dragging on background?
    @State private var initialSelection: Set<URL> = [] // Snapshot during drag
    
    @State private var scrollMonitor: Any? // 🖱️ Scroll/Zoom Monitor
    @State private var viewportSize: CGSize = .zero // 🔥 For accurate marquee hit-testing
    
    // 🚦 Debounce for Layout Switch
    @State private var lastLayoutSwitchTime: Date = .distantPast
    
    // MARK: - Monitor Logic
    private func bindGlobalScrollMonitor() {
        if scrollMonitor != nil { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { event in
            // 只有当鼠标在窗口内时才响应 (简化判定，可增强)
            // 实际上这里的 Monitor 是 Local (App内)，所以只需确保不是其他窗口？
            // 简单处理：直接响应。SwiftUI View 生命周期会管理它的启用/禁用。
            
            if event.type == .magnify {
                let factor = event.magnification
                let newScale = self.zoomScale * (1 + factor)
                self.zoomScale = max(0.2, min(5.0, newScale))
                return nil // Consume event
            } else if event.type == .scrollWheel {
                // 判断是否按住了 Command 键 -> 转换为缩放 (Standard macOS behavior)
                if event.modifierFlags.contains(.command) {
                    let factor = event.deltaY * 0.01
                    let newScale = self.zoomScale * (1 + factor)
                    self.zoomScale = max(0.2, min(5.0, newScale))
                    return nil
                }
                
                // 正常的滚动平移
                let deltaX = event.scrollingDeltaX
                let deltaY = event.scrollingDeltaY
                //若是触摸板，delta通常较精确；类似 Photoshop，反向？通常是内容跟随手指，delta是对的
                let newX = self.currentScrollOffset.x + deltaX
                let newY = self.currentScrollOffset.y + deltaY
                self.currentScrollOffset = CGPoint(x: newX, y: newY)
                return nil // Consume event
            }
            return event
        }
    }
    
    private func unbindGlobalScrollMonitor() {
        if let monitor = scrollMonitor {
            NSEvent.removeMonitor(monitor)
            scrollMonitor = nil
        }
    }

    
    var body: some View {

        HSplitView {
            // === Left: Canvas ===
            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    // Store viewport size for accurate marquee hit-testing
                    Color.clear
                        .onAppear { viewportSize = proxy.size }
                        .onChange(of: proxy.size) { viewportSize = proxy.size }
                    // 1. 背景层：负责接收 Finder 外部文件
                    // 只有当没有内部拖拽发生时，才允许显示高亮
                        // 2. 交互背景层 (Marquee & External Drop)
                        ZStack {
                            Color.clear
                                .contentShape(Rectangle())
                                .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
                                    handleExternalDrop(providers)
                                }
                                .onTapGesture {
                                    // Tap on empty space to deselect
                                    if !NSEvent.modifierFlags.contains(.command) {
                                        selection.removeAll()
                                    }
                                }
                                // 🔥 Marquee Selection Gesture
                                .gesture(
                                    DragGesture(minimumDistance: 5, coordinateSpace: .named("canvas"))
                                        .onChanged { value in
                                            // Start selecting
                                            if !isMarqueeSelecting {
                                                isMarqueeSelecting = true
                                                // If no modifier (Command), clear previous selection
                                                if !NSEvent.modifierFlags.contains(.command) {
                                                    initialSelection = []
                                                } else {
                                                    initialSelection = selection
                                                }
                                            }
                                            
                                            let start = value.startLocation
                                            let current = value.location
                                            
                                            // Create Rect from Start to Current
                                            let minX = min(start.x, current.x)
                                            let minY = min(start.y, current.y)
                                            let width = abs(current.x - start.x)
                                            let height = abs(current.y - start.y)
                                            
                                            self.selectionRect = CGRect(x: minX, y: minY, width: width, height: height)
                                            
                                            // 🔥 Update Selection Live
                                            // Check intersection with all items
                                            // Since we have `itemSizes`, we can approximate frames?
                                            // Actually, `itemSizes` only gives size, not origin.
                                            // We need full frames. But `cardsView` is a layout derived from Order.
                                            // We can use a simpler heuristic: Center point intersection? Or GeometryReader on items.
                                            // Let's use `updateSelection()` helper.
                                            updateSelectionWithMarquee()
                                        }
                                        .onEnded { _ in
                                            isMarqueeSelecting = false
                                            selectionRect = .zero
                                        }
                                )
                        }
                    
                    if isTargeted && draggingURL == nil {
                        Color.blue.opacity(0.1).allowsHitTesting(false)
                    }
                    
                    if files.isEmpty {
                        EmptyStateDropZone(onBrowse: { isImporting = true }, onDrop: { handleImportedURLs($0) })
                        // 注意：这里不要 allowsHitTesting(false)，否则按钮点不了
                    } else {
                        // 2. 内容滚动层
                        // 2. 内容滚动层
                        // 根据方向锁定滚动轴，隐藏无关的滚动条
                        // 2. 无限画布层 (Pure Canvas)
                        // 摒弃 ScrollView，使用 Offset + EventReader 实现绝对控制，彻底解决抖动
                        ZStack {
//                        // Event Reader (Bottom Layer to capture generic scrolls)
//                        ScrollEventHandlingView(offset: $currentScrollOffset, zoomScale: $zoomScale)
//                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                         
                        // 🔥 使用 Global Monitor 替代底层 View，确保即使鼠标在 Image 上也能缩放
                         Color.clear
                            .onAppear {
                                bindGlobalScrollMonitor()
                            }
                            .onDisappear {
                                unbindGlobalScrollMonitor()
                            }
                            
                            // Content
                            ZStack {
                                layoutContainer(proxy: proxy)
                                    .background(
                                        GeometryReader { geo in
                                            Color.clear
                                                .onAppear { contentSize = geo.size }
                                                .onChange(of: geo.size) { contentSize = geo.size }
                                        }
                                    )
                                    .onPreferenceChange(ItemSizePreferenceKey.self) { sizes in
                                        self.itemSizes = sizes
                                    }
                                    .scaleEffect(zoomScale)
                                    .offset(x: currentScrollOffset.x, y: currentScrollOffset.y)
                                    // 确保内容居中初始位置
                                    .frame(width: max(proxy.size.width, contentSize.width * zoomScale),
                                           height: max(proxy.size.height, contentSize.height * zoomScale),
                                           alignment: .center)
                                    
                                // 🔥 Marquee Drawing Layer (Inside Canvas Space)

                            }
                            // 限制内容的交互区域，防止无限溢出
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .clipped()
                            // Remove blocking contentShape and DragGesture to allow ScrollEventHandlingView to receive events
                            // If canvas dragging (Pan) is needed later, integrate it into ScrollEventHandlingView
                        }

                            // 限制内容的交互区域，防止无限溢出
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .clipped()
                            // Remove blocking contentShape and DragGesture to allow ScrollEventHandlingView to receive events
                            // If canvas dragging (Pan) is needed later, integrate it into ScrollEventHandlingView
                        }
                        //.coordinateSpace(name: "canvas") // 🔥 REMOVED from here

                    
                    // 3. 悬浮拖拽层 (Overlay Drag Layer)
                    // 这才是真正跟随手指的东西
                    if let draggingURL {
                        // 🔥 Multi-selection: Show all selected items in original layout
                        let itemsToDrag: [URL] = selection.contains(draggingURL) && selection.count > 1
                            ? files.filter { selection.contains($0) }
                            : [draggingURL]
                        
                        // Use the same layout as the original (VStack/HStack based on direction)
                        Group {
                            if activeDirection == .vertical {
                                VStack(spacing: 16) {
                                    ForEach(itemsToDrag, id: \.self) { url in
                                        let capturedSize = itemSizes[url]
                                        StitchImageCard(url: url, direction: activeDirection, isSelected: false, zoomScale: zoomScale, onDelete: {})
                                            .frame(width: capturedSize?.width, height: capturedSize?.height)
                                    }
                                }
                            } else {
                                HStack(spacing: 16) {
                                    ForEach(itemsToDrag, id: \.self) { url in
                                        let capturedSize = itemSizes[url]
                                        StitchImageCard(url: url, direction: activeDirection, isSelected: false, zoomScale: zoomScale, onDelete: {})
                                            .frame(width: capturedSize?.width, height: capturedSize?.height)
                                    }
                                }
                            }
                        }
                        .shadow(color: .black.opacity(0.3), radius: 12, x: 0, y: 8)
                        .scaleEffect(zoomScale)
                        .position(dragLocation)
                        .allowsHitTesting(false)
                        .transition(.identity)
                    }
                    
                    // Floating Toolbar (保持不变)
                    VStack {
                        Spacer()
                        toolbarView
                            .padding(.bottom, 24)
                    }
                    .frame(maxWidth: .infinity) // 修复：确保 Toolbar 在 ZStack(.topLeading) 中居中
                    .frame(maxWidth: .infinity) // 修复：确保 Toolbar 在 ZStack(.topLeading) 中居中
                
                // === 4. Photoshop Style Pan Overlay ===
                // 只有按住空格键时才覆盖在最上层，拦截所有点击和拖拽
                if isSpacePressed {
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    if !isPanning {
                                        isPanning = true
                                        NSCursor.closedHand.push()
                                    }
                                    
                                    if panStartOffset == nil { panStartOffset = currentScrollOffset }
                                    guard let start = panStartOffset else { return }
                                    
                                    // Calculate new offset
                                    let deltaX = value.translation.width
                                    let deltaY = value.translation.height
                                    currentScrollOffset = CGPoint(x: start.x + deltaX, y: start.y + deltaY)
                                }
                                .onEnded { _ in
                                    isPanning = false
                                    panStartOffset = nil
                                    NSCursor.pop() // Pop closedHand
                                }
                        )
                }
                
                // === 5. Marquee Overlay ===
                // === 5. Marquee Overlay ===
                if isMarqueeSelecting {
                    // Draw in Viewport Coordinates (Canvas Space)
                    // No scale or offset needed, as selectionRect is already in this space
                    Rectangle()
                        .stroke(Color.blue.opacity(0.8), lineWidth: 1)
                        .background(Rectangle().fill(Color.blue.opacity(0.1)))
                        .frame(width: selectionRect.width, height: selectionRect.height)
                        // Position based on center
                        .position(x: selectionRect.midX, y: selectionRect.midY)
                        .allowsHitTesting(false)
                }
                
                // === 6. Minimap (Top Layer) ===
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        MinimapView(
                            files: files,
                            direction: activeDirection,
                            contentSize: contentSize,
                            viewportSize: proxy.size,
                            canvasOffset: $currentScrollOffset,
                            zoomScale: zoomScale
                        )
                    }
                }
            } // End of Root ZStack
            // 🔥 终极防线：强制根视图尺寸等于窗口视口，防止所有 UI 偏移
            .frame(width: proxy.size.width, height: proxy.size.height)
            .coordinateSpace(name: "canvas") // 🔥 Correct placement: Viewport Coordinates
            .frame(minWidth: 260, maxWidth: .infinity)
            .onAppear {
                // 监听全局键盘事件 (Local Monitor - App Active)
                // 先移除旧的 (Safeguard)
                if let monitor = keyMonitor { NSEvent.removeMonitor(monitor) }
                
                keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
                    if event.keyCode == 49 { // Space Key
                        if event.type == .keyDown && !event.isARepeat {
                            self.isSpacePressed = true
                            NSCursor.openHand.push()
                        } else if event.type == .keyUp {
                            self.isSpacePressed = false
                            NSCursor.pop() // Pop openHand
                            // Safety cleanup
                            if isPanning {
                                isPanning = false
                                panStartOffset = nil
                                NSCursor.pop() // Pop closedHand if stuck
                            }
                        }
                        return nil // Consume Space key to prevent system beep
                    }
                    if event.keyCode == 49 { // Space Key
                        if event.type == .keyDown && !event.isARepeat {
                            self.isSpacePressed = true
                            NSCursor.openHand.push()
                        } else if event.type == .keyUp {
                            self.isSpacePressed = false
                            NSCursor.pop() // Pop openHand
                            // Safety cleanup
                            if isPanning {
                                isPanning = false
                                panStartOffset = nil
                                NSCursor.pop() // Pop closedHand if stuck
                            }
                        }
                        return nil // Consume Space key to prevent system beep
                    }
                    
                    // 🔥 Delete Key (Backspace: 51, Forward Delete: 117)
                    if (event.keyCode == 51 || event.keyCode == 117) && event.type == .keyDown {
                        if !selection.isEmpty {
                            withAnimation {
                                files.removeAll { selection.contains($0) }
                                selection.removeAll()
                            }
                            return nil // Create no beep
                        }
                        // Handle single item hover delete? No, strictly selection.
                    }
                    return event
                }
            }
            .onDisappear {
                if let monitor = keyMonitor {
                    NSEvent.removeMonitor(monitor)
                    keyMonitor = nil
                }
                // Reset Cursor State
                NSCursor.arrow.set()
                isSpacePressed = false
                NSCursor.arrow.set()
                isSpacePressed = false
                isPanning = false
            }
            .onChange(of: files) { _, newFiles in
                appState.isStitchingDirty = !newFiles.isEmpty
            }
            // 🔥 Sync State on Appear
            .onAppear {
                activeDirection = direction // Initialize from Storage
                appState.isStitchingDirty = !files.isEmpty
                
                // Register Save Action
                appState.requestSaveAction = {
                    await startStitching()
                }
            }
            .onChange(of: activeDirection) { _, newDir in
                // Async sync back to Storage to avoid animation glitches
                directionStr = newDir == .horizontal ? "horizontal" : "vertical"
            }
            //.zIndex(1) // Removed zIndex as HSplitView handles layering differently

            
            
            } // End of GeometryReader
            
            // === Right: Settings (保持不变) ===
            settingsPanel
                //.zIndex(2) // Removed zIndex
        } // End of HSplitView
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.image, .svgImage], allowsMultipleSelection: true) { result in
            if let urls = try? result.get() { handleImportedURLs(urls) }
        }
    } // End of body property
    
    // MARK: - 核心布局逻辑
    
    @ViewBuilder
    func layoutContainer(proxy: GeometryProxy) -> some View {
        // 🔥 使用 AnyLayout 保持视图层级一致性 (View Identity Preservation)
        // 这样当布局从 Vertical 切换到 Horizontal 时，子视图 (ForEach) 不会被销毁重建
        //从而 dragGesture 不会被打断！这就是"卡住"的原因。
        //从而 dragGesture 不会被打断！这就是"卡住"的原因。
        let layout = activeDirection == .vertical 
            ? AnyLayout(VStackLayout(spacing: 16))
            : AnyLayout(HStackLayout(spacing: 16))
            
        layout {
            cardsView(containerSize: proxy.size)
        }
    }
    
    @ViewBuilder
    func cardsView(containerSize: CGSize) -> some View {
        ForEach(files, id: \.self) { url in
            StitchImageCard(url: url, direction: activeDirection, isSelected: selection.contains(url), zoomScale: zoomScale, onDelete: {
                withAnimation {
                    if let idx = files.firstIndex(of: url) { files.remove(at: idx) }
                }
            })
            // 📏 Capture exact size
            .background(GeometryReader { geo in
                Color.clear.preference(key: ItemSizePreferenceKey.self, value: [url: geo.size])
            })
            // 🔥 核心修正：
            // 1. 被拖拽的原始卡片变为透明占位符 (Opacity 0)
            // 2. 手势绑定在占位符上，更新全局状态
            // 3. Multi-selection: Hide ALL selected items when dragging
            .opacity(draggingURL != nil && (draggingURL == url || (selection.contains(draggingURL!) && selection.contains(url))) ? 0.0 : 1.0)
            .onTapGesture {
                // Click to Select
                if NSEvent.modifierFlags.contains(.command) {
                    if selection.contains(url) {
                        selection.remove(url)
                    } else {
                        selection.insert(url)
                    }
                } else {
                    selection = [url]
                }
            }
            .gesture(
                DragGesture(coordinateSpace: .named("canvas"))
                    .onChanged { value in
                        handleDragChanged(value: value, item: url)
                    }
                    .onEnded { _ in
                        handleDragEnded()
                    }
            )
        }
    }
    
    // MARK: - 🔥 纯手势核心逻辑 (Overlay Mode)
    
    private func handleDragChanged(value: DragGesture.Value, item: URL) {
        // 1. 激活拖拽状态 & 记录初始索引
        if draggingURL == nil {
            withAnimation(.interactiveSpring(response: 0.2, dampingFraction: 0.6)) {
                draggingURL = item
            }
            initialDragIndex = files.firstIndex(of: item)
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
        }
        
        // 2. 更新全局坐标 (让 Overlay 跟随鼠标)
        dragLocation = value.location
        
        // 3. 实时重排：基于初始索引 + 位移投影 (Index Projection)
        // 这种算法比逐个交换更稳定，因为它基于绝对位移
        guard let fromIndex = files.firstIndex(of: item),
              let startIndex = initialDragIndex else { return }
        
        // Horizontal: Var Width (Base ~220) + 16
        // Vertical: Var Height (Base ~220) + 16
        let stride: CGFloat = 236 // 220 + 16 (Approximation)
        
        // 计算目标索引位移
        // 比如向右移了 200px -> 200/196 = 1 -> 目标索引 = 初始索引 + 1
        let translation = activeDirection == .vertical ? value.translation.height : value.translation.width
        let offsetStep = Int(round(translation / stride))
        
        var toIndex = startIndex + offsetStep
        
        // 边界限制
        toIndex = max(0, min(files.count - 1, toIndex))
        
        if toIndex != fromIndex {
             withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                // 🔥 Multi-selection group move
                // If dragged item is part of selection, move ALL selected items together
                let itemsToMove: [URL]
                if selection.contains(item) && selection.count > 1 {
                    // Get selected items in their current order
                    itemsToMove = files.filter { selection.contains($0) }
                } else {
                    itemsToMove = [item]
                }
                
                // Remove all items to move
                files.removeAll { itemsToMove.contains($0) }
                
                // Calculate insertion index (may have shifted after removal)
                let adjustedToIndex = min(toIndex, files.count)
                
                // Insert all items at the target position, maintaining their relative order
                for (offset, url) in itemsToMove.enumerated() {
                    files.insert(url, at: min(adjustedToIndex + offset, files.count))
                }
            }
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
        }
        
        // 4. 智能边缘检测
        // 4. 智能边缘检测 (带 Debounce)
        let now = Date()
        if now.timeIntervalSince(lastLayoutSwitchTime) > 0.8 { // 0.8s Cooldown
            // 🔥 Tuned Threshold: 150 for V->H (Horizontal Drag)
            // 🔥 Tuned Animation: Damping 0.85
            if abs(value.translation.width) > 150 && activeDirection == .vertical {
                 withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                     activeDirection = .horizontal
                 }
                 lastLayoutSwitchTime = now
                 NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
            // 🔥 Tuned Threshold: 100 (was 150) for H->V (Vertical Drag) to feel easier
            } else if abs(value.translation.height) > 100 && activeDirection == .horizontal {
                 withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                     activeDirection = .vertical
                 }
                 lastLayoutSwitchTime = now
                 NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
            }
        }
    }
    
    private func handleDragEnded() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) {
            draggingURL = nil
            initialDragIndex = nil
        }
    }
    
    func updateScrollOffset(_ geo: GeometryProxy) {
        let frame = geo.frame(in: .named("canvas"))
        currentScrollOffset = CGPoint(x: -frame.origin.x, y: -frame.origin.y)
    }
    
    // MARK: - Logic Helpers
    
    @MainActor
    func handleExternalDrop(_ providers: [NSItemProvider]) -> Bool {
        Task {
            var newUrls: [URL] = []
            for provider in providers {
                if let item = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil),
                   let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    newUrls.append(url)
                }
            }
            await MainActor.run { handleImportedURLs(newUrls) }
        }
        return true
    }
    
    func handleImportedURLs(_ urls: [URL]) {
        let allowed = ImageSourceSupport.supportedImageExtensions
        let filtered = urls.filter { allowed.contains($0.pathExtension.lowercased()) }
        withAnimation {
            for url in filtered {
                if !files.contains(url) { files.append(url) }
            }
        }
    }
    
    @discardableResult
    func startStitching() async -> Bool {
        guard files.count > 1, !isProcessing else { return false }
        isProcessing = true
        let ordered = files
        let dir = activeDirection
        let format = targetFormat
        let q = quality
        let opt = mobileOptimize
        
        // 显式使用 .userInitiated 优先级以避免优先级反转警告 (Hang Risk)
        let success = await Task(priority: .userInitiated) {
            await ImageStitcher.processOrdered(
                imageURLs: ordered,
                direction: dir,
                targetFormat: format,
                quality: q,
                mobileOptimize: opt
            )
        }.value
        
        if success {
            withAnimation {
                files.removeAll()
                selection.removeAll()
            }
        }
        isProcessing = false
        return success
    }

    // MARK: - Selection Logic
    
    @State private var lastMarqueeUpdateTime: Date = .distantPast
    
    private func updateSelectionWithMarquee() {
        // Throttle to ~20fps for complex O(N) calculations (50ms)
        let now = Date()
        if now.timeIntervalSince(lastMarqueeUpdateTime) < 0.05 { return }
        lastMarqueeUpdateTime = now
        
        // Calculate Frames logic
        // We simulate the Stack layout
        var currentOffset: CGFloat = 0
        let spacing: CGFloat = 16
        
        // Use initial selection as base if Cmd is pressed?
        // Usually marquee behaves: New selection = (Selected in Marquee)
        // If Cmd held: New Selection = (Old Selection) XOR (Selected in Marquee)?
        // Or Union?
        // Finder:
        // No modifier: Clears old, selects inside.
        // Shift/Cmd: Toggles/Adds.
        // Let's implement: No modifier = Replace. Cmd = Toggle.
        
        var newInMarquee: Set<URL> = []
        
        // 🔥 Coordinate Transform: Viewport -> Unscaled Content
        // The content is CENTERED in the viewport via `.frame(..., alignment: .center)`
        // So we need to calculate where the content actually starts
        let ox = currentScrollOffset.x
        let oy = currentScrollOffset.y
        let z = zoomScale
        
        // Scaled content size
        let scaledContentW = contentSize.width * z
        let scaledContentH = contentSize.height * z
        
        // Viewport size (approximation - we use contentSize as proxy since we don't have proxy here)
        // Actually, the frame is `max(viewport, scaledContent)`, and content is centered.
        // Let's get the actual viewport from the outer frame.
        // For now, assume viewport >= scaledContent (common case), so centering offset exists.
        // The content's top-left in viewport coords = ((viewportW - scaledContentW)/2, (viewportH - scaledContentH)/2) + offset
        // But we don't have viewportSize here. Let's use itemSizes-based approach instead:
        // The items are laid out from (0,0) in content-local coords.
        // The marquee is in viewport coords.
        // Transform: content-local = (viewport - offset - centeringOffset) / z
        // Since we don't have viewportSize, we can infer:
        // The content is placed at offset = currentScrollOffset from its center.
        // This is complex. Let's simplify by using the stored viewportSize if available.
        
        // Actually, re-reading the layout:
        // Line 231: `.frame(width: max(proxy.size.width, contentSize.width * z), ...)`
        // This creates a frame that's at least viewport-sized.
        // Content inside is centered (default alignment).
        // So if viewport > scaledContent, content is centered.
        // Content origin in this frame = ((frameW - scaledContentW)/2, (frameH - scaledContentH)/2)
        // frameW = max(viewportW, scaledContentW)
        // If scaledContentW < viewportW: contentOriginX = (viewportW - scaledContentW)/2
        // If scaledContentW >= viewportW: contentOriginX = 0
        
        // The marquee is drawn in "canvas" coordinate space (line 291: .coordinateSpace(name: "canvas"))
        // This is on the root ZStack, AFTER the frame(proxy.size) modifier.
        // So marquee coords are in viewport space (0,0) = top-left of visible area.
        
        // 🔥 Calculate centering offset using viewportSize
        // The content is centered when smaller than viewport
        let frameW = max(viewportSize.width, scaledContentW)
        let frameH = max(viewportSize.height, scaledContentH)
        let centeringOffsetX = (frameW - scaledContentW) / 2
        let centeringOffsetY = (frameH - scaledContentH) / 2
        
        // Transform marquee from viewport coords to content-local coords:
        // 1. Subtract scroll offset (ox, oy) - content moves with offset
        // 2. Subtract centering offset - content is shifted down/right when centered
        // 3. Divide by zoom scale - content coordinates are unscaled
        let contentMarquee = CGRect(
            x: (selectionRect.minX - ox - centeringOffsetX) / z,
            y: (selectionRect.minY - oy - centeringOffsetY) / z,
            width: selectionRect.width / z,
            height: selectionRect.height / z
        )
        
        for url in files {
            guard let size = itemSizes[url] else { continue }
            
            let frame: CGRect
            if activeDirection == .vertical {
                // Centered horizontally in contentSize
                // Note: contentSize includes Zoom? No, we used `max(1, contentSize.width)` in minimap.
                // In `layoutContainer`, we use `AnyLayout` with `cardsView`.
                // `itemSizes` are UNZOOOMED (captured in `background(GeometryReader)` inside `cardsView` inside `scaleEffect`).
                // Wait. `cardsView` is inside `scaleEffect`?
                // Line 175: `layoutContainer...scaleEffect(zoomScale)`.
                // So `cardsView` is Unscaled coordinates.
                // `contentSize` is captured by `background(GeometryReader)` on `layoutContainer` (Line 165).
                // Since `scaleEffect` is AFTER `background` (Line 175 > 165), `contentSize` is UNZOOOMED.
                // Correct.
                
                let x = (contentSize.width - size.width) / 2
                frame = CGRect(x: x, y: currentOffset, width: size.width, height: size.height)
                currentOffset += size.height + spacing
            } else {
                // Centered vertically
                let y = (contentSize.height - size.height) / 2
                frame = CGRect(x: currentOffset, y: y, width: size.width, height: size.height)
                currentOffset += size.width + spacing
            }
            
            if contentMarquee.intersects(frame) {
                newInMarquee.insert(url)
            }
        }
        
        if NSEvent.modifierFlags.contains(.command) {
            // Toggle logic or Union? Finder usually extends. 
            // Let's do Union for simplicity with marquee, or Symmetric Difference?
            // Standard: Union with existing `initialSelection`.
            // Any item initially selected REMAINS selected.
            // Any item in marquee BECOMES selected.
            // Real Finder behavior is subtle (Cmd+Marquee toggles).
            // Let's stick to Union (easier for users to understand "add").
            // Actually, Symmetric Difference (Toggle) is more powerful.
            // Let's do: Base + New.
            selection = initialSelection.union(newInMarquee)
        } else {
            selection = newInMarquee
        }
    }
    
    // MARK: - Components
    
    var toolbarView: some View {
        HStack(spacing: 12) {
            Button(action: { isImporting = true }) {
                Image(systemName: "plus").font(.system(size: 14, weight: .semibold))
            }.buttonStyle(.plain)
            
            Divider().frame(height: 16)
            Text("\(files.count) 张").font(.caption).foregroundStyle(.secondary)
            
            if !files.isEmpty {
                Divider().frame(height: 16)
                Button(action: { withAnimation { files.removeAll() } }) {
                    Image(systemName: "trash").foregroundStyle(.red)
                }.buttonStyle(.plain).disabled(isProcessing)
            }
        }

        .padding(12)
        .background(
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                Color.white.opacity(0.1) // Extra brightness boost for "pop"
            }
        )
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.12), radius: 6, x: 0, y: 3)
        .overlay(
            Capsule()
                .strokeBorder(.white.opacity(0.4), lineWidth: 0.5)
        )
    }
    
    var settingsPanel: some View {
        VStack(spacing: 0) {
            Form {
                Section("布局设置") {
                    Picker("拼接方向", selection: Binding(
                        get: { activeDirection },
                        set: { newValue in
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                activeDirection = newValue
                            }
                        }
                    )) {
                        Text("纵向").tag(StitchDirection.vertical)
                        Text("横向").tag(StitchDirection.horizontal)
                    }
                    .pickerStyle(.segmented)
                }
                Section("输出配置") {
                    Picker("目标格式", selection: $targetFormat) {
                        ForEach(ImageConverter.TargetFormat.allCases, id: \.self) { fmt in
                            Text(fmt.rawValue.uppercased()).tag(fmt)
                        }
                    }
                    Slider(value: $quality, in: 0.1...1.0) {
                         Text("质量 \(Int(quality * 100))%")
                    }
                    
                    Toggle("适合移动设备", isOn: $mobileOptimize)
                        .help("以 iPhone 17 标准版 (1206px) 为基准优化拼接图尺寸")
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(.regularMaterial) // Glass effect
            
            Divider()
            
            VStack(spacing: 16) {
                Button(action: {
                    Task { await startStitching() }
                }) {
                    HStack(spacing: 8) {
                        if isProcessing {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "wand.and.stars")
                        }
                        Text(isProcessing ? "处理中..." : "开始拼接")
                            .fontWeight(.bold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .disabled(files.count < 2 || isProcessing)
                .controlSize(.large)
                .shadow(color: .blue.opacity(0.2), radius: 8, x: 0, y: 4)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .background {
                 Rectangle()
                     .fill(.thinMaterial)
                     .overlay(alignment: .top) { Divider() }
            }
        }
        .frame(minWidth: 260, maxWidth: 350)
    }
    
    // MARK: - Subviews (Refined)
    
    struct StitchImageCard: View {
        let url: URL
        let direction: StitchDirection
        let isSelected: Bool 
        let zoomScale: CGFloat // ✨ Pass zoomScale to maintain button sharpness
        let onDelete: () -> Void
        @State private var isHovering = false
        
        var body: some View {
            VStack(spacing: 0) {
                AsyncThumbnailView(url: url, maxSize: 1500)
                    .padding(8)
            }
            .frame(width: direction == .vertical ? 220 : nil, height: direction == .horizontal ? 220 : nil)
            .fixedSize(horizontal: direction == .horizontal, vertical: direction == .vertical)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isSelected ? Color.blue : (isHovering ? Color.blue.opacity(0.5) : Color.white.opacity(0.1)), lineWidth: isSelected ? 3 : (isHovering ? 2 : 1))
            )
            .overlay(alignment: .topTrailing) {
                if isHovering || isSelected {
                    if isHovering {
                        Button(action: onDelete) {
                            let baseSize: CGFloat = 20
                            let targetSize = baseSize * max(1.0, zoomScale)
                            
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: targetSize))
                                .foregroundStyle(.white, .red.opacity(0.9))
                                .background(
                                    Circle()
                                        .fill(.white)
                                        // Padding also needs to be larger for high-res Circle background
                                        .padding(2 * max(1.0, zoomScale))
                                )
                                .scaleEffect(1.0 / max(1.0, zoomScale))
                                .frame(width: baseSize, height: baseSize) // 🔥 Force fixed layout size back to original to keep alignment static
                                .shadow(color: .black.opacity(0.2), radius: 2)
                        }
                        .buttonStyle(.plain)
                        .offset(x: 8, y: -8)
                        .transition(.opacity)
                    }
                }
            }
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
        }
    }
    
    struct AsyncThumbnailView: View {
        let url: URL
        let maxSize: CGFloat
        @State private var image: NSImage?
        
        init(url: URL, maxSize: CGFloat) {
            self.url = url
            self.maxSize = maxSize
            // 同步读取缓存，防止闪烁
            if let cached = ThumbnailCache.shared.image(for: url, size: maxSize) {
                _image = State(initialValue: cached)
            }
        }
        
        var body: some View {
            Group {
                if let img = image {
                    Image(nsImage: img)
                        .resizable()
                        .antialiased(true) // 🔥 Ensure smooth scaling
                        .aspectRatio(img.size, contentMode: .fit) // 🔥 Force explicit ratio from verified size
                        .cornerRadius(4)
                } else {
                    ProgressView().scaleEffect(0.5)
                        .frame(width: 100, height: 100) // Placeholder size
                }
            }
            .task { if image == nil { await load() } }
        }
        
        func load() async {
            if let cached = ThumbnailCache.shared.image(for: url, size: maxSize) {
                image = cached; return
            }
            let scale = await MainActor.run { NSScreen.main?.backingScaleFactor ?? 2.0 }
            let size = Int(maxSize * scale)
            let generated = await Task.detached { () -> NSImage? in
                let opts = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: size] as CFDictionary
                guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts) else { return nil }
                // 🔥 Critical Fix: Normalize to points to avoid coordinate precision issues at low zoom
                let pointSize = NSSize(width: CGFloat(cg.width) / scale, height: CGFloat(cg.height) / scale)
                return NSImage(cgImage: cg, size: pointSize)
            }.value
            
            if let generated {
                ThumbnailCache.shared.insert(generated, for: url, size: maxSize)
                withAnimation(.easeIn(duration: 0.1)) { image = generated }
            }
        }
    }
    
    struct EmptyStateDropZone: View {
        let onBrowse: () -> Void
        let onDrop: ([URL]) -> Void
        @State private var isTargeted = false
        
        var body: some View {
            VStack(spacing: 16) {
                Image(systemName: "square.fill.text.grid.1x2")
                    .font(.system(size: 48))
                    .foregroundStyle(isTargeted ? .blue : .secondary.opacity(0.3))
                Text("拖拽图片到这里拼接").font(.headline)
                Button("浏览文件") { onBrowse() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(isTargeted ? Color.blue.opacity(0.1) : Color.clear)
            .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
                Task {
                    var newUrls: [URL] = []
                    for provider in providers {
                        if let item = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil),
                           let data = item as? Data,
                           let url = URL(dataRepresentation: data, relativeTo: nil) {
                            newUrls.append(url)
                        }
                    }
                    await MainActor.run { onDrop(newUrls) }
                }
                return true
            }
        }
    }
    
// MARK: - Reusable Layout
struct StitchingLayout<Content: View>: View {
    let direction: StitchDirection
    let spacing: CGFloat
    @ViewBuilder var content: () -> Content
    
    var body: some View {
        if direction == .vertical {
            VStack(spacing: spacing) { content() }
        } else {
            HStack(spacing: spacing) { content() }
        }
    }
}

struct MinimapView: View {
        let files: [URL]
        let direction: StitchDirection
        let contentSize: CGSize
        let viewportSize: CGSize
        @Binding var canvasOffset: CGPoint
        let zoomScale: CGFloat
        
        @State private var dragStartOffset: CGPoint?
        
        var body: some View {
            if !files.isEmpty {
                GeometryReader { proxy in
                    let mapSize = proxy.size
                    
                    // 1. 计算"虚拟画布"的尺寸 (Virtual Canvas Size)
                    // 主界面逻辑：frame = max(viewport, content * zoom)
                    // Minimap 需要显示这个完整的区域
                    
                    // 为了简单且忠实，Minimap 的逻辑应该是：
                    // 显示完整的 Content (未缩放的)，然后缩放到 mapSize 内 fit。
                    // 但是主界面是可以无限滚动的，Minimap 应该代表"当前可见及可滚动区域"。
                    
                    // 安全尺寸，防止除以0
                    let realContentW = max(1, contentSize.width)
                    let realContentH = max(1, contentSize.height)
                    
                    // 计算合适的缩放比例，让 content 能够塞进 mapSize
                    // 保持长宽比 (Aspect Fit)
                    let scaleX = mapSize.width / realContentW
                    let scaleY = mapSize.height / realContentH
                    let mapScale = min(scaleX, scaleY)
                    
                    // 3. 视口框 (Viewport Box) 计算 - 基于中心对齐机制
                    // 核心逻辑：
                    // 在主界面，Content 是居中的 (alignment: .center)。
                    // 初始状态下(Offset=0)，Viewport 中心与 Content 中心重合。
                    // 用户拖动 Offset 后，Content 移动，Viewport 从 Content 视角看发生了相对位移。
                    // 
                    // Minimap 坐标系：
                    // mapSize = Minimap 容器大小
                    // Content 也是居中放置在 Minimap 里的。
                    // 所以：Minimap Center == Content Center (Initial Viewport Center)
                    
                    let mapCenterX = mapSize.width / 2
                    let mapCenterY = mapSize.height / 2
                    
                    // Viewport 在 Minimap 里的尺寸
                    let viewportRectW = (viewportSize.width / zoomScale) * mapScale
                    let viewportRectH = (viewportSize.height / zoomScale) * mapScale
                    
                    // 此处 Offset 是主界面 Content 的偏移量
                    // 如果 Content 向左移 (-x)，意味着 Viewport 相对向右移 (+x)
                    // 所以 Viewport 中心的偏移量 = -canvasOffset
                    let viewportCenterOffsetX = (-canvasOffset.x / zoomScale) * mapScale
                    let viewportCenterOffsetY = (-canvasOffset.y / zoomScale) * mapScale
                    
                    // 最终 Viewport Box 的位置 (TopLeading)
                    // BoxCenterX = MapCenterX + OffsetX
                    // BoxTopLeft = BoxCenterX - BoxWidth/2
                    let boxAbsX = (mapCenterX + viewportCenterOffsetX) - (viewportRectW / 2)
                    let boxAbsY = (mapCenterY + viewportCenterOffsetY) - (viewportRectH / 2)
                    
                    ZStack(alignment: .topLeading) {
                        
                        // === 1. 内容层 (Mini Content) ===
                        // 隔离渲染：使用子视图承载，防止父级状态更新导致整个 Minimap 重绘
                        MinimapCardsView(files: files, direction: direction)
                        .frame(width: realContentW, height: realContentH, alignment: .center)
                        .scaleEffect(mapScale, anchor: .center) 
                        .frame(width: mapSize.width, height: mapSize.height, alignment: .center) 
                        
                        // === 2. 视口框 (The White Box) ===
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.white, lineWidth: 2)
                            .background(Color.white.opacity(0.1))
                            .frame(width: max(4, viewportRectW), height: max(4, viewportRectH))
                            .position(x: boxAbsX + viewportRectW/2, y: boxAbsY + viewportRectH/2) // Posiiton 使用中心坐标
                            .shadow(color: .black.opacity(0.3), radius: 2)
                            // Gesture removed from here
                    }
                    .frame(width: mapSize.width, height: mapSize.height) // 🔥 Force Frame
                    .contentShape(Rectangle()) // 🔥 Hit Test Limit
                    .clipped()
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                if dragStartOffset == nil { dragStartOffset = canvasOffset }
                                guard let start = dragStartOffset else { return }
                                
                                // 逆向计算：Box 移动 delta -> Canvas Offset 变化 -delta
                                let factor = zoomScale / mapScale
                                let deltaX = value.translation.width * factor
                                let deltaY = value.translation.height * factor
                                
                                canvasOffset = CGPoint(x: start.x - deltaX, y: start.y - deltaY)
                            }
                            .onEnded { _ in dragStartOffset = nil }
                    )
                }
                .frame(width: 160, height: 160)
                .background(.ultraThinMaterial) // 移除灰色背景，只保留高斯模糊，更清爽
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                )
                .padding(20)
                .transition(.opacity)
            }
        }
        
}

// MARK: - 性能优化隔离视图：Minimap 内的卡片渲染
struct MinimapCardsView: View {
    let files: [URL]
    let direction: StitchDirection
    
    var body: some View {
        let layout = direction == .vertical 
            ? AnyLayout(VStackLayout(spacing: 16))
            : AnyLayout(HStackLayout(spacing: 16))
            
        layout {
            let limit = 20
            ForEach(files.prefix(limit), id: \.self) { url in
                ZStack {
                    Color(nsColor: .controlBackgroundColor)
                    AsyncThumbnailView(url: url, maxSize: 300)
                        .padding(4)
                }
                .frame(width: 220)
                .fixedSize(horizontal: false, vertical: true)
                .aspectRatio(contentMode: .fit)
                .cornerRadius(12)
                .shadow(color: .black.opacity(0.2), radius: 4)
            }
            if files.count > limit {
                Rectangle()
                    .fill(Color.secondary.opacity(0.2))
                    .frame(width: 220, height: 220)
            }
        }
    }
}

// MARK: - Event Handling
// MARK: - Event Handling (Fixed & Smooth)
struct ScrollEventHandlingView: NSViewRepresentable {
    @Binding var offset: CGPoint
    @Binding var zoomScale: CGFloat
    
    func makeNSView(context: Context) -> NSScrollEventView {
        let view = NSScrollEventView()
        context.coordinator.setup(view: view)
        return view
    }
    
    func updateNSView(_ nsView: NSScrollEventView, context: Context) {
        context.coordinator.setup(view: nsView)
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator {
        var parent: ScrollEventHandlingView
        
        init(_ parent: ScrollEventHandlingView) {
            self.parent = parent
        }
        
        func setup(view: NSScrollEventView) {
            view.onScroll = { [weak self] delta in
                guard let self = self else { return }
                // 简单的平移叠加
                // 添加一个阻尼系数 1.5 让滚动稍微快一点点，符合直觉
                let newX = self.parent.offset.x + delta.x * 1.5
                let newY = self.parent.offset.y + delta.y * 1.5
                self.parent.offset = CGPoint(x: newX, y: newY)
            }
            
            view.onMagnify = { [weak self] magnification, mouseLoc in
                guard let self = self else { return }
                
                let oldScale = self.parent.zoomScale
                
                // 1. 计算新比例
                // 直接使用 (1 + mag) 进行乘法运算，不再人为 damp 0.05
                // 系统的 magnification 已经包含了物理手感
                var newScale = oldScale * (1 + magnification)
                
                // 2. 限制缩放范围 (0.1x 到 5.0x)
                newScale = max(0.1, min(5.0, newScale))
                
                // 3. 核心：锚点修正算法 (Anchor Point Correction)
                // 这是一个纯几何问题：
                // 我们希望鼠标指向的那个"内容点"，在缩放前后，相对于屏幕的位置保持不变。
                
                // A. 计算鼠标在"当前缩放层级的内容"中的相对位置 (Visual Vector)
                //    mouseLoc 是相对于 View 左上角的坐标
                //    offset 是 View 左上角相对于内容的偏移 (通常是负数)
                //    visiblePoint = mouseLoc - offset
                
                // B. 还原到"未缩放(1.0x)"时的绝对内容坐标 (Absolute Content Coordinate)
                //    anchorPoint = (mouseLoc - offset) / oldScale
                let anchorX = (mouseLoc.x - self.parent.offset.x) / oldScale
                let anchorY = (mouseLoc.y - self.parent.offset.y) / oldScale
                
                // C. 计算新 Offset
                //    我们希望: newMouseLoc == oldMouseLoc
                //    即: newOffset + (anchorPoint * newScale) == mouseLoc
                //    所以: newOffset = mouseLoc - (anchorPoint * newScale)
                let newOffsetX = mouseLoc.x - (anchorX * newScale)
                let newOffsetY = mouseLoc.y - (anchorY * newScale)
                
                // 4. 应用状态
                self.parent.zoomScale = newScale
                self.parent.offset = CGPoint(x: newOffsetX, y: newOffsetY)
            }
        }
    }
    
    class NSScrollEventView: NSView {
        var onScroll: ((CGPoint) -> Void)?
        var onMagnify: ((CGFloat, CGPoint) -> Void)?
        
        override var acceptsFirstResponder: Bool { true }
        // 关键：SwiftUI 坐标系是左上角为原点，AppKit 默认左下角。
        // 必须翻转坐标系，否则缩放时锚点会上下颠倒，导致"疯了一样"乱跳。
        override var isFlipped: Bool { true }
        
        override func scrollWheel(with event: NSEvent) {
            // 将滚轮事件转换为点位移
            onScroll?(CGPoint(x: event.scrollingDeltaX, y: event.scrollingDeltaY))
        }
        
        override func magnify(with event: NSEvent) {
            let loc = convert(event.locationInWindow, from: nil)
            onMagnify?(event.magnification, loc)
        }
    }
}

// MARK: - PreferenceKeys
struct ItemSizePreferenceKey: PreferenceKey {
    static var defaultValue: [URL: CGSize] = [:]
    static func reduce(value: inout [URL: CGSize], nextValue: () -> [URL: CGSize]) {
        value.merge(nextValue()) { $1 }
    }
}
}
