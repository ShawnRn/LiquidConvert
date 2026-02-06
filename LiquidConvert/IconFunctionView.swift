//
//  IconFunctionView.swift
//  LiquidConvert
//
//  Created by Shawn Rain.
//
import SwiftUI
import UniformTypeIdentifiers

struct IconFunctionView: View, Sendable {
    @State private var files: [URL] = []
    @Environment(\.colorScheme) private var colorScheme

    @AppStorage("icon_del_orig") private var deleteOriginal = false
    @AppStorage("icon_gen_set") private var generateIconSet = false

    @State private var isProcessing = false
    @State private var isImporting = false
    @State private var conversionStatus: [URL: String] = [:]
    @State private var targetFormat: IconConverter.TargetFormat = .icns
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
                        Label("添加图片/ICNS", systemImage: "plus")
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
                            IconFileRow(
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
            .frame(minWidth: 300, maxWidth: .infinity)
            .frame(minWidth: 300, maxWidth: .infinity)
            .onDrop(of: [.fileURL], delegate: FileDropDelegate(action: { handleImportedURLs($0) }))

            // === 右侧：检查器 (Form Style) ===
            VStack(spacing: 0) {
                Form {
                    Section("输出配置") {
                        Picker("目标格式", selection: $targetFormat) {
                            ForEach(IconConverter.TargetFormat.allCases, id: \.self) { fmt in
                                Text(fmt.rawValue).tag(fmt)
                            }
                        }
                        .disabled(isProcessing)
                    }

                    Section("任务选项") {
                        Toggle("同时生成 IconSet", isOn: $generateIconSet)
                        Toggle("完成后删除源文件", isOn: $deleteOriginal)
                    }
                    .disabled(isProcessing)

                    Section(header: Text("小贴士"), footer: Text("生成的 IconSet 将包含多种尺寸，适合 Xcode 使用。")) {
                        HStack {
                            Image(systemName: "info.circle")
                            Text("图标优化")
                            Spacer()
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        
                        Text("转换为 ICNS 时，建议原始图片分辨率至少为 1024x1024。")
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
                            Text("共 \(files.count) 个图标项目，准备就绪")
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    }

                    Button(action: startConversion) {
                        HStack(spacing: 8) {
                            if isProcessing {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "square.stack.3d.up.fill")
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
            .frame(minWidth: 280, maxWidth: 350)
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.icns, .image],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls): handleImportedURLs(urls)
            case .failure(let error): print("File selection error: \(error.localizedDescription)")
            }
        }
    }

    // Row View
    struct IconFileRow: View {
        let url: URL
        let status: String
        let statusColor: Color
        @Environment(\.colorScheme) private var colorScheme

        var body: some View {
            HStack(spacing: 16) {
                // 左侧图表
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                        .frame(width: 44, height: 44)
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.05), lineWidth: 0.5)
                        }
                    
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
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
                
                // 右侧格式标签
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
                Image(systemName: "app.dashed")
                    .font(.system(size: 48))
                    .foregroundStyle(isHovering ? .blue : .secondary.opacity(0.3))
                    .scaleEffect(isHovering ? 1.1 : 1.0)
                    .animation(.spring(response: 0.3), value: isHovering)
                
                VStack(spacing: 4) {
                    Text("拖拽图片或 ICNS 到这里")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("自动生成多尺寸 ICNS 与 IconSet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                
                Button("浏览文件") { onBrowse() }
                    .tint(.blue)
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
            let finalFiles = await Task.detached(priority: .userInitiated) {
                FileScanner.scan(urls: urls, allowedExtensions: ["png", "jpg", "jpeg", "icns"])
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
        let target = targetFormat
        let del = deleteOriginal
        let iconSet = generateIconSet

        Task {
            while true {
                // 1. 获取下一个待处理文件
                guard let url = files.first(where: { conversionStatus[$0] == nil || conversionStatus[$0] == "等待中" }) else { break }

                // 2. 更新状态
                self.conversionStatus[url] = "处理中..."
                
                // 3. 执行转换
                do {
                    try await Task.detached(priority: .userInitiated) {
                        let _ = try await IconConverter.convert(
                            inputURL: url, targetFormat: target, generateIconSet: iconSet)
                        if del { try? FileManager.default.removeItem(at: url) }
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
                title: "图标转换完成", subtitle: "队列中的任务已全部处理完毕")
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
}
