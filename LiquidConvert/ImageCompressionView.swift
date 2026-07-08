//
//  ImageCompressionView.swift
//  LiquidConvert
//
//  Created by Shawn Rain.
//
import SwiftUI
import UniformTypeIdentifiers

struct ImageCompressionView: View, Sendable {
    @State private var files: [URL] = []
    @Environment(\.colorScheme) private var colorScheme

    // 分辨率设置
    enum ResizeModeOption: String, CaseIterable {
        case auto = "自动"
        case none = "不调整"
        case longEdge = "长边"
        case shortEdge = "短边"
        case custom = "自定义"
    }

    @AppStorage("compress_resize_mode") private var resizeModeOption: ResizeModeOption = .auto
    @AppStorage("compress_resize_value") private var resizeValue: Int = 1080
    @AppStorage("compress_custom_width") private var customWidth: Int = 1920
    @AppStorage("compress_custom_height") private var customHeight: Int = 1080

    // 质量设置
    enum QualityMode: String, CaseIterable {
        case auto = "自动"
        case manual = "手动"
    }

    @AppStorage("compress_quality_mode") private var qualityMode: QualityMode = .auto
    @AppStorage("compress_quality") private var quality: Double = 0.8
    @AppStorage("compress_auto_5mb") private var autoCompressTo5MB = false
    @AppStorage("compress_del_orig") private var deleteOriginal = false
    @AppStorage("compress_target_format") private var targetFormat: ImageConverter.TargetFormat = .jpeg
    @AppStorage("compress_apply_rounded_corners") private var applyRoundedCorners = false

    // 状态
    @State private var isProcessing = false
    @State private var isImporting = false
    @State private var conversionStatus: [URL: String] = [:]
    @State private var totalCount: Int = 0
    @State private var processedCount: Int = 0
    @State private var currentProgress: String = ""
    @State private var currentFileProgress: Double = 0.0
    @State private var selection: Set<URL> = []

    var progress: Double {
        guard totalCount > 0 else { return 0 }
        return Double(processedCount) / Double(totalCount)
    }

    var hasPendingFiles: Bool {
        files.contains { url in
            let s = conversionStatus[url]
            return s == nil || s == "等待中" || s?.contains("失败") == true
        }
    }

