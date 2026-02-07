//
//  LiquidConvertApp.swift
//  LiquidConvert
//
//  Created by Shawn Rain.
//

import AppKit
import Combine
import SwiftUI
import UserNotifications

// 🔥 全局状态管理
enum SettingsTab: String {
    case general
    case profile
    case about
}

// 1. 使用枚举定义 Tab (Moved from ContentView)
enum TabIdentifier: String, CaseIterable {
    case home, audio, compress, stitch, videogif, icns, settings
}

@MainActor
class AppState: ObservableObject {
    @Published var settingsTab: SettingsTab = .general
    
    // 🔥 全局 Tab 导航状态
    @Published var selectedTab: TabIdentifier? = .home
    
    // 🚦 Navigation Guard State
    @Published var isStitchingDirty = false
    @Published var showUnsavedAlert = false
    var pendingTab: TabIdentifier?
    
    var openSettingsAction: (() -> Void)?

    func requestTabChange(to tab: TabIdentifier) {
        // Intercept navigation if leaving Stitching view with unsaved changes
        if selectedTab == .stitch && isStitchingDirty && tab != .stitch {
            print("⚠️ Stitching view is dirty, requesting confirmation")
            pendingTab = tab
            showUnsavedAlert = true
        } else {
            selectedTab = tab
            pendingTab = nil
        }
    }
    
    func confirmDiscardChanges() {
        if let target = pendingTab {
            print("🗑️ Discarding changes, navigating to \(target)")
            selectedTab = target
            isStitchingDirty = false // Reset dirty state as view will be recreated
        }
        pendingTab = nil
        showUnsavedAlert = false
    }
    
    func cancelNavigation() {
        print("❌ Navigation cancelled")
        pendingTab = nil
        showUnsavedAlert = false
    }

    // 💾 Save Interception
    var requestSaveAction: (() async -> Bool)?
    
    func performSaveAndLeave() async {
        print("💾 Requesting Save & Leave...")
        guard let action = requestSaveAction else {
            print("❌ No save action registered")
            cancelNavigation()
            return
        }
        
        let success = await action()
        if success {
            print("✅ Save successful, navigating away")
            confirmDiscardChanges()
        } else {
            print("❌ Save failed or cancelled, staying")
            cancelNavigation()
        }
    }

    func openSettingsToAbout() {
        print("🔘 Menu 'About' clicked. Switching to Settings Tab")
        
        // Use requestTabChange to ensure safety
        requestTabChange(to: .settings)
        // If navigation succeeds (or is forced later), we need to ensure right sub-tab
        // But since requestTabChange might block, we should only set settingsTab if we actually move?
        // For simplicity, we set it. If blocked, users stay in Stitching. 
        // If they discard, they go to Settings. 
        // However, if they stay, settingsTab is changed "in background" which is fine.
        settingsTab = .about
        
        // 确保应用激活
        NSApp.activate(ignoringOtherApps: true)
    }
}

