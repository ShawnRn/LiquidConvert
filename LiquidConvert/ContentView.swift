//
//  ContentView.swift
//  LiquidConvert
//
//  Created by Shawn Rain.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    
    // 使用枚举管理选中状态，绑定到 AppState
    // @State private var selectedTab: TabIdentifier? = .home (Removed, use appState)
    
    // 定义侧边栏宽度的默认范围
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    // Restore user data for Avatar
    @AppStorage("use_custom_avatar") private var useCustomAvatar = false
    @AppStorage("avatar_timestamp") private var avatarTimestamp: Double = 0
    // 🔥 Bind UserName
    @AppStorage("user_name") private var userName = "UserName"
    
    // Animation Namespace
    @Namespace private var animation
    
    // 🔥 Custom Binding for Navigation interception
    var navigationBinding: Binding<TabIdentifier?> {
        Binding(
            get: { appState.selectedTab },
            set: { newValue in
                if let tab = newValue {
                    appState.requestTabChange(to: tab)
                }
            }
        )
    }

    var body: some View {
        // 🔥 核心改变：使用原生分栏视图
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // === [1] 侧边栏区域 ===
            VStack(spacing: 0) {
                // 顶部 Logo 区域 (不需要手动算 52px，系统会自动处理 Safe Area)
                LogoHeader()
                    .padding(.top, 60) // 给红绿灯留一点呼吸感
                    .padding(.bottom, 40)
                
                // 导航列表
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 4) {
                        SidebarItem(icon: "house.fill", title: "主页", id: .home, selected: navigationBinding, namespace: animation)
                        

                            
                        SidebarItem(icon: "music.note", title: "音频转换", id: .audio, selected: navigationBinding, namespace: animation)
                        SidebarItem(icon: "photo.on.rectangle", title: "图片压缩", id: .compress, selected: navigationBinding, namespace: animation)
                        SidebarItem(icon: "square.fill.text.grid.1x2", title: "图片拼接", id: .stitch, selected: navigationBinding, namespace: animation)
                        SidebarItem(icon: "film", title: "视频 GIF", id: .videogif, selected: navigationBinding, namespace: animation)
                        SidebarItem(icon: "app.gift", title: "图标转换", id: .icns, selected: navigationBinding, namespace: animation)
                        SidebarItem(icon: "doc.viewfinder.fill", title: "AI 文档提取", id: .aidoc, selected: navigationBinding, namespace: animation)
                        SidebarItem(icon: "doc.richtext.fill", title: "飞书转换", id: .lark2pad, selected: navigationBinding, namespace: animation)
                        SidebarItem(icon: "photo.stack.fill", title: "图库", id: .gallery, selected: navigationBinding, namespace: animation)
                    }
                }
                
                Spacer()
                
                // 底部用户区
                VStack(spacing: 0) {
                    Divider()
                        .opacity(0.4)
                    HStack {
                        AvatarView(useCustom: useCustomAvatar, timestamp: avatarTimestamp)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(userName)
                                .font(.system(size: 13, weight: .medium))
                        }
                        Spacer()
                        Button(action: { appState.requestTabChange(to: .settings) }) {
                            Image(systemName: "gearshape.fill")
                                .foregroundStyle(appState.selectedTab == .settings ? .blue : .secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(16)
                }
            }
            // 🔥 移除手动背景 VisualEffectView，原生侧边栏自带半透明材质
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 300) // 允许拖拽调整宽度
            .ignoresSafeArea(edges: .top) // 让侧边栏背景通顶
            
        } detail: {
            // === [2] 右侧内容区域 ===
            ZStack {
                // 原生背景色
                Color(nsColor: .windowBackgroundColor)
                    .ignoresSafeArea()
                
                // 内容切换逻辑
                if let tab = appState.selectedTab {
                    Group {
                        switch tab {
                        case .home:
                            HomeView(selectedTab: navigationBinding)
                        case .audio:
                            AudioFunctionView()
                        case .compress:
                            ImageCompressionView()
                        case .stitch:
                            ImageStitchingView()
                        case .videogif:
                            VideoGifFunctionView()
                        case .icns:
                            IconFunctionView()
                        case .aidoc:
                            AIDocumentExtractView()
                        case .lark2pad:
                            Lark2PadFunctionView()
                        case .gallery:
                            ImageGalleryView()
                        case .settings:
                            SettingsView()
                        }
                    }
                    .id(tab) // 关键：区分不同 View 实例
                    .transition(.opacity.animation(.easeInOut(duration: 0.2))) // 关键：切换动画
                }
            }
            // 🔥 同样移除所有 padding/clipShape
        }
        // 设置样式为均衡模式 (sidebar + detail)
        .navigationSplitViewStyle(.balanced)
        // 🔥 Unsaved Changes Alert
        .alert("设置未保存", isPresented: $appState.showUnsavedAlert) {
            Button("应用并离开", role: .none) {
                Task {
                    await appState.performSaveAndLeave()
                }
            }
            .keyboardShortcut(.defaultAction)
            
            Button("放弃修改", role: .destructive) {
                appState.confirmDiscardChanges()
            }
            
            Button("取消", role: .cancel) {
                appState.cancelNavigation()
            }
        } message: {
            Text("您在图片拼接页面有未处理的图片。\n离开将导致当前进度丢失。")
        }
    }
}

