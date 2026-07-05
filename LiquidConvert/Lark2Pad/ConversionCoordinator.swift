//
//  ConversionCoordinator.swift
//  LiquidConvert
//
//  Orchestrates the full pipeline: clipboard HTML → image fetch → Turndown → result.
//

import Foundation
import Combine

/// Observable coordinator that drives the conversion pipeline and exposes state for SwiftUI.
@MainActor
final class ConversionCoordinator: ObservableObject {
    struct OversizedImagePrompt: Identifiable, Equatable {
        let id = UUID()
        let byteCount: Int
        let uploadLimitBytes: Int

        var message: String {
            "检测到飞书原文档里存在超过上传限制的大图。\n当前图片约 \(Self.megabyteString(for: byteCount))，而图床稳定限制约为 \(Self.megabyteString(for: uploadLimitBytes))。\n\n是否自动按现有“图片压缩 / Auto 5 MB”规则压缩后继续转换？"
        }

        private static func megabyteString(for bytes: Int) -> String {
            String(format: "%.1f MB", Double(bytes) / 1_000_000)
        }
    }

    private enum UploadMode {
        case askBeforeCompressing
        case compressOversizedImages
    }

    // MARK: - Published State

    enum Phase: Equatable {
        case idle
        case processing
        case rendering // Waiting for WebView to finish painting
        case done
        case error(message: String)
    }

    @Published var phase: Phase = .idle
    @Published var statusMessage: String = ""
    @Published var markdownResult: String = ""
    @Published var etherpadHTML: String = "" // Raw version for export
    @Published var previewHTML: String = ""   // Rendered version for preview
    @Published var isLoggedIntoEtherpad: Bool = false
    
    // 进度跟踪
    @Published var uploadProgress: Double = 0 // 0.0 - 1.0 整体进度
    @Published var speedMessage: String = ""  // 实时网速文本
    @Published var oversizedImagePrompt: OversizedImagePrompt?

    // MARK: - Engine
    
    private let engine = TurndownEngine()
    private var engineReady = false
    private var pendingHTML: String?
    private var pendingMarkdown: String?
    private var pendingBaseDirectory: URL?
    private var pendingAutoUpload = false

    init() {
        checkLoginStatus()
    }

    func checkLoginStatus() {
        isLoggedIntoEtherpad = CookieManager.shared.hasValidSession
    }

    // MARK: - Public API

    /// Warm up the Turndown engine (call once at app launch).
    func prepareEngine() async {
        await engine.prepare()
        engineReady = true
    }

    /// Run the full conversion pipeline on pasted HTML.
    func convert(html: String, autoUpload: Bool) async {
        pendingHTML = html
        pendingAutoUpload = autoUpload
        await convert(html: html, autoUpload: autoUpload, uploadMode: .compressOversizedImages)
    }

    func retryPendingConversionWithCompression() async {
        if let pendingHTML {
            oversizedImagePrompt = nil
            statusMessage = "检测到超限图片，正在自动压缩后继续上传…"
            phase = .processing
            uploadProgress = 0
            speedMessage = ""
            await convert(html: pendingHTML, autoUpload: pendingAutoUpload, uploadMode: .compressOversizedImages)
        } else if let pendingMarkdown {
            oversizedImagePrompt = nil
            statusMessage = "检测到超限图片，正在自动压缩后继续上传…"
            phase = .processing
            uploadProgress = 0
            speedMessage = ""
            await convertMarkdown(content: pendingMarkdown, baseDirectory: pendingBaseDirectory, autoUpload: pendingAutoUpload, uploadMode: .compressOversizedImages)
        }
    }

    func dismissOversizedImagePrompt() {
        oversizedImagePrompt = nil
        statusMessage = ""
        uploadProgress = 0
        speedMessage = ""
        phase = .idle
    }

