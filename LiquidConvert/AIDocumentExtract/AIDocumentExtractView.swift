import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct AIDocumentExtractItem: Identifiable, Hashable {
    let id = UUID()
    let source: AIDocumentSource
    let createdAt = Date()

    var title: String {
        source.displayName
    }

    var subtitle: String {
        source.detailText
    }
}

private enum AIDocumentFileTypes {
    static let doc = UTType(filenameExtension: "doc") ?? .data
    static let docx = UTType(filenameExtension: "docx") ?? .data
    static let ppt = UTType(filenameExtension: "ppt") ?? .data
    static let pptx = UTType(filenameExtension: "pptx") ?? .data
    static let xls = UTType(filenameExtension: "xls") ?? .data
    static let xlsx = UTType(filenameExtension: "xlsx") ?? .data

    static let importable: [UTType] = [
        .data, .pdf, .plainText, .html, .image,
        doc, docx, ppt, pptx, xls, xlsx,
    ]
}

@MainActor
final class AIDocumentExtractViewModel: ObservableObject {
    @Published var items: [AIDocumentExtractItem] = []
    @Published var selectedItemID: UUID?
    @Published var markdownResults: [UUID: String] = [:]
    @Published var suggestedTitles: [UUID: String] = [:]
    @Published var itemStatuses: [UUID: String] = [:]
    @Published var itemErrors: [UUID: String] = [:]
    @Published var runtimeStatus = "尚未准备运行环境"
    @Published var draftLink = ""
    @Published var isImporting = false
    @Published var isPreparingRuntime = false
    @Published var isExtracting = false
    @Published var globalMessage = "支持 PDF、Word、Excel、PPT、HTML、文本、图片与网页链接，图片会直接 OCR。"
    @Published var historyRecords: [AIDocumentHistoryRecord] = []

    private let runtime = ManagedMarkItDownRuntime.shared
    private let historyManager = AIDocumentExtractHistoryManager.shared

    var selectedItem: AIDocumentExtractItem? {
        guard let selectedItemID else { return nil }
        return items.first(where: { $0.id == selectedItemID })
    }

    var selectedMarkdown: String {
        guard let selectedItem else { return "" }
        return markdownResults[selectedItem.id] ?? ""
    }

    var selectedStatus: String {
        guard let selectedItem else { return "等待中" }
        return itemStatuses[selectedItem.id] ?? "等待中"
    }

    var selectedPreviewHTML: String {
        guard !selectedMarkdown.isEmpty else { return "" }
        return EtherpadExporter.buildRenderedHTML(from: selectedMarkdown)
    }

    var selectedError: String? {
        guard let selectedItem else { return nil }
        return itemErrors[selectedItem.id]
    }

    var canExtractSelection: Bool {
        selectedItem != nil && !isExtracting
    }

    var canExportSelection: Bool {
        selectedItem != nil && !selectedMarkdown.isEmpty
    }

    func prepareRuntimeIfNeeded() {
        guard !isPreparingRuntime else { return }
        isPreparingRuntime = true
        runtimeStatus = "正在准备 AI 文档提取运行环境…"

        Task {
            defer { isPreparingRuntime = false }
            do {
                _ = try await runtime.prepare()
                runtimeStatus = "运行环境已就绪"
            } catch {
                runtimeStatus = "环境准备失败"
                globalMessage = error.localizedDescription
            }
        }
    }

    func loadHistory() {
        Task {
            let records = await historyManager.loadHistory()
            await MainActor.run {
                self.historyRecords = records
            }
        }
    }

    func clearHistory() {
        Task {
            await historyManager.clearHistory()
            await MainActor.run {
                self.historyRecords = []
            }
        }
    }

    private func saveToHistory(item: AIDocumentExtractItem, markdown: String) {
        let title = suggestedTitles[item.id]
            ?? markdownTitle(from: markdown)
            ?? item.title
        let record = AIDocumentHistoryRecord(
            id: UUID(),
            title: title,
            sourceDisplayName: item.source.displayName,
            sourceDetailText: item.source.detailText,
            markdown: markdown,
            date: Date()
        )
        Task {
            await historyManager.saveRecord(record)
            await MainActor.run {
                self.historyRecords.insert(record, at: 0)
            }
        }
    }