    var body: some View {
        HSplitView {
            // === 左侧：文件列表区 ===
            VStack(spacing: 0) {
                // 顶部工具栏
                HStack {
                    Text("待处理图片 (\(files.count))")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                    
                    Spacer()
                    
                    Button(action: { isImporting = true }) {
                        Label("添加图片", systemImage: "plus")
                    }
                    .controlSize(.small)
                    
                    if !files.isEmpty {
                        Button("清空") {
                            withAnimation {
                                files.removeAll()
                                conversionStatus.removeAll()
                                selection.removeAll()
                                processedCount = 0
                                totalCount = 0
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.red)
                        .font(.system(size: 11))
                        .disabled(isProcessing)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(.bar)
                
                Divider()

                if files.isEmpty {
                    EmptyStateDropZone(onBrowse: { isImporting = true }, onDrop: { handleImportedURLs($0) })
                } else {
                    List(selection: $selection) {
                        ForEach(files, id: \.self) { url in
                            ImageFileRow(
                                url: url, 
                                status: status(for: url), 
                                statusColor: statusColor(for: url)
                            )
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                            .listRowSeparator(.visible, edges: .bottom)
                        }
                        .onDelete(perform: isProcessing ? nil : { idx in 
                            files.remove(atOffsets: idx)
                        })
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .background(Color(nsColor: .controlBackgroundColor))
                }

                // 底部的总进度条 (仅在处理时显示)
                if isProcessing {
                    VStack(spacing: 4) {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .tint(.orange)
                        if !currentProgress.isEmpty {
                            Text(currentProgress)
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(12)
                    .background(.ultraThinMaterial)
                }
            }
            .frame(minWidth: 260, maxWidth: .infinity)
            .onDrop(of: [.fileURL], delegate: FileDropDelegate(action: { handleImportedURLs($0) }))

            // === 右侧：设置检查器 (Form Style) ===
            VStack(spacing: 0) {
                Form {
                    Section("输出配置") {
                        Picker("目标格式", selection: $targetFormat) {
                            ForEach(ImageConverter.TargetFormat.allCases, id: \.self) { fmt in
                                Text(fmt.rawValue.uppercased()).tag(fmt)
                            }
                        }
                        .disabled(isProcessing)
                        
                        Toggle("添加圆角 (2% 比例)", isOn: $applyRoundedCorners)
                            .disabled(isProcessing)
                        
                        Picker("尺寸调整", selection: $resizeModeOption) {
                            ForEach(ResizeModeOption.allCases, id: \.self) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .disabled(isProcessing)

                        if resizeModeOption != .none && resizeModeOption != .auto {
                            if resizeModeOption == .custom {
                                HStack {
                                    Text("自定义尺寸")
                                    Spacer()
                                    TextField("宽", value: $customWidth, format: .number)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 60)
                                    Text("×").foregroundColor(.secondary)
                                    TextField("高", value: $customHeight, format: .number)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 60)
                                }
                            } else {
                                HStack {
                                    Text("像素值")
                                    Spacer()
                                    TextField("", value: $resizeValue, format: .number)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 80)
                                    Text("px").font(.caption).foregroundColor(.secondary)
                                }
                            }
                        }
                    }

                    Section(header: Text("质量控制")) {
                        Picker("模式", selection: $qualityMode) {
                            ForEach(QualityMode.allCases, id: \.self) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .disabled(isProcessing)

                        if qualityMode == .manual {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("质量强度")
                                    Spacer()
                                    Text("\(Int(quality * 100))%")
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                }
                                Slider(value: $quality, in: 0.1...1.0, step: 0.05)
                                    .tint(.orange)
                            }
                            .padding(.vertical, 4)
                        }
                        
                        Toggle("限制 ≤5MB (自动优化)", isOn: $autoCompressTo5MB)
                            .disabled(isProcessing)
                    }

                    Section("文件处理") {
                        Toggle("完成后删除原文件", isOn: $deleteOriginal)
                            .disabled(isProcessing)
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .windowBackgroundColor))

                Divider()

                // 执行按钮
                VStack(spacing: 16) {
                    if !files.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: "info.circle.fill")
                                .symbolRenderingMode(.hierarchical)
                            Text("共 \(files.count) 张图片，准备就绪")
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    }

                    Button(action: startCompression) {
                        HStack(spacing: 8) {
                            if isProcessing {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.right.circle.fill")
                            }
                            Text(isProcessing ? "正在处理..." : "开始转换")
                                .fontWeight(.bold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(files.isEmpty || isProcessing || !hasPendingFiles)
                    .controlSize(.large)
                    .shadow(color: .orange.opacity(0.2), radius: 8, x: 0, y: 4)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .background {
                    Rectangle()
                        .fill(.thinMaterial)
                        .overlay(alignment: .top) {
                            Divider()
                        }
                }
            }
            .frame(minWidth: 260, maxWidth: 350)
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.image, .svgImage],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                handleImportedURLs(urls)
            case .failure(let error):
                print("File selection error: \(error.localizedDescription)")
            }
        }
    }

    // Row View
    struct ImageFileRow: View {
        let url: URL
        let status: String
        let statusColor: Color
        @Environment(\.colorScheme) private var colorScheme
        
        @State private var icon: NSImage = NSImage(systemSymbolName: "photo.fill", accessibilityDescription: nil)!

        var body: some View {
            HStack(spacing: 16) {
                // 左侧图表：更大且有磨砂感
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                        .frame(width: 44, height: 44)
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.05), lineWidth: 0.5)
                        }
                    
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 28, height: 28)
                        .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(url.lastPathComponent)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    
                    HStack(spacing: 6) {
                        if status == "处理中..." {
                            ProgressView().controlSize(.small).scaleEffect(0.5)
                                .frame(width: 12, height: 12)
                        } else {
                            Circle()
                                .fill(statusColor)
                                .frame(width: 7, height: 7)
                                .shadow(color: statusColor.opacity(0.3), radius: 2)
                        }
                        Text(status)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(statusColor.opacity(0.9))
                    }
                }
                
                Spacer()
                
                // 右侧格式标签：更精致
                Text(url.pathExtension.uppercased())
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background {
                        Capsule()
                            .fill(Color.primary.opacity(0.06))
                    }
                    .foregroundColor(.secondary)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 2)
            .contextMenu {
                Button("在 Finder 中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
            .onAppear { loadIcon() }
        }

        private func loadIcon() {
            Task.detached(priority: .userInitiated) {
                let loadedIcon = NSWorkspace.shared.icon(forFile: url.path)
                await MainActor.run {
                    self.icon = loadedIcon
                }
            }
        }
    }