// MARK: - 辅助枚举与组件
// TabIdentifier moved to LiquidConvertApp.swift

// 2. 改造后的 SidebarItem (适配 Enum & MotrixMac 动画)
struct SidebarItem: View {
    let icon: String
    let title: String
    let id: TabIdentifier
    @Binding var selected: TabIdentifier?
    let namespace: Namespace.ID // 传入 Namespace
    
    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: {
            if selected != id {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    selected = id
                }
            }
        }) {
            // 🔥 MotrixMac 风格：胶囊 + 左对齐
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium)) // 稍微加大一点
                    .frame(width: 20)
                
                Text(title)
                    .font(.system(size: 13, weight: selected == id ? .medium : .regular))
                    .padding(.top, 1) // 视觉微调
            }
            .padding(.leading, 12)
            .foregroundStyle(selected == id ? .white : .primary)
            // 固定宽度或自适应，这里使用尽可能占满但留边距
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
            .contentShape(Rectangle()) // 确保点击区域
            .background {
                ZStack {
                    if isHovered && selected != id {
                        Capsule() // 改为胶囊
                            .fill(.primary.opacity(0.05))
                    }
                    
                    if selected == id {
                        // 胶囊背景 + 阴影
                        Capsule()
                            .fill(Color.accentColor) // 使用系统强调色 (通常是蓝色)
                            .matchedGeometryEffect(id: "activeTab", in: namespace)
                            .shadow(color: Color.black.opacity(0.15), radius: 4, x: 0, y: 2)
                    }
                }
            }
        }
        .buttonStyle(SidebarButtonStyle()) // 按压反馈
        .padding(.horizontal, 16) // 增加水平边距，使其更像药丸悬浮在中间
        .onHover { isHovered = $0 }
    }
}

// 新增按压反馈样式
struct SidebarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.9 : 1.0)
            .animation(.interactiveSpring(duration: 0.1), value: configuration.isPressed)
    }
}

// 3. 改造后的 HomeView
struct HomeView: View {
    @Binding var selectedTab: TabIdentifier?
    @EnvironmentObject var appState: AppState // Receive AppState for method access
    
