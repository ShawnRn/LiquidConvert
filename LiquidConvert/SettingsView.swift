//
//  SettingsView.swift
//  LiquidConvert
//
//  Created by Shawn Rain.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

// 外观枚举
enum AppAppearance: String, CaseIterable, Identifiable {
    case system = "跟随系统"
    case light = "浅色模式"
    case dark = "深色模式"
    var id: String { self.rawValue }
}

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var updaterController = UpdaterController()
    
    // 状态管理
    @AppStorage("audio_output_format") private var audioFormat = "mp3"
    @AppStorage("video_output_format") private var videoFormat = "mp4"
    @AppStorage("image_default_format") private var imageFormat = "jpg"
    
    @AppStorage("image_delete_original") private var imgDel = false
    @AppStorage("audio_delete_original") private var audDel = false
    @AppStorage("icon_delete_original") private var iconDel = false
    @AppStorage("app_appearance") private var appearance: AppAppearance = .system
    
    @AppStorage("user_name") private var userName = "UserName"
    @AppStorage("user_signature") private var userSignature = "介绍一下你自己..." // 个性签名
    @AppStorage("use_custom_avatar") private var useCustomAvatar = false
    @AppStorage("avatar_timestamp") private var avatarTimestamp: Double = 0
    @State private var avatarRefreshID = UUID()
    @State private var hoverReset = false
    @State private var isAvatarHovered = false // 🔥 头像悬浮状态
    
    // 🔥 焦点管理：解决回车全选问题
    @FocusState private var focusedField: Field?
    enum Field {
        case name
        case signature
    }
    
    let defaultGradient = [Color.blue, Color.purple]
    
    var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "Version \(version) (Build \(build))"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                // Header
                VStack(alignment: .leading, spacing: 4) {
                    Text("设置")
                        .font(.system(size: 28, weight: .bold))
                    Text("个性化您的转换体验与系统偏好")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 40)
                .padding(.horizontal, 40)

                VStack(spacing: 24) {
                    // 1. 用户资料卡片 (Premium Style)
                    VStack(spacing: 20) {
                        HStack(spacing: 20) {
                            // Avatar ZStack
                            ZStack {
                                if useCustomAvatar, let nsImage = getCustomAvatarImage() {
                                    Image(nsImage: nsImage)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 80, height: 80)
                                        .clipShape(Circle())
                                        .id(avatarRefreshID)
                                } else {
                                    Circle()
                                        .fill(LinearGradient(colors: defaultGradient, startPoint: .topLeading, endPoint: .bottomTrailing))
                                        .frame(width: 80, height: 80)
                                }
                                
                                // 🔥 修复：悬浮遮罩 (纯 View + 手势，彻底消除系统 Focus Ring)
                                ZStack {
                                    // 极简液态玻璃：超薄材质 + 低不透明度
                                    Circle()
                                        .fill(.regularMaterial.opacity(0.5))
                                        .opacity(0.3) // 更通透，接近纯净玻璃
                                    
                                    // 增加一点白色高光渐变，模拟玻璃反光
                                    Circle()
                                        .fill(
                                            LinearGradient(
                                                colors: [.white.opacity(0.2), .clear],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            )
                                        )
                                    
                                    Image(systemName: "camera.fill")
                                        .foregroundColor(.white.opacity(0.95))
                                        .font(.system(size: 24, weight: .medium))
                                        .shadow(color: .black.opacity(0.15), radius: 2, x: 0, y: 1)
                                }
                                .frame(width: 80, height: 80)
                                .clipShape(Circle())
                                .contentShape(Circle())
                                .onTapGesture {
                                    selectCustomAvatar()
                                }
                                .opacity(isAvatarHovered ? 1 : 0) // 根据状态显示/隐藏
                                .animation(.easeOut(duration: 0.2), value: isAvatarHovered) // 渐隐渐显
                            }
                            .shadow(color: Color.black.opacity(0.08), radius: 8, x: 0, y: 4)
                            .onHover { isAvatarHovered = $0 } // 🔥 监听悬浮
                            
                            VStack(alignment: .leading, spacing: 8) {
                                TextField("您的昵称", text: $userName)
                                    .font(.system(size: 20, weight: .bold))
                                    .textFieldStyle(.plain)
                                    .focused($focusedField, equals: .name) // 绑定焦点
                                    .onSubmit { focusedField = nil }       // 回车取消焦点
                                
                                TextField("输入个性签名...", text: $userSignature)
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                                    .textFieldStyle(.plain)
                                    .focused($focusedField, equals: .signature) // 绑定焦点
                                    .onSubmit { focusedField = nil }            // 回车取消焦点
                            }
                            
                            Spacer()
                            
                            // Check for Updates Button
                            Button(action: {
                                updaterController.checkForUpdates()
                            }) {
                                VStack(spacing: 4) {
                                    Image(systemName: "arrow.triangle.2.circlepath")
                                        .font(.system(size: 20))
                                        .foregroundColor(.blue.opacity(0.8))
                                    Text("检查更新")
                                        .font(.system(size: 11))
                                        .foregroundColor(.blue.opacity(0.8))
                                }
                                .frame(width: 80, height: 80)
                                .background(Color.blue.opacity(0.05))
                                .cornerRadius(12)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(24)
                    .background {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.primary.opacity(0.03))
                            .overlay {
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(Color.primary.opacity(0.05), lineWidth: 1)
                            }
                    }

                    // 2. 外观设置
                    SettingsGroup(title: "界面外观") {
                        SettingsRow(icon: "paintbrush.fill", title: "应用主题", subtitle: "选择您偏好的视觉模式") {
                            Picker("", selection: $appearance) {
                                ForEach(AppAppearance.allCases) { item in
                                    Text(item.rawValue).tag(item)
                                }
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 220)
                        }
                    }

                    // 3. 转换预设
                    SettingsGroup(title: "转换预设") {
                        SettingsRow(icon: "music.note", title: "音频默认格式", subtitle: "智能识别时的首选输出") {
                            Picker("", selection: $audioFormat) {
                                Text("MP3").tag("mp3")
                                Text("FLAC").tag("flac")
                                Text("WAV").tag("wav")
                                Text("M4A").tag("m4a")
                            }
                            .frame(width: 100)
                        }
                        
                        SettingsRow(icon: "film", title: "视频默认格式", subtitle: "提取音轨或转码的首选") {
                            Picker("", selection: $videoFormat) {
                                Text("MP4").tag("mp4")
                                Text("MOV").tag("mov")
                                Text("MKV").tag("mkv")
                            }
                            .frame(width: 100)
                        }
                        
                        SettingsRow(icon: "photo", title: "图片默认格式", subtitle: "批量转换或压缩的默认导出") {
                            Picker("", selection: $imageFormat) {
                                Text("JPG").tag("jpg")
                                Text("PNG").tag("png")
                                Text("HEIC").tag("heic")
                                Text("WebP").tag("webp")
                            }
                            .frame(width: 100)
                        }
                    }

                    // 4. 全局行为
                    SettingsGroup(title: "全局行为") {
                        SettingsRow(icon: "trash.fill", title: "自动清理源文件", subtitle: "转换成功后自动将源文件移至废纸篓") {
                            HStack(spacing: 12) {
                                Toggle("图片", isOn: $imgDel).toggleStyle(.checkbox)
                                Toggle("音频", isOn: $audDel).toggleStyle(.checkbox)
                                Toggle("图标", isOn: $iconDel).toggleStyle(.checkbox)
                            }
                        }
                    }

                    // 5. 关于与交互
                    VStack(spacing: 32) {
                        VStack(spacing: 4) {
                            Text("LiquidConvert")
                                .font(.system(size: 14, weight: .bold))
                            Text(appVersion)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }

                        // 重置所有设置按钮
                        Button(action: {
                            resetAllSettings()
                        }) {
                            Text("重置所有设置")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.red)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color.red.opacity(0.1))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.red.opacity(0.2), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                        .scaleEffect(hoverReset ? 0.98 : 1.0)
                        .animation(.spring(response: 0.3), value: hoverReset)
                        .onHover { hoverReset = $0 }
                    }
                    .padding(.top, 20)
                }
                .padding(.horizontal, 30)
                .padding(.bottom, 60)
            }
        }
        // 🔥 添加 TapGesture 以在点击空白处时取消焦点
        .onTapGesture {
            focusedField = nil
        }
    }

    // 头像逻辑支持
    private func getAvatarURL() -> URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("custom_avatar.png")
    }
    
    private func getCustomAvatarImage() -> NSImage? {
        guard let url = getAvatarURL(), FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return NSImage(contentsOfFile: url.path)
    }
    
    private func selectCustomAvatar() {
        // 创建 OpenPanel
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "选择一张图片作为头像"
        panel.prompt = "选择"
        
        // 修正逻辑：点击头像时，如果已有头像，弹出 Action Sheet 风格的 Alert
        if useCustomAvatar {
            let alert = NSAlert()
            alert.messageText = "编辑头像"
            alert.informativeText = "您想要更改还是移除当前的自定义头像？"
            alert.addButton(withTitle: "更换头像")
            alert.addButton(withTitle: "移除头像")
            alert.addButton(withTitle: "取消")
            
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                // 更换头像 -> 打开 OpenPanel
                performFileSelection(panel)
            } else if response == .alertSecondButtonReturn {
                // 移除头像
                useCustomAvatar = false
                removeCustomAvatarFile()
            }
            // Cancel -> do nothing
        } else {
            // 没有头像 -> 直接打开 OpenPanel
            performFileSelection(panel)
        }
    }
    
    private func performFileSelection(_ panel: NSOpenPanel) {
        if panel.runModal() == .OK, let url = panel.url {
            if let saveURL = getAvatarURL() {
                try? FileManager.default.removeItem(at: saveURL)
                if let data = try? Data(contentsOf: url) {
                    try? data.write(to: saveURL)
                    useCustomAvatar = true
                    avatarTimestamp = Date().timeIntervalSince1970
                    avatarRefreshID = UUID()
                }
            }
        }
    }
    
    private func removeCustomAvatarFile() {
        if let url = getAvatarURL() { try? FileManager.default.removeItem(at: url) }
        avatarTimestamp = Date().timeIntervalSince1970
    }
    
    private func resetAllSettings() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "audio_output_format")
        defaults.removeObject(forKey: "video_output_format")
        defaults.removeObject(forKey: "image_default_format")
        defaults.removeObject(forKey: "image_delete_original")
        defaults.removeObject(forKey: "audio_delete_original")
        defaults.removeObject(forKey: "icon_delete_original")
        defaults.removeObject(forKey: "app_appearance")
        
        appearance = .system
        NSSound(named: "Glass")?.play()
    }
}

// 布局辅助组件
struct SettingsGroup<Content: View>: View {
    let title: String
    let content: Content
    
    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.secondary.opacity(0.8))
                .padding(.leading, 8)
            
            VStack(spacing: 0) {
                content
            }
            .background {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.primary.opacity(0.03))
                    .overlay {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(Color.primary.opacity(0.05), lineWidth: 1)
                    }
            }
        }
    }
}

struct SettingsRow<Control: View>: View {
    let icon: String
    let title: String
    let subtitle: String
    let control: Control
    
    init(icon: String, title: String, subtitle: String, @ViewBuilder control: () -> Control) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.control = control()
    }
    
    var body: some View {
        HStack {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(.blue)
                .frame(width: 24)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            control
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

struct AboutCircularButton: View {
    let icon: String
    let title: String
    let action: () -> Void
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(Color.primary.opacity(isHovered ? 0.08 : 0.04))
                        .frame(width: 64, height: 64)
                    
                    Image(systemName: icon)
                        .font(.system(size: 24))
                        .foregroundColor(.blue.opacity(0.8))
                }
                
                Text(title)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// 🔥 无点击变色/消失效果的 ButtonStyle
struct StaticButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            // 点击时仅稍微缩小一点点，不改变透明度
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}
