//
//  Lark2PadFunctionView.swift
//  LiquidConvert
//
//  Main SwiftUI view for Lark2Pad integration in LiquidConvert.
//  Adapted for Liquid Glass design language.
//

import SwiftUI
import UniformTypeIdentifiers

struct Lark2PadFunctionView: View {
    @StateObject private var coordinator = ConversionCoordinator()
    @State private var showExporter = false
    @State private var toastMessage: String?
    @State private var toastIsError = false
    @State private var showLoginSheet = false
    @AppStorage("lark2pad_auto_upload") private var autoUploadImages = true
    @Environment(\.colorScheme) private var colorScheme
    
    // Animation Namespace
    @Namespace private var animation

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                VStack(spacing: 24) {
                    headerSection
                        .padding(.top, 20)

                    mainContent
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    footerSection
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 24)
            }

            // Toast overlay
            if let msg = toastMessage {
                toastOverlay(message: msg, isError: toastIsError)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(100)
            }
        }
        .task {
            await coordinator.prepareEngine()
        }
        .sheet(isPresented: $showLoginSheet, onDismiss: {
            coordinator.checkLoginStatus()
        }) {
            Lark2PadLoginView(coordinator: coordinator)
        }
        .fileExporter(
            isPresented: $showExporter,
            document: Lark2PadExportDocument(html: coordinator.etherpadHTML),
            contentType: .html,
            defaultFilename: EtherpadExporter.defaultFilename()
        ) { result in
            switch result {
            case .success:
                showToast("Etherpad 格式 HTML 已保存！")
            case .failure(let error):
                showToast("保存失败: \(error.localizedDescription)", isError: true)
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.1))
                    .frame(width: 80, height: 80)
                    .blur(radius: 10)
                
                Image(systemName: "doc.richtext.fill")
                    .font(.system(size: 44, weight: .thin))
                    .foregroundStyle(LinearGradient(colors: [.blue, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .symbolEffect(.breathe, options: .repeating, isActive: coordinator.phase == .processing)
            }

            VStack(spacing: 6) {
                Text("飞书文档 → Etherpad 转换")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.primary)

                Text("在飞书内全选并复制云文档，然后点击下方按钮读取剪贴板。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                
                Toggle("自动上传图片到私有图床", isOn: $autoUploadImages)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                
                Button(action: { showLoginSheet = true }) {
                    Label(coordinator.isLoggedIntoEtherpad ? "已登录公司账号" : "登录公司账号同步 Session", 
                          systemImage: coordinator.isLoggedIntoEtherpad ? "person.badge.shield.checkmark.fill" : "person.badge.key.fill")
                        .font(.caption)
                        .foregroundStyle(coordinator.isLoggedIntoEtherpad ? .green : .blue)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
    }

    // MARK: - Main Content

    @ViewBuilder
    private var mainContent: some View {
        ZStack {
            // Background pre-rendering
            resultView
                .opacity(coordinator.phase == .done ? 1 : 0)
                .allowsHitTesting(coordinator.phase == .done)
            
            // Overlays (Loading, Idle, Error)
            switch coordinator.phase {
            case .idle:
                idleView.transition(.opacity)
            case .processing, .rendering:
                processingView(status: coordinator.statusMessage).transition(.opacity)
            case .error(let message):
                errorView(message: message).transition(.opacity)
            case .done:
                EmptyView()
            }
        }
        .animation(.spring(response: 0.3), value: coordinator.phase)
    }

    // MARK: - Idle (Paste Zone)

    private var idleView: some View {
        Button {
            handlePaste()
        } label: {
            VStack(spacing: 20) {
                ZStack {
                    Circle()
                        .fill(.secondary.opacity(0.05))
                        .frame(width: 100, height: 100)
                    
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 48, weight: .ultraLight))
                        .foregroundStyle(.secondary)
                        .symbolEffect(.pulse, options: .repeating)
                }

                VStack(spacing: 8) {
                    Text("点击读取剪贴板")
                        .font(.headline)
                    
                    Text("自动解析剪贴板中的飞书富文本内容及图片")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                HStack(spacing: 0) {
                    Image(systemName: "command")
                    Text("V 快速粘贴")
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(.primary.opacity(0.05)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.4))
                    .overlay {
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .strokeBorder(.primary.opacity(0.05), lineWidth: 1)
                    }
            }
        }
        .buttonStyle(PlainButtonStyle())
        .keyboardShortcut("v", modifiers: .command)
    }

    // MARK: - Processing

    private func processingView(status: String) -> some View {
        VStack(spacing: 24) {
            ProgressView()
                .controlSize(.large)

            Text(status)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .id(status)
                .transition(.identity)
        }
        .animation(.none, value: status)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Result

    private var resultView: some View {
        VStack(spacing: 16) {
            HStack {
                Label("转换完成", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
                Spacer()
                Text("图片使用外部 URL 引用")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            VStack(spacing: 0) {
                HTMLPreviewView(html: coordinator.previewHTML) {
                    coordinator.markDone()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.3))
                
                Divider()
                
                actionButtons
                    .padding(16)
                    .background(.ultraThinMaterial.opacity(0.5))
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.primary.opacity(0.1), lineWidth: 0.5)
            }
        }
    }
    private var actionButtons: some View {
        HStack(spacing: 16) {
            Button(action: copyMarkdown) {
                Label("复制 Markdown", systemImage: "doc.on.doc")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            Button(action: { showExporter = true }) {
                Label("保存 Etherpad HTML", systemImage: "arrow.down.doc.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            .controlSize(.large)

            Button(action: { coordinator.reset() }) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.headline)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }

    // MARK: - Error

    private func errorView(message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)

            Text(message)
                .font(.headline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("重新尝试") {
                coordinator.reset()
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            Image(systemName: "lock.shield")
                .font(.caption)
            Text("安全说明：转换过程全本地进行，图片下载不经过代理，直接通过原生 URLSession 完成。")
                .font(.caption2)
        }
        .foregroundStyle(.quaternary)
    }

    // MARK: - Toast Helpers

    private func toastOverlay(message: String, isError: Bool) -> some View {
        VStack {
            HStack(spacing: 10) {
                Image(systemName: isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(.white)
                Text(message)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(
                isError ? Color.red.opacity(0.9) : Color.blue.opacity(0.9),
                in: Capsule()
            )
            .shadow(color: .black.opacity(0.2), radius: 10, y: 5)
            .padding(.top, 20)
            Spacer()
        }
    }

    private func showToast(_ msg: String, isError: Bool = false) {
        withAnimation(.spring(response: 0.3)) {
            toastMessage = msg
            toastIsError = isError
        }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation {
                toastMessage = nil
            }
        }
    }

    private func handlePaste() {
        let content = Lark2PadClipboardHelper.read()

        guard let html = content.html, !html.isEmpty else {
            if let text = content.plainText, !text.isEmpty {
                coordinator.markdownResult = text
                coordinator.previewHTML = EtherpadExporter.buildRenderedHTML(from: text)
                coordinator.etherpadHTML = EtherpadExporter.buildRawHTML(from: text)
                coordinator.phase = .rendering
                return
            }
            showToast("剪贴板中未找到飞书文档内容，请确认已全选并复制。", isError: true)
            return
        }

        Task {
            await coordinator.convert(html: html, autoUpload: autoUploadImages)
        }
    }

    private func copyMarkdown() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(coordinator.markdownResult, forType: .string)
        showToast("Markdown 内容已复制！")
    }
}