    @discardableResult
    func addFiles(_ urls: [URL]) -> [AIDocumentExtractItem] {
        let newItems = urls.map { AIDocumentExtractItem(source: .file($0)) }
        return append(items: newItems)
    }

    func addDraftLink() {
        _ = enqueueLink(draftLink)
    }

    func addDraftLinkAndExtract() {
        guard !isExtracting else {
            globalMessage = "当前正在提取，请等待本次任务完成。"
            return
        }
        guard let item = enqueueLink(draftLink) else { return }
        extract(items: [item])
    }

    func addClipboardLink() {
        guard !isExtracting else {
            globalMessage = "当前正在提取，请等待本次任务完成。"
            return
        }
        let pasteboard = NSPasteboard.general
        let raw = pasteboard.string(forType: .string) ?? ""
        _ = enqueueLink(raw, invalidMessage: "剪贴板里没有可识别的网页链接。")
    }

    func addClipboardLinkAndExtract() {
        guard !isExtracting else {
            globalMessage = "当前正在提取，请等待本次任务完成。"
            return
        }
        let pasteboard = NSPasteboard.general
        let raw = pasteboard.string(forType: .string) ?? ""
        guard let item = enqueueLink(raw, invalidMessage: "剪贴板里没有可识别的网页链接。") else { return }
        extract(items: [item])
    }

    func openSelectedOriginal() {
        guard let selectedItem else { return }
        switch selectedItem.source {
        case .file(let url):
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case .link(let url):
            NSWorkspace.shared.open(url)
        }
    }

    func removeItems(at offsets: IndexSet) {
        let removedIDs = offsets.map { items[$0].id }
        items.remove(atOffsets: offsets)
        removedIDs.forEach {
            markdownResults.removeValue(forKey: $0)
            suggestedTitles.removeValue(forKey: $0)
            itemStatuses.removeValue(forKey: $0)
            itemErrors.removeValue(forKey: $0)
        }

        if let selectedItemID, !items.contains(where: { $0.id == selectedItemID }) {
            self.selectedItemID = items.first?.id
        }
    }

    func clearAll() {
        items.removeAll()
        markdownResults.removeAll()
        suggestedTitles.removeAll()
        itemStatuses.removeAll()
        itemErrors.removeAll()
        selectedItemID = nil
    }

    func extractSelected() {
        guard let selectedItem else { return }
        extract(items: [selectedItem])
    }

    func extractAll() {
        extract(items: items)
    }

    func copySelectedMarkdown() {
        guard !selectedMarkdown.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(selectedMarkdown, forType: .string)
        globalMessage = "Markdown 已复制到剪贴板。"
    }