    private func convert(html: String, autoUpload: Bool, uploadMode: UploadMode) async {
        if !engineReady {
            statusMessage = "引擎正在准备中，请稍候…"
            phase = .processing
            // Wait for engine to be ready if not already (max 4 seconds)
            for _ in 0..<40 {
                if engineReady { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        
        guard engineReady else {
            phase = .error(message: "引擎准备超时，请重载应用。")
            return
        }

        statusMessage = "正在解析 HTML 结构…"
        phase = .processing

        do {
            // Step 1: Parse HTML and extract image URLs
            let images = try await engine.loadHTMLAndGetImageURLs(html)

            // Step 2: 自动搬家图片至私有图床 (如果开启了自动上传)
            var replacements: [(id: Int, base64: String)] = []
            if autoUpload && !images.isEmpty {
                statusMessage =
                    uploadMode == .compressOversizedImages
                    ? "正在上传 \(images.count) 张图片（超限图片会自动压缩）..."
                    : "正在准备上传 \(images.count) 张图片..."
                uploadProgress = 0
                speedMessage = ""
                
                // 使用 try-catch 捕获上传过程中的任何严重错误
                do {
                    replacements = try await ImageUploader.uploadAll(
                        images: images,
                        behavior: uploadMode == .compressOversizedImages ? .compressOversizedImages : .askBeforeCompressing
                    ) { [weak self] batchProgress in
                        guard let self = self else { return }
                        self.uploadProgress = batchProgress.overallFraction
                        self.speedMessage = batchProgress.speedMessage
                        self.statusMessage = "正在并发上传图片 (\(batchProgress.completed)/\(batchProgress.total))..."
                    }
                } catch let error as ImageUploader.UploadError {
                    switch error {
                    case .oversizedImageRequiresCompression(let summary):
                        uploadProgress = 0
                        speedMessage = ""
                        oversizedImagePrompt = OversizedImagePrompt(
                            byteCount: summary.byteCount,
                            uploadLimitBytes: summary.uploadLimitBytes
                        )
                        phase = .idle
                        statusMessage = ""
                        return
                    default:
                        print("[ConversionCoordinator] ❌ 图片上传环节报错: \(error.localizedDescription)")
                        phase = .error(message: "图片上传失败: \(error.localizedDescription)")
                        return
                    }
                } catch {
                    print("[ConversionCoordinator] ❌ 图片上传环节报错: \(error.localizedDescription)")
                    phase = .error(message: "图片上传失败: \(error.localizedDescription)。请检查网络连接或稍后重试。")
                    return
                }
            }

            // Step 3: 执行 Markdown 转换 (如果存在替换则采用替换后的 DOM)
            statusMessage = "正在执行 Markdown 转换…"
            let markdown = try await engine.replaceImagesAndConvert(replacements)

            markdownResult = markdown
            previewHTML = EtherpadExporter.buildRenderedHTML(from: markdown)
            etherpadHTML = EtherpadExporter.buildRawHTML(from: markdown)
            
            // Transition to rendering phase (waiting for WebView)
            statusMessage = "正在渲染预览…"
            phase = .rendering
            
            NotificationManager.send(title: "飞书转换完成", subtitle: "文件已解析并准备好导出！")
        } catch {
            phase = .error(message: "转换失败: \(error.localizedDescription)")
        }
    }

    /// Complete the process once rendering is finished.
    func markDone() {
        phase = .done
    }

    /// Reset to initial state.
    func reset() {
        markdownResult = ""
        etherpadHTML = ""
        previewHTML = ""
        statusMessage = ""
        uploadProgress = 0
        speedMessage = ""
        oversizedImagePrompt = nil
        pendingHTML = nil
        pendingMarkdown = nil
        pendingBaseDirectory = nil
        pendingAutoUpload = false
        phase = .idle
    }

    // MARK: - Markdown Conversion Helpers & Structures

    struct MarkdownImage {
        let id: Int
        let urlRange: NSRange
        let originalURL: String
        let resolvedURL: String
    }

    /// Run the conversion pipeline on Markdown content (e.g. from dragged file)
    func convertMarkdown(content: String, baseDirectory: URL?, autoUpload: Bool) async {
        pendingHTML = nil
        pendingMarkdown = content
        pendingBaseDirectory = baseDirectory
        pendingAutoUpload = autoUpload
        await convertMarkdown(content: content, baseDirectory: baseDirectory, autoUpload: autoUpload, uploadMode: .compressOversizedImages)
    }

    private func convertMarkdown(
        content: String,
        baseDirectory: URL?,
        autoUpload: Bool,
        uploadMode: UploadMode
    ) async {
        // Clean markdown backslash escapes (e.g. B\&O -> B&O, Type\-C -> Type-C) before conversion
        let cleanedContent = EtherpadExporter.normalizeMarkdownSpacing(
            ManagedMarkItDownRuntime.stripMarkdownEscapes(content)
        )
        
        statusMessage = "正在解析 Markdown 结构…"
        phase = .processing

        // Step 1: 提取图片 URLs 和精确 range
        let mdImages = extractImages(from: cleanedContent, baseDirectory: baseDirectory)

        // Step 2: 上传图片到私有图床
        var replacements: [(id: Int, base64: String)] = []
        if autoUpload && !mdImages.isEmpty {
            statusMessage =
                uploadMode == .compressOversizedImages
                ? "正在上传 \(mdImages.count) 张图片（超限图片会自动压缩）..."
                : "正在准备上传 \(mdImages.count) 张图片..."
            uploadProgress = 0
            speedMessage = ""

            let uploadImages = mdImages.map { (id: $0.id, url: $0.resolvedURL) }

            do {
                replacements = try await ImageUploader.uploadAll(
                    images: uploadImages,
                    behavior: uploadMode == .compressOversizedImages ? .compressOversizedImages : .askBeforeCompressing
                ) { [weak self] batchProgress in
                    guard let self = self else { return }
                    self.uploadProgress = batchProgress.overallFraction
                    self.speedMessage = batchProgress.speedMessage
                    self.statusMessage = "正在并发上传图片 (\(batchProgress.completed)/\(batchProgress.total))..."
                }
            } catch let error as ImageUploader.UploadError {
                switch error {
                case .oversizedImageRequiresCompression(let summary):
                    uploadProgress = 0
                    speedMessage = ""
                    oversizedImagePrompt = OversizedImagePrompt(
                        byteCount: summary.byteCount,
                        uploadLimitBytes: summary.uploadLimitBytes
                    )
                    phase = .idle
                    statusMessage = ""
                    return
                default:
                    print("[ConversionCoordinator] ❌ 图片上传环节报错: \(error.localizedDescription)")
                    phase = .error(message: "图片上传失败: \(error.localizedDescription)")
                    return
                }
            } catch {
                print("[ConversionCoordinator] ❌ 图片上传环节报错: \(error.localizedDescription)")
                phase = .error(message: "图片上传失败: \(error.localizedDescription)。请检查网络连接或稍后重试。")
                return
            }
        }

        // Step 3: 进行高精度替换，生成最终 Markdown
        statusMessage = "正在处理图片链接..."
        let finalMarkdown = replaceMarkdownImages(content: cleanedContent, images: mdImages, replacements: replacements)

        // Step 4: 将 ![alt](url) 转换为 <img> 标签，与旧版 TurndownEngine keepImages 输出一致
        let normalizedMarkdown = convertMarkdownImagesToHTML(finalMarkdown)

        markdownResult = normalizedMarkdown
        previewHTML = EtherpadExporter.buildRenderedHTML(from: normalizedMarkdown)
        etherpadHTML = EtherpadExporter.buildRawHTML(from: normalizedMarkdown)

        statusMessage = "正在渲染预览…"
        phase = .rendering

        NotificationManager.send(title: "Markdown 转换完成", subtitle: "文件已解析并准备好导出！")
    }

    private func extractImages(from markdown: String, baseDirectory: URL?) -> [MarkdownImage] {
        var images: [MarkdownImage] = []
        var idCounter = 1
        let nsString = markdown as NSString

        // 1. 匹配 Markdown 格式: ![alt](url)
        if let mdRegex = try? NSRegularExpression(pattern: #"!\[.*?\]\((.*?)\)"#, options: []) {
            let matches = mdRegex.matches(in: markdown, options: [], range: NSRange(location: 0, length: nsString.length))
            for match in matches {
                guard match.numberOfRanges > 1 else { continue }
                let urlRange = match.range(at: 1)
                let originalURL = nsString.substring(with: urlRange).trimmingCharacters(in: .whitespacesAndNewlines)
                if originalURL.isEmpty || originalURL.hasPrefix("#") { continue }
                let resolvedURL = resolveImageURL(originalURL, baseDirectory: baseDirectory)
                images.append(MarkdownImage(id: idCounter, urlRange: urlRange, originalURL: originalURL, resolvedURL: resolvedURL))
                idCounter += 1
            }
        }

        // 2. 匹配 HTML img 标签: <img[^>]+src=["'](.*?)["']
        if let htmlRegex = try? NSRegularExpression(pattern: #"<img[^>]+src=["'](.*?)["']"#, options: [.caseInsensitive]) {
            let matches = htmlRegex.matches(in: markdown, options: [], range: NSRange(location: 0, length: nsString.length))
            for match in matches {
                guard match.numberOfRanges > 1 else { continue }
                let urlRange = match.range(at: 1)
                let originalURL = nsString.substring(with: urlRange).trimmingCharacters(in: .whitespacesAndNewlines)
                if originalURL.isEmpty || originalURL.hasPrefix("#") { continue }
                let resolvedURL = resolveImageURL(originalURL, baseDirectory: baseDirectory)
                if !images.contains(where: { $0.urlRange == urlRange }) {
                    images.append(MarkdownImage(id: idCounter, urlRange: urlRange, originalURL: originalURL, resolvedURL: resolvedURL))
                    idCounter += 1
                }
            }
        }
        return images
    }

    private func resolveImageURL(_ urlString: String, baseDirectory: URL?) -> String {
        if urlString.hasPrefix("http://") || urlString.hasPrefix("https://") || urlString.hasPrefix("file://") || urlString.hasPrefix("data:") {
            return urlString
        }
        guard let baseDirectory = baseDirectory else { return urlString }
        if urlString.hasPrefix("/") {
            return URL(fileURLWithPath: urlString).absoluteString
        }
        return baseDirectory.appendingPathComponent(urlString).standardizedFileURL.absoluteString
    }

    private func replaceMarkdownImages(
        content: String,
        images: [MarkdownImage],
        replacements: [(id: Int, base64: String)]
    ) -> String {
        if replacements.isEmpty { return content }
        let replacementMap = Dictionary(uniqueKeysWithValues: replacements.map { ($0.id, $0.base64) })
        let sortedImages = images.sorted { $0.urlRange.location > $1.urlRange.location }
        var nsString = content as NSString
        for image in sortedImages {
            guard let newURL = replacementMap[image.id] else { continue }
            nsString = nsString.replacingCharacters(in: image.urlRange, with: newURL) as NSString
        }
        return nsString as String
    }

    /// 将 Markdown 图片语法 ![alt](url) 转换为 <img src="url" name="imgX"> HTML 标签
    /// name 使用 imga/imgb/.../imgz/imgaa 递增编号，与 TurndownEngine keepImages 规则完全一致
    private func convertMarkdownImagesToHTML(_ markdown: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"!\[([^\]]*)\]\(([^)]+)\)"#, options: []) else {
            return markdown
        }
        let nsString = markdown as NSString
        let matches = regex.matches(in: markdown, options: [], range: NSRange(location: 0, length: nsString.length))
        guard !matches.isEmpty else { return markdown }

        var result = markdown as NSString
        // 从后往前替换，保持 range 有效性
        for (reverseIdx, match) in matches.enumerated().reversed() {
            let index = matches.count - 1 - reverseIdx
            let name = "img\(Self.indexToLetters(index))"
            let url = nsString.substring(with: match.range(at: 2))
            let imgTag = "<img src=\"\(url)\" name=\"\(name)\">"
            result = result.replacingCharacters(in: match.range, with: imgTag) as NSString
        }
        return result as String
    }

    /// 将索引转换为纯字母字符串 (0 → a, 1 → b, ..., 25 → z, 26 → aa)
    /// 与 turndown-wrapper.js 中 indexToLetters 逻辑一致
    private static func indexToLetters(_ index: Int) -> String {
        var res = ""
        var n = index
        repeat {
            res = String(UnicodeScalar(97 + (n % 26))!) + res
            n = n / 26 - 1
        } while n >= 0
        return res
    }
}
