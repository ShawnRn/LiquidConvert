//
//  AudioFunctionView.swift
//  LiquidConvert
//
//  Created by Shawn Rain.
//
import SwiftUI
import UniformTypeIdentifiers

struct AudioFunctionView: View, Sendable {
    @State private var files: [URL] = []
    @Environment(\.colorScheme) private var colorScheme

    // 设置
    @AppStorage("audio_format") private var targetFormat: AudioConverter.Format = .aac
    @AppStorage("audio_del_orig") private var deleteOriginal = false

    // 状态
    @State private var isProcessing = false
    @State private var isImporting = false
    @State private var conversionStatus: [URL: String] = [:]
    @State private var totalCount: Int = 0
    @State private var processedCount: Int = 0
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
                    Text("待处理项目 (\(files.count))")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                    
                    Spacer()
                    
                    Button(action: { isImporting = true }) {
                        Label("添加音视频", systemImage: "plus")
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
                            AudioFileRow(
                                url: url, 
                                status: status(for: url), 
                                statusColor: statusColor(for: url),
                                iconName: iconName(for: url),
                                iconColor: iconColor(for: url)
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

                // 进度条
                if isProcessing {
                    VStack(spacing: 4) {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .tint(.blue)
                        Text("正在处理第 \(processedCount + 1) 个，共 \(totalCount) 个")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    .padding(12)
                    .background(.ultraThinMaterial)
                }
            }
            .frame(minWidth: 260, maxWidth: .infinity)
            .onDrop(of: [.fileURL], delegate: FileDropDelegate(action: { handleImportedURLs($0) }))

            // === 右侧：检查器 (Form Style) ===
            VStack(spacing: 0) {
                Form {
                    Section("输出配置") {
                        Picker("目标格式", selection: $targetFormat) {
                            ForEach(AudioConverter.Format.allCases, id: \.self) { fmt in
                                Text(shortLabel(for: fmt)).tag(fmt)
                            }
                        }
                        .disabled(isProcessing)
                    }

                    Section("任务选项") {
                        Toggle("完成后删除源文件", isOn: $deleteOriginal)
                            .disabled(isProcessing)
                    }

                    Section(footer: Text("支持从视频中提取音频，并适配网易云 NCM 解密。")) {
                        HStack {
                            Image(systemName: "info.circle")
                            Text("小贴士")
                            Spacer()
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        
                        Text("针对大批量 NCM 文件，建议开启“删除源文件”以节省空间。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
                            Text("共 \(files.count) 个音视频，准备就绪")
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    }

                    Button(action: startConversion) {
                        HStack(spacing: 8) {
                            if isProcessing {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "play.fill")
                            }
                            Text(isProcessing ? "正在处理..." : "开始转换")
                                .fontWeight(.bold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .disabled(files.isEmpty || isProcessing || !hasPendingFiles)
                    .controlSize(.large)
                    .shadow(color: .blue.opacity(0.2), radius: 8, x: 0, y: 4)
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
            allowedContentTypes: [.audio, .movie],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls): handleImportedURLs(urls)
            case .failure(let error): print("File selection error: \(error.localizedDescription)")
            }
        }
    }

    // Row View
    struct AudioFileRow: View {
        let url: URL
        let status: String
        let statusColor: Color
        let iconName: String
        let iconColor: Color
        @Environment(\.colorScheme) private var colorScheme

        var body: some View {
            HStack(spacing: 16) {
                // 左侧图表：更大且有磨砂感
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(iconColor.opacity(0.1))
                        .frame(width: 44, height: 44)
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(iconColor.opacity(0.15), lineWidth: 0.5)
                        }
                    
                    Image(systemName: iconName)
                        .font(.system(size: 18))
                        .foregroundColor(iconColor)
                        .shadow(color: iconColor.opacity(0.2), radius: 2, x: 0, y: 1)
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
        }
    }

    struct EmptyStateDropZone: View {
        let onBrowse: () -> Void
        let onDrop: @MainActor @Sendable ([URL]) -> Void
        @State private var isHovering = false
        
        var body: some View {
            VStack(spacing: 16) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(isHovering ? .blue : .secondary.opacity(0.3))
                    .scaleEffect(isHovering ? 1.1 : 1.0)
                    .animation(.spring(response: 0.3), value: isHovering)
                
                VStack(spacing: 4) {
                    Text("拖拽音频或视频到这里")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("支持提取音频、转换格式及 NCM 解压")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                
                Button("浏览文件") { onBrowse() }
                    .tint(.blue)
                    .controlSize(.regular)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.clear)
            .onDrop(of: [.fileURL], delegate: FileDropDelegate(action: { onDrop($0) }, isTargeted: $isHovering))
        }
    }

    // Logic
    func shortLabel(for format: AudioConverter.Format) -> String {
        switch format {
        case .aac: return "AAC"
        case .alac: return "ALAC"
        case .flac: return "FLAC"
        case .wav: return "WAV"
        case .mp3: return "MP3"
        }
    }

    @MainActor
    func handleImportedURLs(_ urls: [URL]) {
        Task {
            let audioExtensions = ["mp3", "wav", "m4a", "flac", "aac", "ogg", "wma", "aiff", "ncm", "mp4", "mov", "m4v", "avi", "mkv", "ts", "webm"]
            let finalFiles = await Task.detached(priority: .userInitiated) {
                FileScanner.scan(urls: urls, allowedExtensions: audioExtensions)
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
                    startConversion()
                }
            }
        }
    }

    func startConversion() {
        guard !files.isEmpty, !isProcessing else { return }
        isProcessing = true
        let fmt = targetFormat
        let shouldDelete = deleteOriginal

        Task {
            while true {
                // 1. 获取下一个待处理文件 (在主线程获取，确保状态最新)
                guard let url = files.first(where: { conversionStatus[$0] == nil || conversionStatus[$0] == "等待中" }) else { break }

                // 2. 更新状态
                self.conversionStatus[url] = "处理中..."
                
                // 3. 执行转换 (在后台线程执行)
                do {
                    try await Task.detached(priority: .userInitiated) {
                        let _ = try await AudioConverter.convert(inputURL: url, to: fmt)
                        if shouldDelete { try? FileManager.default.trashItem(at: url, resultingItemURL: nil) }
                    }.value
                    
                    self.conversionStatus[url] = "完成 ✅"
                    self.processedCount += 1
                } catch {
                    self.conversionStatus[url] = "失败: \(error.localizedDescription)"
                    self.processedCount += 1
                }
            }
            
            self.isProcessing = false
            NSSound(named: "Glass")?.play()
            NotificationManager.send(
                title: "音频转换完成", subtitle: "队列中的任务已全部处理完毕")
        }
    }

    func status(for url: URL) -> String { conversionStatus[url] ?? "等待中" }
    func statusColor(for url: URL) -> Color {
        let s = conversionStatus[url]
        if s?.contains("完成") == true { return .green }
        if s?.contains("失败") == true { return .red }
        if s == "处理中..." { return .blue }
        return .secondary
    }

    func iconName(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        if ext == "ncm" { return "lock.doc.fill" }
        let videoExts = ["mp4", "mov", "m4v", "avi", "mkv", "ts", "webm"]
        if videoExts.contains(ext) { return "video.fill" }
        return "waveform.circle.fill"
    }

    func iconColor(for url: URL) -> Color {
        let ext = url.pathExtension.lowercased()
        if ext == "ncm" { return .orange }
        let videoExts = ["mp4", "mov", "m4v", "avi", "mkv", "ts", "webm"]
        if videoExts.contains(ext) { return .blue }
        return .cyan
    }
}
