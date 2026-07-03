//
//  Lark2PadFunctionView.swift
//  LiquidConvert
//
//  Main SwiftUI view for Lark2Pad integration in LiquidConvert.
//  Adapted for Liquid Glass design language.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct Lark2PadFunctionView: View {
    @StateObject private var coordinator = ConversionCoordinator()
    @State private var showExporter = false
    @State private var toastMessage: String?
    @State private var toastIsError = false
    @State private var showLoginSheet = false
    @State private var isSyncingToPad = false
    @AppStorage("lark2pad_auto_upload") private var autoUploadImages = true
    @Environment(\.colorScheme) private var colorScheme
    
    // Animation Namespace
    @Namespace private var animation

    @State private var isDraggingOver = false
    @State private var showImporterSheet = false
    @State private var isHoveringBrowse = false

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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .contentShape(Rectangle())
        .task {
            await coordinator.prepareEngine()
        }
        .sheet(isPresented: $showLoginSheet, onDismiss: {
            coordinator.checkLoginStatus()
        }) {
            Lark2PadLoginView(coordinator: coordinator)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("Lark2PadLoginSuccess"))) { _ in
            showLoginSheet = false
        }
        .alert(
            "检测到超限图片",
            isPresented: Binding(
                get: { coordinator.oversizedImagePrompt != nil },
                set: { isPresented in
                    if !isPresented {
                        coordinator.dismissOversizedImagePrompt()
                    }
                }
            ),
            presenting: coordinator.oversizedImagePrompt
        ) { _ in
            Button("自动压缩并继续") {
                Task {
                    await coordinator.retryPendingConversionWithCompression()
                }
            }
            Button("取消", role: .cancel) {
                coordinator.dismissOversizedImagePrompt()
            }
        } message: { prompt in
            Text(prompt.message)
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

        .fileImporter(
            isPresented: $showImporterSheet,
            allowedContentTypes: [UTType(filenameExtension: "md") ?? .plainText, UTType(filenameExtension: "markdown") ?? .plainText],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                handleImportedURLs(urls)
            case .failure(let error):
                showToast("导入失败: \(error.localizedDescription)", isError: true)
            }
        }
        .background(
            Button(action: handlePaste) {
                EmptyView()
            }
            .keyboardShortcut("v", modifiers: .command)
            .buttonStyle(.plain)
            .allowsHitTesting(false)
            .frame(width: 0, height: 0)
        )
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
        VStack(spacing: 20) {
            VStack(spacing: 20) {
                Spacer()
                
                ZStack {
                    Circle()
                        .fill(.secondary.opacity(0.05))
                        .frame(width: 100, height: 100)
                    
                    Image(systemName: isDraggingOver ? "arrow.down.doc.fill" : "doc.on.clipboard")
                        .font(.system(size: 48, weight: .ultraLight))
                        .foregroundStyle(isDraggingOver ? .blue : .secondary)
                        .scaleEffect(isDraggingOver ? 1.15 : 1.0)
                        .animation(.spring(response: 0.3), value: isDraggingOver)
                        .symbolEffect(.pulse, options: .repeating)
                }

                VStack(spacing: 8) {
                    Text("点击读取剪贴板 或 拖入 .md 文件")
                        .font(.headline)
                        .foregroundStyle(isDraggingOver ? .blue : .primary)
                    
                    Text("自动解析剪贴板富文本，或处理本地 Markdown 文件及图片")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                HStack(spacing: 12) {
                    HStack(spacing: 0) {
                        Image(systemName: "command")
                        Text("V 快速粘贴")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(.primary.opacity(0.05)))
                    
                    Label("支持拖入 .md 文件", systemImage: "tray.and.arrow.down")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(.primary.opacity(0.05)))
                }
                
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            // 浏览本地文件按钮
            Button(action: { showImporterSheet = true }) {
                HStack(spacing: 8) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 13, weight: .semibold))
                    Text("浏览本地文件")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(isHoveringBrowse ? .white : .secondary)
                .padding(.horizontal, 24)
                .padding(.vertical, 10)
                .background {
                    Capsule()
                        .fill(isHoveringBrowse ? Color.blue : Color.primary.opacity(0.06))
                }
                .scaleEffect(isHoveringBrowse ? 1.03 : 1.0)
                .animation(.easeOut(duration: 0.2), value: isHoveringBrowse)
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                isHoveringBrowse = hovering
            }
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(isDraggingOver ? 0.6 : 0.4))
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(
                            isDraggingOver ? Color.blue : .primary.opacity(0.05),
                            style: StrokeStyle(
                                lineWidth: isDraggingOver ? 2 : 1,
                                dash: isDraggingOver ? [6, 4] : []
                            )
                        )
                }
        }
        .onTapGesture {
            handlePaste()
        }
        .onDrop(of: [.fileURL], isTargeted: $isDraggingOver) { providers in
            handleDrop(providers)
        }
    }

    // MARK: - Processing

    private func processingView(status: String) -> some View {
        VStack(spacing: 16) {
            statusLabel(status)
            loadingSection
        }
        .animation(.easeInOut(duration: 0.3), value: coordinator.phase)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func statusLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14, weight: .regular))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .id(text)
    }

    @ViewBuilder
    private var loadingSection: some View {
        VStack(spacing: 8) {
            switch coordinator.phase {
            case .rendering:
                indeterminateBar
            case .processing where coordinator.uploadProgress > 0:
                determinateBar
            default:
                initialSpinner
            }
        }
        .frame(height: 32, alignment: .top)
    }

    private var indeterminateBar: some View {
        ProgressView()
            .progressViewStyle(.linear)
            .tint(.blue)
            .frame(width: 240)
            .transition(.opacity)
    }

    private var determinateBar: some View {
        VStack(spacing: 8) {
            ProgressView(value: coordinator.uploadProgress)
                .progressViewStyle(.linear)
                .tint(.blue)
                .frame(width: 240)
                .animation(.spring(response: 0.5), value: coordinator.uploadProgress)
            
            HStack {
                Text("\(Int(coordinator.uploadProgress * 100))%")
                Spacer()
                if !coordinator.speedMessage.isEmpty {
                    Text(coordinator.speedMessage)
                }
            }
            .font(.system(size: 10, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(.tertiary)
            .frame(width: 240)
        }
    }

    private var initialSpinner: some View {
        ProgressView()
            .controlSize(.regular)
            .transition(.opacity)
            .padding(.top, 4)
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

            Button(action: copyEtherpad) {
                Label("复制 Etherpad", systemImage: "doc.on.clipboard")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            .controlSize(.large)

            Button(action: { showExporter = true }) {
                Label("保存 HTML", systemImage: "arrow.down.doc")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            Button(action: syncToPad) {
                Label(isSyncingToPad ? "同步中" : "同步到 Pad", systemImage: isSyncingToPad ? "arrow.triangle.2.circlepath" : "icloud.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .controlSize(.large)
            .disabled(isSyncingToPad || coordinator.markdownResult.isEmpty || coordinator.etherpadHTML.isEmpty)

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

    private func copyEtherpad() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(coordinator.etherpadHTML, forType: .html)
        pb.setString(coordinator.etherpadHTML, forType: .string)
        showToast("Etherpad 格式已复制！")
    }

    private func syncToPad() {
        guard coordinator.isLoggedIntoEtherpad else {
            showToast("请先登录公司 Etherpad 账号", isError: true)
            return
        }

        isSyncingToPad = true
        let markdown = coordinator.markdownResult
        let html = coordinator.etherpadHTML

        Task {
            do {
                let result = try await EtherpadSyncService.sync(markdown: markdown, html: html)
                await MainActor.run {
                    isSyncingToPad = false
                    let suffix = result.renamed ? "，已自动重命名为 \(result.padID)" : ""
                    showToast("已同步到 \(result.padID)\(suffix)")
                    NSWorkspace.shared.open(result.url)
                }
            } catch {
                await MainActor.run {
                    isSyncingToPad = false
                    showToast("同步失败: \(error.localizedDescription)", isError: true)
                }
            }
        }
    }

    private func handleImportedURLs(_ urls: [URL]) {
        let mdFiles = urls.filter { url in
            let ext = url.pathExtension.lowercased()
            return ext == "md" || ext == "markdown"
        }
        
        guard let firstMdFile = mdFiles.first else {
            showToast("请拖入 .md 或 .markdown 格式的 Markdown 文件", isError: true)
            return
        }
        
        Task {
            let access = firstMdFile.startAccessingSecurityScopedResource()
            defer {
                if access {
                    firstMdFile.stopAccessingSecurityScopedResource()
                }
            }
            
            do {
                let content = try String(contentsOf: firstMdFile, encoding: .utf8)
                let baseDir = firstMdFile.deletingLastPathComponent()
                
                await coordinator.convertMarkdown(
                    content: content,
                    baseDirectory: baseDir,
                    autoUpload: autoUploadImages
                )
            } catch {
                showToast("读取文件失败: \(error.localizedDescription)", isError: true)
            }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        Task {
            var urls: [URL] = []
            for provider in providers {
                if let url = await provider.loadSafeURL() {
                    urls.append(url)
                }
            }
            await MainActor.run {
                if !urls.isEmpty {
                    handleImportedURLs(urls)
                }
            }
        }
        return true
    }
}