    func exportSelectedMarkdown() {
        guard let selectedItem, !selectedMarkdown.isEmpty else { return }

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = suggestedMarkdownFilename(for: selectedItem)
        panel.title = "导出 Markdown"
        panel.prompt = "导出"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try selectedMarkdown.write(to: url, atomically: true, encoding: .utf8)
            globalMessage = "Markdown 已导出到 \(url.lastPathComponent)。"
        } catch {
            globalMessage = "导出失败：\(error.localizedDescription)"
        }
    }

    private func enqueueLink(_ rawValue: String, invalidMessage: String = "请输入有效的 http/https 链接。") -> AIDocumentExtractItem? {
        guard let normalized = normalizeLink(rawValue) else {
            globalMessage = invalidMessage
            return nil
        }

        draftLink = normalized.absoluteString
        return append(items: [AIDocumentExtractItem(source: .link(normalized))]).first
    }

    @discardableResult
    private func append(items newItems: [AIDocumentExtractItem]) -> [AIDocumentExtractItem] {
        guard !newItems.isEmpty else { return [] }

        let existingSignatures = Set(items.map(\.subtitle))
        let filtered = newItems.filter { !existingSignatures.contains($0.subtitle) }
        guard !filtered.isEmpty else {
            globalMessage = "这些项目已经在队列中了。"
            return []
        }

        items.append(contentsOf: filtered)
        filtered.forEach { itemStatuses[$0.id] = "等待提取" }
        selectedItemID = filtered.last?.id
        globalMessage = "已加入 \(filtered.count) 个待提取项目。"
        return filtered
    }

    private func normalizeLink(_ rawValue: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let candidate: String
        if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") {
            candidate = trimmed
        } else if trimmed.lowercased().hasPrefix("www.") {
            candidate = "https://\(trimmed)"
        } else {
            return nil
        }

        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else {
            return nil
        }

        return url
    }

    func extract(items extractionItems: [AIDocumentExtractItem]) {
        guard !extractionItems.isEmpty else { return }
        guard !isExtracting else { return }

        isExtracting = true
        globalMessage = "正在提取 Markdown，请稍候…"

        Task {
            defer { isExtracting = false }

            for item in extractionItems {
                selectedItemID = item.id
                itemStatuses[item.id] = "准备运行环境…"
                runtimeStatus = "正在准备 AI 文档提取运行环境…"

                do {
                    itemStatuses[item.id] = "正在提取内容…"
                    runtimeStatus = "正在调用 MarkItDown 提取内容…"
                    let progressSink = AIDocumentExtractionProgressSink(viewModel: self, itemID: item.id)
                    let result = try await runtime.extract(source: item.source) { message in
                        progressSink.update(message)
                    }

                    markdownResults[item.id] = result.markdown
                    suggestedTitles[item.id] = result.suggestedTitle
                    itemErrors[item.id] = nil
                    itemStatuses[item.id] = "提取完成"
                    runtimeStatus = "运行环境已就绪"
                    globalMessage = "已完成 \(item.title) 的 Markdown 提取。"
                    saveToHistory(item: item, markdown: result.markdown)
                } catch {
                    itemStatuses[item.id] = "提取失败"
                    let message = error.localizedDescription
                    itemErrors[item.id] = message
                    globalMessage = message
                }
            }
        }
    }

    private func suggestedMarkdownFilename(for item: AIDocumentExtractItem) -> String {
        let rawName: String
        switch item.source {
        case .file(let url):
            rawName = url.deletingPathExtension().lastPathComponent
        case .link(let url):
            rawName = suggestedTitles[item.id]
                ?? markdownTitle(from: markdownResults[item.id] ?? "")
                ?? url.host
                ?? "WebPage"
        }

        let cleaned = rawName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>\n\r\t"))
            .joined(separator: "_")

        return cleaned.isEmpty ? "Extracted.md" : "\(cleaned).md"
    }

    private func markdownTitle(from markdown: String) -> String? {
        markdown
            .components(separatedBy: .newlines)
            .first { $0.hasPrefix("# ") }
            .map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }
}

private final class AIDocumentExtractionProgressSink: @unchecked Sendable {
    nonisolated(unsafe) private weak var viewModel: AIDocumentExtractViewModel?
    nonisolated private let itemID: UUID

    @MainActor
    init(viewModel: AIDocumentExtractViewModel, itemID: UUID) {
        self.viewModel = viewModel
        self.itemID = itemID
    }

    nonisolated func update(_ message: String) {
        Task { @MainActor [weak viewModel, itemID] in
            viewModel?.itemStatuses[itemID] = message
            viewModel?.runtimeStatus = message
        }
    }
}

struct AIDocumentExtractView: View {
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var viewModel = AIDocumentExtractViewModel()
    @State private var isDropTargeted = false
    @State private var showQuickAddSheet = false
    @State private var showResultSheet = false
    @State private var showHistoryPopover = false
    @State private var selectedHistoryRecord: AIDocumentHistoryRecord?