    struct EmptyStateDropZone: View {
        let onBrowse: () -> Void
        let onDrop: @MainActor @Sendable ([URL]) -> Void
        @State private var isHovering = false
        
        var body: some View {
            VStack(spacing: 16) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 48))
                    .foregroundStyle(isHovering ? .orange : .secondary.opacity(0.3))
                    .scaleEffect(isHovering ? 1.1 : 1.0)
                    .animation(.spring(response: 0.3), value: isHovering)
                
                VStack(spacing: 4) {
                    Text("拖拽图片到这里")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("支持主流图片与 SVG 的压缩转换")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                
                Button("浏览文件") { onBrowse() }
                    .tint(.orange)
                    .controlSize(.regular)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.clear)
            .background(Color.clear)
            .onDrop(of: [.fileURL], delegate: FileDropDelegate(action: { onDrop($0) }, isTargeted: $isHovering))
        }
    }

    // Logic
    @MainActor
    func handleImportedURLs(_ urls: [URL]) {
        Task {
            let imageExtensions = ImageSourceSupport.supportedImageExtensions
            let finalFiles = await Task.detached(priority: .userInitiated) {
                FileScanner.scan(urls: urls, allowedExtensions: imageExtensions)
            }.value
            
            withAnimation {
                var addedAny = false
                for url in finalFiles {
                    if !self.files.contains(url) {
                        self.files.append(url)
                        self.totalCount += 1
                        addedAny = true
                    }
                }
                if addedAny && !isProcessing {
                    startCompression()
                }
            }
        }
    }

    func startCompression() {
        guard !files.isEmpty, !isProcessing else { return }
        isProcessing = true
        

        let resizeMode: ImageResizeMode
        switch resizeModeOption {
        case .auto: resizeMode = .none
        case .none: resizeMode = .none
        case .longEdge: resizeMode = .longEdge(pixels: resizeValue)
        case .shortEdge: resizeMode = .shortEdge(pixels: resizeValue)
        case .custom: resizeMode = .custom(width: customWidth, height: customHeight)
        }

        let outputFormat: UTType
        switch targetFormat {
        case .jpeg: outputFormat = .jpeg
        case .png: outputFormat = .png
        case .heic: outputFormat = .heic
        case .webp: outputFormat = .webP
        case .tiff: outputFormat = .tiff
        }

        let options = ImageCompressionOptions(
            resizeMode: resizeMode,
            quality: qualityMode == .auto ? 0.8 : quality,
            deleteOriginal: deleteOriginal,
            autoCompressTo5MB: autoCompressTo5MB,
            targetFormat: outputFormat,
            applyRoundedCorners: applyRoundedCorners
        )

        Task {
            while true {
                // 1. 获取下一个待处理文件
                guard let url = files.first(where: { conversionStatus[$0] == nil || conversionStatus[$0] == "等待中" }) else { break }

                // 2. 更新状态
                self.conversionStatus[url] = "处理中..."
                self.currentFileProgress = 0.0

                do {
                    _ = try await Task.detached(priority: .userInitiated) {
                        try autoreleasepool {
                            try ImageCompressor.compress(inputURL: url, options: options) { progressMsg in
                                // 这里简化处理
                            }
                        }
                    }.value
                    
                    self.conversionStatus[url] = "完成 ✅"
                    self.processedCount += 1
                } catch {
                    self.conversionStatus[url] = "失败: \(error.localizedDescription)"
                    self.processedCount += 1
                }
                self.currentFileProgress = 0.0
                self.currentProgress = ""
            }
            
            self.isProcessing = false
            NSSound(named: "Glass")?.play()
            NotificationManager.send(
                title: "图片压缩完成",
                subtitle: "队列中的所有任务已处理完毕"
            )
        }
    }

    func status(for url: URL) -> String { conversionStatus[url] ?? "等待中" }
    func statusColor(for url: URL) -> Color {
        let s = conversionStatus[url]
        if s?.contains("完成") == true { return .green }
        if s?.contains("失败") == true { return .red }
        if s == "处理中..." { return .orange }
        return .secondary
    }
}