    // Helper to request change via AppState if available, or fall back to binding (Binding set logic in ContentView handles it if passed)
    // But ContentView passes `$appState.selectedTab` to HomeView in ContentView.swift?
    // Let's check ContentView.
    // Line 91: HomeView(selectedTab: $appState.selectedTab)
    // Wait, the binding passed to HomeView in ContentView is `$appState.selectedTab`.
    // It sets the value directly.
    // I should change ContentView to pass `navigationBinding` to HomeView too?
    // OR HomeView uses `appState.requestTabChange` in buttons.
    // Since HomeView takes `selectedTab` Binding, if I pass `navigationBinding`, `selectedTab = .audio` will trigger the setter in `navigationBinding`.
    // That seems cleanest.
    
    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            
            VStack(spacing: 30) {
                // App Info
                VStack(spacing: 16) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .interpolation(.high)
                        .antialiased(true)
                        .frame(width: 110, height: 110)
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 6)
                        .background {
                            Circle()
                                .fill(Color.blue.opacity(0.12)) // 使用 Blue 作为主色调
                                .frame(width: 140, height: 140)
                                .blur(radius: 20)
                        }
                        
                    VStack(spacing: 6) {
                        Text("LiquidConvert")
                            .font(.system(size: 24, weight: .semibold))
                            
                        Text("选择左侧功能或拖入文件开始处理")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                    }
                }
                
                // Quick Actions
                HStack(spacing: 24) {
                    QuickActionButton(icon: "waveform", label: "音频", action: { selectedTab = .audio })
                    QuickActionButton(icon: "photo", label: "压缩", action: { selectedTab = .compress })
                    QuickActionButton(icon: "square.fill.text.grid.1x2", label: "拼接", action: { selectedTab = .stitch })
                    QuickActionButton(icon: "film", label: "视频", action: { selectedTab = .videogif })
                    QuickActionButton(icon: "app.gift", label: "图标", action: { selectedTab = .icns })
                    QuickActionButton(icon: "doc.richtext.fill", label: "飞书", action: { selectedTab = .lark2pad })
                    QuickActionButton(icon: "photo.stack.fill", label: "图库", action: { selectedTab = .gallery })
                }
            }
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// ... LogoHeader, AvatarView unused by HomeView, keeping them for Sidebar ...

struct QuickActionButton: View {
    let icon: String
    let label: String
    let action: () -> Void
    
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(isHovered ? Color.blue.opacity(0.12) : .secondary.opacity(0.08))
                        .frame(width: 48, height: 48)
                        .overlay {
                            Circle()
                                .stroke(
                                    LinearGradient(
                                        colors: [
                                            isHovered ? .white.opacity(colorScheme == .dark ? 0.4 : 0.8) : .white.opacity(colorScheme == .dark ? 0.3 : 0.6),
                                            .clear,
                                            isHovered ? .white.opacity(colorScheme == .dark ? 0.1 : 0.2) : .white.opacity(colorScheme == .dark ? 0.05 : 0.1)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 1
                                )
                        }
                        .shadow(color: isHovered ? Color.blue.opacity(0.2) : .black.opacity(0.05),
                                radius: isHovered ? 8 : 4, x: 0, y: isHovered ? 4 : 2)
                        .scaleEffect(isHovered ? 1.05 : 1.0)
                    
                    Image(systemName: icon)
                        .font(.system(size: 20))
                        .foregroundStyle(Color.blue)
                        .scaleEffect(isHovered ? 1.1 : 1.0)
                }
                
                Text(label)
                    .font(.caption)
                    .foregroundStyle(isHovered ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
        .frame(width: 80)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                isHovered = hovering
            }
        }
    }
}

struct LogoHeader: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .antialiased(true)
                .aspectRatio(contentMode: .fit)
                .frame(width: 65, height: 65)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            Text("LiquidConvert")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.primary)
                .opacity(0.9)
        }
        .frame(maxWidth: .infinity)
    }
}

struct AvatarView: View {
    let useCustom: Bool
    let timestamp: Double
    
    var body: some View {
        Group {
            if useCustom, let img = load() {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(width: 32, height: 32)
                    .clipShape(Circle())
            } else {
                 Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .foregroundStyle(.white, .blue)
                    .frame(width: 32, height: 32)
            }
        }
        .id(timestamp)
    }
    
    func load() -> NSImage? {
        guard
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
                .appendingPathComponent("custom_avatar.png"),
            FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return NSImage(contentsOfFile: url.path)
    }
}


extension Color { static let tertiaryLabel = Color(nsColor: .tertiaryLabelColor) }