    var body: some View {
        GeometryReader { geometry in
            let horizontalPadding: CGFloat = geometry.size.width < 900 ? 20 : 32
            let topPadding: CGFloat = 0
            let bottomPadding: CGFloat = 8
            let verticalSpacing: CGFloat = 10
            let cardHeight = max(300, geometry.size.height - 240)

            VStack(spacing: verticalSpacing) {
                headerSection
                    .padding(.top, topPadding)

                conversionCard(height: cardHeight)
                    .frame(maxHeight: .infinity)

                footerHint
            }
            .frame(
                width: geometry.size.width - (horizontalPadding * 2),
                height: geometry.size.height - bottomPadding,
                alignment: .top
            )
            .padding(.horizontal, horizontalPadding)
            .padding(.bottom, bottomPadding)
            .background(pageBackgroundColor)
        }
        .fileImporter(
            isPresented: $viewModel.isImporting,
            allowedContentTypes: AIDocumentFileTypes.importable,
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result else { return }
            let newItems = viewModel.addFiles(urls)
            guard !newItems.isEmpty else { return }
            viewModel.extract(items: newItems)
        }
        .sheet(isPresented: $showQuickAddSheet) {
            quickAddSheet
        }
        .sheet(isPresented: $showResultSheet) {
            resultSheet
        }
        .onChange(of: viewModel.selectedStatus) { _, newValue in
            guard newValue == "提取完成" || newValue == "提取失败" else { return }
            showResultSheet = true
        }
        .sheet(item: $selectedHistoryRecord) { record in
            historyDetailSheet(record: record)
        }
        .task {
            viewModel.prepareRuntimeIfNeeded()
            viewModel.loadHistory()
        }
    }