// 🔥 1. 创建 AppDelegate 处理通知代理和文件打开
class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    // 🔥 跟踪App是否已完成启动
    private var didFinishLaunching = false
    // 🔥 标记是否需要隐藏窗口 (静默模式)
    private var shouldHideWindow = false

    // 🔥 跟踪是否由文件拖放启动
    private var isLaunchedByFileDrop = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("✅ App启动完成")
        didFinishLaunching = true

        // 🔥 如果是静默启动，隐藏所有窗口并转为后台应用
        if shouldHideWindow {
            print("🤫 静默模式：隐藏窗口")
            // 延迟一点确保窗口已被创建
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                NSApp.windows.forEach { $0.close() }
                NSApp.setActivationPolicy(.accessory) // 隐藏 Dock 图标和菜单栏
            }
        }
        
        // 请求通知权限
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) {
            granted, error in
            if let error = error {
                print("Notification permission error: \(error)")
            }
        }
        // 设置代理
        UNUserNotificationCenter.current().delegate = self
    }

    // 🔥 关键：让 App 在前台也能显示通知
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    // 🔥 防止打开新的空白窗口
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        print("🚫 阻止打开空白窗口")
        return false
    }

    // MARK: - Dock 拖拽防抖处理
    private var pendingDropURLs: [URL] = []
    private var dropTimer: Timer?
    
    // 🔥 处理拖拽到 Dock 图标的文件 - 新方法（更可靠）
    func application(_ application: NSApplication, open urls: [URL]) {
        print("🔵🔵🔵 [Dock] 收到 \(urls.count) 个URL (缓冲中...)")
        urls.forEach { print("   📄 \($0.path)") }
        
        // 🔥 关键：如果在 App 启动完成前收到文件，说明是冷启动拖入
        if !didFinishLaunching {
            print("🚀 检测到冷启动拖入，标记为静默模式 & 自动退出")
            isLaunchedByFileDrop = true
            shouldHideWindow = true
        }
        
        pendingDropURLs.append(contentsOf: urls)
        resetDropTimer()
    }

    // 🔥 旧方法也保留（兼容性）
    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        print("🔵 [Dock-旧] 收到单个文件: \(filename) (缓冲中...)")
        
        if !didFinishLaunching {
            isLaunchedByFileDrop = true
            shouldHideWindow = true
        }

        let url = URL(fileURLWithPath: filename)
        pendingDropURLs.append(url)
        resetDropTimer()
        return true
    }

    // 🔥 旧方法也保留（兼容性）
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        print("🔵 [Dock-旧] 收到多个文件: \(filenames.count) 个 (缓冲中...)")
        
        if !didFinishLaunching {
            isLaunchedByFileDrop = true
            shouldHideWindow = true
        }

        let urls = filenames.map { URL(fileURLWithPath: $0) }
        pendingDropURLs.append(contentsOf: urls)
        resetDropTimer()
    }
    
    private func resetDropTimer() {
        dropTimer?.invalidate()
        dropTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
            self?.fireDropHandler()
        }
    }
    
    private func fireDropHandler() {
        let urls = self.pendingDropURLs
        self.pendingDropURLs = [] // 清空缓冲区
        
        guard !urls.isEmpty else { return }
        
        print("🔥 [防抖触发] 最终处理 \(urls.count) 个文件")

        // 使用 flag 判断是否需要退出
        let shouldQuitAfter = isLaunchedByFileDrop
        if shouldQuitAfter {
            print("🔖 取出模式：App由文件拖入启动，处理完成后将自动退出")
        } else {
            print("🔖 保持模式：App此前已在运行")
        }

        handleDroppedFiles(urls, shouldQuitAfter: shouldQuitAfter)
    }

    // 🔥 统一处理拖拽文件的逻辑
    private func handleDroppedFiles(_ urls: [URL], shouldQuitAfter: Bool) {
        print("🟢 [处理] 开始处理 \(urls.count) 个文件")

        // 过滤出图片文件
        let imageExtensions = [
            "jpg", "jpeg", "png", "heic", "webp", "tiff", "tif", "bmp", "gif", "raw", "cr2", "nef",
            "arw", "avif",
        ]
        let imageFiles = urls.filter { url in
            imageExtensions.contains(url.pathExtension.lowercased())
        }

        print("🟡 [过滤] 找到 \(imageFiles.count) 个图片文件")
        imageFiles.forEach { print("   ✓ \($0.lastPathComponent)") }

        guard !imageFiles.isEmpty else {
            print("❌ [错误] 没有找到图片文件")
            if shouldQuitAfter {
                print("👋 无文件需处理，退出App")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    NSApp.terminate(nil)
                }
            }
            return
        }

        print("🚀 [启动] 开始后台静默转换任务")
        // 后台静默转换（无任何UI提示）

        Task.detached(priority: .userInitiated) {
            
            // 🔥 分支逻辑：单张图 vs 多张图
            if imageFiles.count > 1 {
                print("🧩 检测到多张图片，进入拼接模式")
                await ImageStitcher.process(imageURLs: imageFiles)
            } else {
                print("🔄 检测到单张图片，进入普通转换模式")
                await ImageConverter.convertSilently(imageURLs: imageFiles)
            }

            // 🔥 如果是通过拖入文件启动，处理完成后退出
            if shouldQuitAfter {
                print("👋 处理完成，自动退出App")
                await MainActor.run {
                    // 延迟一点以确保通知发送完成
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        NSApp.terminate(nil)
                    }
                }
            }
        }
    }
}

