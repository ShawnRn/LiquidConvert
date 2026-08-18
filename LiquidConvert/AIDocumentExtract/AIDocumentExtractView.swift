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
    @Published var isBatchExtracting = false
    @Published var showResultSheet = false
    @Published var performOCR: Bool {
        didSet { UserDefaults.standard.set(performOCR, forKey: Self.performOCRDefaultsKey) }
    }
    @Published var globalMessage = "支持 PDF、Word、Excel、PPT、HTML、文本、图片与网页链接。"
    @Published var historyRecords: [AIDocumentHistoryRecord] = []

    private let runtime = ManagedMarkItDownRuntime.shared
    private let historyManager = AIDocumentExtractHistoryManager.shared
    private static let performOCRDefaultsKey = "aiDocumentExtraction.performOCR"

    init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.performOCRDefaultsKey) == nil {
            performOCR = true
        } else {
            performOCR = defaults.bool(forKey: Self.performOCRDefaultsKey)
        }
    }

    var selectedItem: AIDocumentExtractItem? {
        guard let selectedItemID else { return items.first }
        return items.first(where: { $0.id == selectedItemID }) ?? items.first
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

    var completedCount: Int {
        items.filter { markdownResults[$0.id]?.isEmpty == false }.count
    }

    var canExtractSelection: Bool {
        selectedItem != nil && !isExtracting
    }

    var canExportSelection: Bool {
        selectedItem != nil && !selectedMarkdown.isEmpty
    }

    var canExportAll: Bool {
        !markdownResults.isEmpty && !isExtracting
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
        _ = enqueueLinks(draftLink, invalidMessage: "请输入有效的 http/https 链接。")
    }

    func addDraftLinkAndExtract() {
        guard !isExtracting else {
            globalMessage = "当前正在提取，请等待本次任务完成。"
            return
        }
        let newItems = enqueueLinks(draftLink, invalidMessage: "请输入有效的 http/https 链接。")
        guard !newItems.isEmpty else { return }
        extract(items: newItems)
    }

    func addClipboardLink() {
        guard !isExtracting else {
            globalMessage = "当前正在提取，请等待本次任务完成。"
            return
        }
        let pasteboard = NSPasteboard.general
        let raw = pasteboard.string(forType: .string) ?? ""
        _ = enqueueLinks(raw, invalidMessage: "剪贴板里没有可识别的网页链接。")
    }

    func addClipboardLinkAndExtract() {
        guard !isExtracting else {
            globalMessage = "当前正在提取，请等待本次任务完成。"
            return
        }
        let pasteboard = NSPasteboard.general
        let raw = pasteboard.string(forType: .string) ?? ""
        let newItems = enqueueLinks(raw, invalidMessage: "剪贴板里没有可识别的网页链接。")
        guard !newItems.isEmpty else { return }
        extract(items: newItems)
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

    func openOriginal(for item: AIDocumentExtractItem) {
        switch item.source {
        case .file(let url):
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case .link(let url):
            NSWorkspace.shared.open(url)
        }
    }

    func remove(item: AIDocumentExtractItem) {
        items.removeAll { $0.id == item.id }
        markdownResults.removeValue(forKey: item.id)
        suggestedTitles.removeValue(forKey: item.id)
        itemStatuses.removeValue(forKey: item.id)
        itemErrors.removeValue(forKey: item.id)
        if selectedItemID == item.id {
            selectedItemID = items.first?.id
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
        let pending = items.filter { markdownResults[$0.id]?.isEmpty != false }
        extract(items: pending.isEmpty ? items : pending)
    }

    func retry(item: AIDocumentExtractItem) {
        extract(items: [item])
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

    func exportAllMarkdown() {
        let completedItems = items.filter { markdownResults[$0.id]?.isEmpty == false }
        guard !completedItems.isEmpty else {
            globalMessage = "当前没有可批量导出的 Markdown。"
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "选择批量导出目录"
        panel.prompt = "导出全部"
        guard panel.runModal() == .OK, let directory = panel.url else { return }

        var usedNames = Set<String>()
        var exportedCount = 0
        var failures: [String] = []

        for item in completedItems {
            guard let markdown = markdownResults[item.id] else { continue }
            do {
                _ = try AIDocumentMarkdownExporter.export(
                    markdown: markdown,
                    source: item.source,
                    suggestedTitle: suggestedTitles[item.id] ?? markdownTitle(from: markdown),
                    to: directory,
                    reserving: &usedNames
                )
                exportedCount += 1
            } catch {
                failures.append("\(item.title)：\(error.localizedDescription)")
            }
        }

        if failures.isEmpty {
            globalMessage = "已将 \(exportedCount) 篇 Markdown 批量导出到 \(directory.lastPathComponent)。"
        } else {
            globalMessage = "已导出 \(exportedCount) 篇，\(failures.count) 篇失败：\(failures.first ?? "未知错误")"
        }
    }

    private func enqueueLinks(_ rawValue: String, invalidMessage: String) -> [AIDocumentExtractItem] {
        let urls = detectedLinks(in: rawValue)
        guard !urls.isEmpty else {
            globalMessage = invalidMessage
            return []
        }
        draftLink = urls.first?.absoluteString ?? ""
        return append(items: urls.map { AIDocumentExtractItem(source: .link($0)) })
    }

    @discardableResult
    private func append(items newItems: [AIDocumentExtractItem]) -> [AIDocumentExtractItem] {
        guard !newItems.isEmpty else { return [] }

        var signatures = Set(items.map(\.subtitle))
        let filtered = newItems.filter { signatures.insert($0.subtitle).inserted }
        guard !filtered.isEmpty else {
            globalMessage = "这些项目已经在队列中了。"
            return []
        }

        items.append(contentsOf: filtered)
        filtered.forEach { itemStatuses[$0.id] = "等待提取" }
        if selectedItemID == nil {
            selectedItemID = filtered.first?.id
        }
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

    private func detectedLinks(in rawValue: String) -> [URL] {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let fullRange = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let detected = detector?.matches(in: trimmed, range: fullRange).compactMap { match -> URL? in
            guard let url = match.url,
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https"
            else { return nil }
            return url
        } ?? []

        if !detected.isEmpty {
            var seen = Set<String>()
            return detected.filter { seen.insert($0.absoluteString).inserted }
        }

        // Fallback: split by lines/whitespace and try to normalize each
        let candidates = trimmed.components(separatedBy: CharacterSet.whitespacesAndNewlines)
        var urls: [URL] = []
        var seen = Set<String>()
        for candidate in candidates {
            if let url = normalizeLink(candidate), seen.insert(url.absoluteString).inserted {
                urls.append(url)
            }
        }
        return urls
    }

    func extract(items extractionItems: [AIDocumentExtractItem]) {
        guard !extractionItems.isEmpty else { return }
        guard !isExtracting else { return }

        isExtracting = true
        isBatchExtracting = extractionItems.count > 1
        globalMessage = "正在提取 Markdown，请稍候…"
        let extractionOptions = AIDocumentExtractionOptions(performOCR: performOCR)

        Task {
            defer {
                isExtracting = false
                isBatchExtracting = false
            }

            var completedCount = 0
            var failedCount = 0

            for (index, item) in extractionItems.enumerated() {
                selectedItemID = item.id
                itemStatuses[item.id] = extractionItems.count > 1
                    ? "批处理中 (\(index + 1)/\(extractionItems.count))…"
                    : "正在准备环境…"
                runtimeStatus = "正在准备 AI 文档提取运行环境…"

                do {
                    itemStatuses[item.id] = "正在提取内容…"
                    runtimeStatus = "正在提取内容…"
                    let progressSink = AIDocumentExtractionProgressSink(viewModel: self, itemID: item.id)
                    let result = try await runtime.extract(
                        source: item.source,
                        options: extractionOptions
                    ) { message in
                        progressSink.update(message)
                    }

                    markdownResults[item.id] = result.markdown
                    suggestedTitles[item.id] = result.suggestedTitle
                    itemErrors[item.id] = nil
                    itemStatuses[item.id] = "提取完成"
                    runtimeStatus = "运行环境已就绪"
                    globalMessage = "已完成 \(result.suggestedTitle ?? item.title) 的 Markdown 提取。"
                    saveToHistory(item: item, markdown: result.markdown)
                    completedCount += 1
                } catch {
                    itemStatuses[item.id] = "提取失败"
                    let message = error.localizedDescription
                    itemErrors[item.id] = message
                    globalMessage = message
                    failedCount += 1
                }
            }

            // Select the first successfully completed item, or first item
            if let firstCompleted = extractionItems.first(where: { markdownResults[$0.id]?.isEmpty == false }) {
                selectedItemID = firstCompleted.id
            } else {
                selectedItemID = extractionItems.first?.id
            }

            if extractionItems.count > 1 {
                globalMessage = "批处理完成：成功 \(completedCount) 项，失败 \(failedCount) 项。"
            }

            showResultSheet = true
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

                if viewModel.items.isEmpty {
                    conversionCard(height: cardHeight)
                        .frame(maxHeight: .infinity)
                } else {
                    queueCard(height: cardHeight)
                        .frame(maxHeight: .infinity)
                }

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
        .sheet(isPresented: $viewModel.showResultSheet) {
            resultSheet
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

                    Text("点击读取剪贴板，或直接拖入支持的文件格式开始提取。")
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

            HStack(spacing: 10) {
                Menu {
                    Toggle("启用图片 OCR", isOn: $viewModel.performOCR)
                        .disabled(viewModel.isExtracting)

                    Text(viewModel.performOCR ? "会识别图片文字，处理耗时较长" : "已跳过图片 OCR，纯图片文件无法提取")

                    Divider()

                    Button("从剪贴板批量导入链接") {
                        viewModel.addClipboardLinkAndExtract()
                    }
                    .keyboardShortcut("v", modifiers: .command)
                    .disabled(viewModel.isExtracting)

                    Button("手动输入链接…") {
                        showQuickAddSheet = true
                    }
                    .disabled(viewModel.isExtracting)

                    Button("批量导入文件…") {
                        viewModel.isImporting = true
                    }
                    .disabled(viewModel.isExtracting)

                    Divider()

                    Button("批量处理全部项目") {
                        viewModel.extractAll()
                    }
                    .disabled(viewModel.items.isEmpty || viewModel.isExtracting)

                    Button("查看提取结果窗口") {
                        viewModel.showResultSheet = true
                    }
                    .disabled(viewModel.items.isEmpty)

                    Button("批量导出全部 Markdown…") {
                        viewModel.exportAllMarkdown()
                    }
                    .disabled(!viewModel.canExportAll)
                } label: {
                    Label("批处理", systemImage: "square.stack.3d.up")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 11)
                        .frame(height: 32)
                        .background(Capsule().fill(.primary.opacity(0.06)))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Spacer()

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
            .frame(maxWidth: .infinity)
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

    private func queueCard(height: CGFloat) -> some View {
        VStack(spacing: 0) {
            // Queue Toolbar
            HStack(spacing: 12) {
                Image(systemName: "list.bullet.rectangle.portrait")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.blue)

                Text("待提取 / 已提取项目 (\(viewModel.items.count))")
                    .font(.system(size: 13, weight: .semibold))

                if viewModel.completedCount > 0 {
                    Text("• 已完成 \(viewModel.completedCount) 项")
                        .font(.system(size: 11))
                        .foregroundStyle(.green)
                }

                Spacer()

                if !viewModel.isExtracting {
                    Button("从剪贴板添加") {
                        viewModel.addClipboardLinkAndExtract()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("全部提取") {
                        viewModel.extractAll()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button("查看结果") {
                        viewModel.showResultSheet = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("清空") {
                        viewModel.clearAll()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                    .font(.system(size: 11))
                    .padding(.leading, 4)
                } else {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在提取中…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))

            Divider()

            // Queue List
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(viewModel.items) { item in
                        AIDocumentQueueRow(
                            item: item,
                            suggestedTitle: viewModel.suggestedTitles[item.id],
                            status: viewModel.itemStatuses[item.id] ?? "等待中",
                            isSelected: item.id == viewModel.selectedItemID,
                            isExtracting: viewModel.isExtracting,
                            onSelect: {
                                viewModel.selectedItemID = item.id
                            },
                            onDoubleClick: {
                                viewModel.selectedItemID = item.id
                                viewModel.showResultSheet = true
                            },
                            onRetry: {
                                viewModel.retry(item: item)
                            },
                            onDelete: {
                                viewModel.remove(item: item)
                            }
                        )
                    }
                }
                .padding(14)
            }

            Divider()

            // Bottom Drop Zone
            HStack(spacing: 8) {
                Image(systemName: "tray.and.arrow.down")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Text("支持拖入更多文件，或按 ⌘V 快速粘贴链接")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Spacer()

                if viewModel.canExportAll {
                    Button {
                        viewModel.exportAllMarkdown()
                    } label: {
                        Label("批量导出全部 Markdown", systemImage: "square.and.arrow.up")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.2))
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(panelBackgroundColor)
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(isDropTargeted ? Color.accentColor.opacity(0.45) : cardBorderColor, style: StrokeStyle(lineWidth: isDropTargeted ? 2 : 1, dash: isDropTargeted ? [10, 8] : []))
                }
        }
        .shadow(color: cardShadowColor, radius: 18, x: 0, y: 8)
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
                    Text("手动添加链接")
                        .font(.title3.weight(.bold))
                    Text("支持输入单个或多个网页链接（每行一个或空格分隔），直接开始批量提取。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("网页链接")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextEditor(text: $viewModel.draftLink)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 100)
                    .padding(4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    )
            }

            HStack(spacing: 10) {
                Button("开始提取") {
                    viewModel.addDraftLinkAndExtract()
                    showQuickAddSheet = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isExtracting || viewModel.draftLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button("仅加入队列") {
                    viewModel.addDraftLink()
                    showQuickAddSheet = false
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.draftLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button("选择本地文件") {
                    showQuickAddSheet = false
                    viewModel.isImporting = true
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isExtracting)

                Spacer()

                Button("取消") {
                    showQuickAddSheet = false
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(width: 520)
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

    // MARK: - Results Window

    private var resultSheet: some View {
        Group {
            if viewModel.items.count > 1 {
                HStack(spacing: 0) {
                    // Left Column: Item Sidebar
                    VStack(spacing: 0) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("提取项目列表")
                                    .font(.headline)
                                Text("共 \(viewModel.items.count) 个项目（已完成 \(viewModel.completedCount)）")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if viewModel.canExportAll {
                                Button {
                                    viewModel.exportAllMarkdown()
                                } label: {
                                    Image(systemName: "square.and.arrow.up")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .help("批量导出全部 Markdown")
                            }
                        }
                        .padding(16)

                        Divider()

                        ScrollView {
                            LazyVStack(spacing: 4) {
                                ForEach(viewModel.items) { item in
                                    Button {
                                        viewModel.selectedItemID = item.id
                                    } label: {
                                        HStack(spacing: 10) {
                                            Image(systemName: iconName(for: item))
                                                .font(.system(size: 13))
                                                .foregroundStyle(item.id == viewModel.selectedItemID ? .white : .blue)
                                                .frame(width: 18)

                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(viewModel.suggestedTitles[item.id] ?? item.title)
                                                    .font(.system(size: 12, weight: item.id == viewModel.selectedItemID ? .semibold : .medium))
                                                    .foregroundStyle(item.id == viewModel.selectedItemID ? .white : .primary)
                                                    .lineLimit(1)

                                                Text(item.subtitle)
                                                    .font(.system(size: 10))
                                                    .foregroundStyle(item.id == viewModel.selectedItemID ? .white.opacity(0.8) : .secondary)
                                                    .lineLimit(1)
                                            }

                                            Spacer(minLength: 4)

                                            let status = viewModel.itemStatuses[item.id] ?? "等待中"
                                            if status == "提取完成" {
                                                Image(systemName: "checkmark.circle.fill")
                                                    .font(.system(size: 13))
                                                    .foregroundStyle(item.id == viewModel.selectedItemID ? .white : .green)
                                            } else if status.contains("失败") {
                                                Image(systemName: "exclamationmark.circle.fill")
                                                    .font(.system(size: 13))
                                                    .foregroundStyle(item.id == viewModel.selectedItemID ? .white : .red)
                                            } else if status.contains("提取") || status.contains("处理") || status.contains("环境") {
                                                ProgressView()
                                                    .controlSize(.mini)
                                            } else {
                                                Image(systemName: "clock")
                                                    .font(.system(size: 12))
                                                    .foregroundStyle(item.id == viewModel.selectedItemID ? .white.opacity(0.8) : .secondary)
                                            }
                                        }
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 8)
                                        .background(
                                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                .fill(item.id == viewModel.selectedItemID ? Color.accentColor : Color.clear)
                                        )
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(10)
                        }
                    }
                    .frame(width: 270)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))

                    Divider()

                    // Right Column: Detail Content
                    resultDetailContent
                }
                .frame(minWidth: 920, idealWidth: 1000, maxWidth: 1200, minHeight: 620, idealHeight: 680, maxHeight: 900)
            } else {
                resultDetailContent
                    .frame(width: 780, height: 640)
            }
        }
    }

    private var resultDetailContent: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(viewModel.suggestedTitles[viewModel.selectedItem?.id ?? UUID()] ?? viewModel.selectedItem?.title ?? "提取结果")
                        .font(.title3.weight(.bold))
                        .lineLimit(1)

                    HStack(spacing: 8) {
                        Text(viewModel.selectedStatus)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(viewModel.selectedStatus.contains("失败") ? .red : (viewModel.selectedStatus == "提取完成" ? .green : .blue))

                        if let selectedItem = viewModel.selectedItem {
                            Text("•")
                                .foregroundStyle(.tertiary)
                            Text(selectedItem.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }

                Spacer()

                Button("完成") {
                    viewModel.showResultSheet = false
                }
                .buttonStyle(.bordered)
            }
            .padding(20)

            Divider()

            Group {
                if !viewModel.selectedMarkdown.isEmpty {
                    HTMLPreviewView(html: viewModel.selectedPreviewHTML)
                        .background(Color(nsColor: .textBackgroundColor))
                } else if let selectedError = viewModel.selectedError {
                    VStack(spacing: 14) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(.orange)
                        Text("提取失败")
                            .font(.headline)
                        Text(selectedError)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 460)

                        if let selectedItem = viewModel.selectedItem, !viewModel.isExtracting {
                            Button("重试此项") {
                                viewModel.retry(item: selectedItem)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .padding(.top, 6)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(24)
                    .background(panelBackgroundColor)
                } else if viewModel.isExtracting {
                    VStack(spacing: 14) {
                        ProgressView()
                            .scaleEffect(1.2)
                        Text(viewModel.selectedStatus)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(24)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 32))
                            .foregroundStyle(.tertiary)
                        Text("尚未提取内容")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        if let selectedItem = viewModel.selectedItem {
                            Button("立即提取") {
                                viewModel.retry(item: selectedItem)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(24)
                }
            }
            .frame(minHeight: 420)

            Divider()

            HStack(spacing: 10) {
                Button("复制 Markdown") {
                    viewModel.copySelectedMarkdown()
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

                if viewModel.items.count > 1 {
                    Button("批量导出全部…") {
                        viewModel.exportAllMarkdown()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!viewModel.canExportAll)
                }
            }
            .padding(18)
        }
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
        return "自动解析剪贴板中的一个或多个网页链接，拖入文件也会直接开始转换。"
    }

    private var footerHint: some View {
        HStack(spacing: 6) {
            Image(systemName: "shield")
            Text(viewModel.performOCR ? "图片 OCR 已开启；可在「批处理」菜单关闭以提升速度。" : "图片 OCR 已关闭，文章与文档提取会更快。")
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

    private func iconName(for item: AIDocumentExtractItem) -> String {
        switch item.source {
        case .file:
            return "doc.text"
        case .link(let url) where (url.host ?? "").contains("mp.weixin.qq.com") || (url.host ?? "").contains("weibo.com") || (url.host ?? "").contains("weibo.cn"):
            return "text.page.badge.magnifyingglass"
        case .link:
            return "globe"
        }
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
    @State private var isHovered = false

    let item: AIDocumentExtractItem
    let suggestedTitle: String?
    let status: String
    let isSelected: Bool
    let isExtracting: Bool
    let onSelect: () -> Void
    let onDoubleClick: () -> Void
    let onRetry: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.system(size: 16))
                .foregroundStyle(iconColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(displayTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(item.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // Status Badge
            HStack(spacing: 6) {
                if status.contains("提取") || status.contains("处理") || status.contains("环境") {
                    ProgressView()
                        .controlSize(.mini)
                }
                Text(status)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(statusColor)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(statusColor.opacity(0.12))
            .clipShape(Capsule())

            // Row Action buttons
            if isHovered || isSelected {
                HStack(spacing: 6) {
                    if status.contains("失败") && !isExtracting {
                        Button(action: onRetry) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.blue)
                        .help("重新提取")
                    }

                    if !isExtracting {
                        Button(action: onDelete) {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("从队列移除")
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(rowBackgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(rowBorderColor, lineWidth: 1)
        )
        .shadow(color: rowShadowColor, radius: isSelected ? 8 : 4, x: 0, y: 2)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onTapGesture(count: 2, perform: onDoubleClick)
        .onHover { isHovered = $0 }
    }

    private var displayTitle: String {
        suggestedTitle ?? item.title
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

    private var iconColor: Color {
        switch item.source {
        case .file:
            return .purple
        case .link(let url) where (url.host ?? "").contains("mp.weixin.qq.com"):
            return .green
        case .link(let url) where (url.host ?? "").contains("weibo.com") || (url.host ?? "").contains("weibo.cn"):
            return .orange
        case .link:
            return .blue
        }
    }

    private var statusColor: Color {
        if status.contains("失败") {
            return .red
        }
        if status == "提取完成" {
            return .green
        }
        if status.contains("提取") || status.contains("处理") || status.contains("环境") {
            return .blue
        }
        return .secondary
    }

    private var rowBackgroundColor: Color {
        if isSelected {
            return Color.accentColor.opacity(colorScheme == .dark ? 0.20 : 0.10)
        }
        return colorScheme == .dark
        ? Color(nsColor: .controlBackgroundColor).opacity(0.66)
        : Color(nsColor: .textBackgroundColor)
    }

    private var rowBorderColor: Color {
        if isSelected {
            return Color.accentColor.opacity(colorScheme == .dark ? 0.40 : 0.25)
        }
        return Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.05)
    }

    private var rowShadowColor: Color {
        Color.black.opacity(colorScheme == .dark ? (isSelected ? 0.24 : 0.12) : (isSelected ? 0.08 : 0.03))
    }
}