    private var headerSection: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.12))
                        .frame(width: 80, height: 80)
                        .blur(radius: 10)

                    Image(systemName: "doc.viewfinder.fill")
                        .font(.system(size: 44, weight: .thin))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.blue, .cyan],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .symbolEffect(.breathe, options: .repeating, isActive: viewModel.isExtracting)
                }

                VStack(spacing: 6) {
                    Text("AI 文档提取")
                        .font(.title2.weight(.bold))

                    Text("点击读取 clipboard，或直接拖入支持的文件格式开始提取。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    runtimeStatusPill

                    Text(viewModel.globalMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity)

            Button {
                viewModel.loadHistory()
                showHistoryPopover.toggle()
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(.primary.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showHistoryPopover) {
                historySheetContent
            }
        }
    }

    private func conversionCard(height: CGFloat) -> some View {
        VStack(spacing: 20) {
            Spacer()

            ZStack {
                Circle()
                    .fill(.secondary.opacity(0.05))
                    .frame(width: 100, height: 100)

                Image(systemName: currentHeroIcon)
                    .font(.system(size: 48, weight: .ultraLight))
                    .foregroundStyle(currentHeroTint)
                    .symbolEffect(.pulse, options: .repeating, isActive: viewModel.isExtracting)
            }

            VStack(spacing: 8) {
                Text(primaryActionTitle)
                    .font(.headline)

                Text(primaryActionSubtitle)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 10) {
                shortcutBadge

                if !viewModel.isExtracting {
                    Label("支持拖入 PDF / Office / HTML / 文本", systemImage: "tray.and.arrow.down")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(.primary.opacity(0.05)))
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .contentShape(Rectangle())
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(panelBackgroundColor)
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(isDropTargeted ? Color.accentColor.opacity(0.45) : cardBorderColor, style: StrokeStyle(lineWidth: isDropTargeted ? 2 : 1, dash: isDropTargeted ? [10, 8] : []))
                }
        }
        .shadow(color: cardShadowColor, radius: 18, x: 0, y: 8)
        .allowsHitTesting(!viewModel.isExtracting)
        .onTapGesture {
            guard !viewModel.isExtracting else { return }
            viewModel.addClipboardLinkAndExtract()
        }
        .onDrop(of: AIDocumentFileTypes.importable + [.fileURL], isTargeted: $isDropTargeted, perform: handleDrop)
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
                guard !urls.isEmpty else {
                    viewModel.globalMessage = "未能读取拖入文件，请确认拖入的是本地 PDF / Office / HTML / 文本 / 图片文件。"
                    return
                }
                let newItems = viewModel.addFiles(urls)
                guard !newItems.isEmpty else { return }
                viewModel.extract(items: newItems)
            }
        }
        return true
    }

    private var quickAddSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("手动添加")
                        .font(.title3.weight(.bold))
                    Text("粘贴网页链接后直接开始提取，或选择本地文件立即转换。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("网页链接")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextField("粘贴 http/https 链接", text: $viewModel.draftLink)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(spacing: 10) {
                Button("开始提取") {
                    viewModel.addDraftLinkAndExtract()
                    showQuickAddSheet = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isExtracting)

                Button("选择文件") {
                    showQuickAddSheet = false
                    viewModel.isImporting = true
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isExtracting)

                Spacer()
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private var runtimeStatusPill: some View {
        Label(
            viewModel.runtimeStatus,
            systemImage: viewModel.isPreparingRuntime ? "gearshape.2.fill" : "checkmark.seal.fill"
        )
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(viewModel.isPreparingRuntime ? .blue : .secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
    }

    private var resultSheet: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(viewModel.selectedItem?.title ?? "提取结果")
                        .font(.title3.weight(.bold))

                    Text(viewModel.selectedStatus)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(viewModel.selectedStatus.contains("失败") ? .red : .secondary)

                    if let selectedItem = viewModel.selectedItem {
                        Text(selectedItem.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                Spacer()

                Button("完成") {
                    showResultSheet = false
                }
                .buttonStyle(.bordered)
            }
            .padding(24)

            Divider()

            Group {
                if !viewModel.selectedMarkdown.isEmpty {
                    HTMLPreviewView(html: viewModel.selectedPreviewHTML)
                        .background(Color(nsColor: .textBackgroundColor))
                } else if let selectedError = viewModel.selectedError {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 28))
                            .foregroundStyle(.orange)
                        Text("提取失败")
                            .font(.headline)
                        Text(selectedError)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 460)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(24)
                    .background(panelBackgroundColor)
                } else {
                    ProgressView("正在准备结果…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(24)
                }
            }
            .frame(minHeight: 420)

            Divider()

            HStack(spacing: 10) {
                Button("复制 Markdown") {
                    viewModel.copySelectedMarkdown()
                    showResultSheet = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canExportSelection)

                Button("导出 .md") {
                    viewModel.exportSelectedMarkdown()
                }
                .buttonStyle(.bordered)
                .disabled(!viewModel.canExportSelection)

                Button("打开原始链接 / 文件") {
                    viewModel.openSelectedOriginal()
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.selectedItem == nil)

                Spacer()
            }
            .padding(20)
        }
        .frame(width: 760, height: 620)
    }

    private var shortcutBadge: some View {
        Button(action: {
            guard !viewModel.isExtracting else { return }
            viewModel.addClipboardLinkAndExtract()
        }) {
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
        .buttonStyle(.plain)
        .keyboardShortcut("v", modifiers: .command)
    }

    private var currentHeroIcon: String {
        if viewModel.isExtracting {
            return "hourglass"
        }
        if viewModel.selectedStatus.contains("失败") {
            return "exclamationmark.triangle"
        }
        return "doc.on.clipboard"
    }

    private var currentHeroTint: some ShapeStyle {
        if viewModel.selectedStatus.contains("失败") {
            return Color.orange
        }
        return Color.secondary
    }

    private var primaryActionTitle: String {
        if viewModel.isExtracting {
            return "正在提取内容"
        }
        return "点击读取剪贴板"
    }

    private var primaryActionSubtitle: String {
        if viewModel.isExtracting {
            return "正在解析并提取内容，此过程在本地运行…"
        }
        return "自动解析剪贴板中的网页链接，拖入文件也会直接开始转换。"
    }

    private var footerHint: some View {
        HStack(spacing: 6) {
            Image(systemName: "shield")
            Text("提取过程在本地完成，结果会在二级结果窗口中查看。")
        }
        .font(.system(size: 11))
        .foregroundStyle(.tertiary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var pageBackgroundColor: Color {
        Color(nsColor: .windowBackgroundColor)
    }

    private var panelBackgroundColor: Color {
        colorScheme == .dark
        ? Color(nsColor: .controlBackgroundColor).opacity(0.72)
        : Color(nsColor: .textBackgroundColor)
    }

    private var cardBorderColor: Color {
        Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.06)
    }

    private var cardShadowColor: Color {
        Color.black.opacity(colorScheme == .dark ? 0.32 : 0.08)
    }

    // MARK: - History

    private var historySheetContent: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("提取历史")
                        .font(.title3.weight(.bold))
                    Text("成功提取的结果会自动保存 24 小时")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !viewModel.historyRecords.isEmpty {
                    Button("清空全部") {
                        viewModel.clearHistory()
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .buttonStyle(.plain)
                }
                Button("完成") {
                    showHistoryPopover = false
                }
                .buttonStyle(.bordered)
            }
            .padding(24)

            Divider()

            if viewModel.historyRecords.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "tray")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text("暂无提取记录")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("提取完成后，结果会自动保存在这里")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(viewModel.historyRecords) { record in
                            historyRow(record: record)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(width: 620, height: 480)
    }

    private func historyRow(record: AIDocumentHistoryRecord) -> some View {
        Button {
            showHistoryPopover = false
            selectedHistoryRecord = record
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "doc.text")
                    .font(.system(size: 14))
                    .foregroundStyle(.blue)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(record.title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    Text(record.sourceDisplayName)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Text(record.date, style: .relative)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func historyDetailSheet(record: AIDocumentHistoryRecord) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(record.title)
                        .font(.title3.weight(.bold))

                    Text(record.sourceDisplayName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)

                    Text(record.date, format: .dateTime.year().month().day().hour().minute())
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                Button("完成") {
                    selectedHistoryRecord = nil
                }
                .buttonStyle(.bordered)
            }
            .padding(24)

            Divider()

            HTMLPreviewView(html: EtherpadExporter.buildRenderedHTML(from: record.markdown))
                .background(Color(nsColor: .textBackgroundColor))
                .frame(minHeight: 420)

            Divider()

            HStack(spacing: 10) {
                Button("复制 Markdown") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(record.markdown, forType: .string)
                    selectedHistoryRecord = nil
                }
                .buttonStyle(.borderedProminent)

                Button("导出 .md") {
                    let panel = NSSavePanel()
                    panel.canCreateDirectories = true
                    panel.allowedContentTypes = [.plainText]
                    let safeName = record.title
                        .components(separatedBy: CharacterSet(charactersIn: "/:*?\"<>|\\\n\r\t"))
                        .joined(separator: "_")
                    panel.nameFieldStringValue = (safeName.isEmpty ? "Extracted" : safeName) + ".md"
                    panel.title = "导出 Markdown"
                    panel.prompt = "导出"
                    guard panel.runModal() == .OK, let url = panel.url else { return }
                    try? record.markdown.write(to: url, atomically: true, encoding: .utf8)
                }
                .buttonStyle(.bordered)

                Spacer()
            }
            .padding(20)
        }
        .frame(width: 760, height: 620)
    }
}