@main
struct LiquidConvertApp: App {
    // 🔥 2. 绑定代理
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    // 🔥 全局状态
    @StateObject private var appState = AppState()

    @AppStorage("app_appearance") private var appearance: AppAppearance = .system

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 1100, minHeight: 700)
                .background(
                    VisualEffectBackground(
                        material: .underWindowBackground, blendingMode: .behindWindow)
                )
                .preferredColorScheme(colorScheme)
                .environmentObject(appState)
                .onAppear {
                    applyTheme(appearance)
                }
                .onChange(of: appearance) { old, newValue in
                    applyTheme(newValue)
                }
        }
        .handlesExternalEvents(matching: [])
        .windowStyle(.hiddenTitleBar)

        // 🔥 自定义菜单：替换默认的"关于"行为
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("关于 LiquidConvert") {
                    appState.openSettingsToAbout()
                }
            }
            
            // 拦截偏好设置快捷键 (Command+,)
            CommandGroup(replacing: .appSettings) {
                Button("偏好设置...") {
                    appState.selectedTab = .settings
                }
                .keyboardShortcut(",", modifiers: .command)
            }

            // 移除"新建"菜单项
            CommandGroup(replacing: .newItem) {
                EmptyView()
            }
        }
    }

    var colorScheme: ColorScheme? {
        switch appearance {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    private func applyTheme(_ theme: AppAppearance) {
        // 强制主线程更新
        DispatchQueue.main.async {
            switch theme {
            case .light:
                NSApp.appearance = NSAppearance(named: .aqua)
            case .dark:
                NSApp.appearance = NSAppearance(named: .darkAqua)
            case .system:
                NSApp.appearance = nil
            }
        }
    }
}

// (以下代码保持不变：VisualEffectBackground)
struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.autoresizingMask = [.width, .height]
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

struct TrafficLightManager: ViewModifier {
    var offset: CGPoint
    func body(content: Content) -> some View {
        content.background(TrafficLightEnforcerRepresentable(offset: offset))
    }
}

struct TrafficLightEnforcerRepresentable: NSViewRepresentable {
    var offset: CGPoint
    func makeNSView(context: Context) -> TrafficLightEnforcerView {
        let view = TrafficLightEnforcerView()
        view.customOffset = offset
        return view
    }
    func updateNSView(_ nsView: TrafficLightEnforcerView, context: Context) {
        nsView.customOffset = offset
        nsView.repositionTrafficLights()
    }
}

class TrafficLightEnforcerView: NSView {
    var customOffset: CGPoint = .zero
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        setupWindow()
    }
    
    private func setupWindow() {
        guard let window = self.window else { return }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        repositionTrafficLights()
    }
    
    override func layout() {
        super.layout()
        repositionTrafficLights()
    }
    
    func repositionTrafficLights() {
        guard let window = self.window,
              let superview = window.standardWindowButton(.closeButton)?.superview else { return }
        
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        var currentX = customOffset.x
        
        for type in buttons {
            guard let button = window.standardWindowButton(type) else { continue }
            var frame = button.frame
            // y 轴位置：从 superview 顶部向下偏移 customOffset.y
            frame.origin.y = superview.frame.height - customOffset.y - (frame.height / 2)
            frame.origin.x = currentX
            button.setFrameOrigin(frame.origin)
            currentX += button.frame.width + 8
        }
    }
}

// 🔥 Helper for macOS 14+ Settings Action
@available(macOS 14.0, *)
struct SettingsLinkBridge: View {
    @Environment(\.openSettings) private var openSettings
    @EnvironmentObject var appState: AppState

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                appState.openSettingsAction = {
                    Task {
                        openSettings()
                    }
                }
            }
    }
}