private struct AIDocumentQueueRow: View {
    @Environment(\.colorScheme) private var colorScheme

    let item: AIDocumentExtractItem
    let status: String
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: iconName)
                    .font(.system(size: 16))
                    .foregroundStyle(.blue)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(item.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()
            }

            HStack {
                Text(status)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(statusColor.opacity(0.12))
                    .clipShape(Capsule())
                Spacer()
            }
        }
        .padding(14)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(rowBackgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(rowBorderColor, lineWidth: 1)
        )
        .shadow(color: rowShadowColor, radius: isSelected ? 12 : 8, x: 0, y: 4)
    }

    private var iconName: String {
        switch item.source {
        case .file:
            return "doc.text"
        case .link(let url) where (url.host ?? "").contains("mp.weixin.qq.com") || (url.host ?? "").contains("weibo.com") || (url.host ?? "").contains("weibo.cn"):
            return "text.page.badge.magnifyingglass"
        case .link:
            return "globe"
        }
    }

    private var statusColor: Color {
        if status.contains("失败") {
            return .red
        }
        if status.contains("完成") || status.contains("就绪") {
            return .green
        }
        return .orange
    }

    private var rowBackgroundColor: Color {
        if isSelected {
            return Color.accentColor.opacity(colorScheme == .dark ? 0.18 : 0.10)
        }
        return colorScheme == .dark
        ? Color(nsColor: .controlBackgroundColor).opacity(0.66)
        : Color(nsColor: .textBackgroundColor)
    }

    private var rowBorderColor: Color {
        if isSelected {
            return Color.accentColor.opacity(colorScheme == .dark ? 0.36 : 0.22)
        }
        return Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.05)
    }

    private var rowShadowColor: Color {
        Color.black.opacity(colorScheme == .dark ? (isSelected ? 0.28 : 0.18) : (isSelected ? 0.10 : 0.05))
    }
}
