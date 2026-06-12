import Foundation
import UniformTypeIdentifiers
import ImageIO
import CoreGraphics

/// 处理飞书图片下载并自动上传到公司私有图床的工具类
@MainActor
final class ImageUploader {
    struct OversizedImageSummary: Sendable, Equatable {
        let sourceURL: String
        let byteCount: Int
        let uploadLimitBytes: Int
    }

    enum UploadBehavior: Sendable {
        case direct
        case askBeforeCompressing
        case compressOversizedImages
    }

    struct UploadBatchProgress: Sendable {
        let completed: Int
        let total: Int
        let overallFraction: Double
        let activeUploads: Int
        let speedMessage: String
    }

    enum UploadError: LocalizedError {
        case oversizedImageRequiresCompression(OversizedImageSummary)
        case automaticCompressionFailed(description: String)
        case uploadRejected(statusCode: Int, description: String)
        case invalidUploadResponse(description: String)

        var errorDescription: String? {
            switch self {
            case .oversizedImageRequiresCompression(let summary):
                return "检测到超限图片（\(Self.megabyteString(for: summary.byteCount) )），超过上传限制 \(Self.megabyteString(for: summary.uploadLimitBytes))。"
            case .automaticCompressionFailed(let description):
                return "自动压缩失败：\(description)"
            case .uploadRejected(let statusCode, let description):
                if statusCode == 413 {
                    return "图片体积仍然超过服务端限制，请先压缩后再试。"
                }
                return "图床拒绝上传（HTTP \(statusCode)）：\(description)"
            case .invalidUploadResponse(let description):
                return "上传成功但服务端返回了无法识别的响应：\(description)"
            }
        }

        private static func megabyteString(for bytes: Int) -> String {
            String(format: "%.1f MB", Double(bytes) / 1_000_000)
        }
    }

    private struct PreparedUploadPayload {
        let data: Data
        let filename: String
        let mimeType: String
    }
    
    // MARK: - 配置信息
    private static let uploadLimitBytes = 4_800_000
    private static let maxConcurrentUploads = 5
    
    /// 共享的 URLSession，开启连接复用 (Keep-Alive)
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 6
        config.timeoutIntervalForRequest = 180 // 针对大图进一步放宽请求超时
        config.timeoutIntervalForResource = 300
        return URLSession(configuration: config)
    }()
    
    /// 批量处理图片：下载飞书临时图片并上传至私有图床输出进度
    /// 回调参数：聚合后的批量上传进度
    static func uploadAll(images: [(id: Int, url: String)], 
                        behavior: UploadBehavior = .direct,
                        progress: (@MainActor (UploadBatchProgress) -> Void)? = nil) async throws -> [(id: Int, base64: String)] {
        if images.isEmpty { return [] }

        let concurrency = min(maxConcurrentUploads, images.count)
        let tracker = UploadProgressTracker(total: images.count)
        progress?(await tracker.snapshot())

        print("[ImageUploader] 开始并发处理 \(images.count) 张图片，并发数: \(concurrency)")

        var iterator = images.enumerated().makeIterator()
        var results: [(position: Int, id: Int, base64: String)] = []

        return try await withThrowingTaskGroup(of: (position: Int, id: Int, base64: String).self) { group in
            func enqueueNext() {
                guard let (position, item) = iterator.next() else { return }
                group.addTask {
                    let startedProgress = await tracker.markStarted(position: position)
                    await MainActor.run { progress?(startedProgress) }

                    print("[ImageUploader] 正在处理第 \(position + 1)/\(images.count) 张图片: \(item.id)")

                    let newURL = try await uploadSingleImage(url: item.url, behavior: behavior) { fileProgress, speed in
                        Task {
                            let snapshot = await tracker.update(position: position, fraction: fileProgress, speed: speed)
                            await MainActor.run { progress?(snapshot) }
                        }
                    }

                    let finishedProgress = await tracker.markFinished(position: position)
                    await MainActor.run { progress?(finishedProgress) }

                    return (position: position, id: item.id, base64: newURL)
                }
            }

            for _ in 0..<concurrency {
                enqueueNext()
            }

            while let result = try await group.next() {
                results.append(result)
                enqueueNext()
            }

            let orderedResults = results
                .sorted { $0.position < $1.position }
                .map { (id: $0.id, base64: $0.base64) }

            print("[ImageUploader] 最终成功上传 \(orderedResults.count) / \(images.count) 张图片")
            return orderedResults
        }
    }
    
    // MARK: - 私有方法
    
    static func uploadSingleImage(
        url: String,
        behavior: UploadBehavior,
        onProgress: @escaping (Double, String) -> Void
    ) async throws -> String {
        guard let imageURL = URL(string: url) else {
            throw UploadError.invalidUploadResponse(description: "无效图片地址")
        }
        
        do {
            // 1. 下载图片数据
            let (rawData, response) = try await session.data(from: imageURL)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard statusCode == 200 else { 
                print("[ImageUploader] ❌ 下载失败: \(url), 状态码: \(statusCode)")
                throw UploadError.uploadRejected(statusCode: statusCode, description: "原图下载失败") 
            }
            
            let originalMimeType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? "image/png"
            let baseName = "l2p_\(UUID().uuidString.prefix(8))"
            
            // 2. 统一转 JPEG：非 JPEG 格式（WebP/PNG/HEIC 等）全部转换，避免兼容性问题
            let (data, mimeType) = normalizeToJPEG(data: rawData, originalMimeType: originalMimeType)
            
            print("[ImageUploader] 已下载数据 (\(rawData.count / 1024) KB → \(data.count / 1024) KB \(mimeType)), 准备上传...")

            let payload = try preparePayload(
                data: data,
                sourceURL: imageURL,
                behavior: behavior,
                suggestedBaseName: baseName,
                originalMimeType: mimeType
            )
            
            // 2. 执行上传 (传入进度回调)
            return try await performUpload(
                data: payload.data,
                filename: payload.filename,
                mimeType: payload.mimeType,
                onProgress: onProgress
            )
        } catch {
            print("[ImageUploader] ❌ 图片下载/处理阶段失败: \(url), 错误: \(error.localizedDescription)")
            throw error
        }
    }

    private static func preparePayload(
        data: Data,
        sourceURL: URL,
        behavior: UploadBehavior,
        suggestedBaseName: String,
        originalMimeType: String
    ) throws -> PreparedUploadPayload {
        guard data.count > uploadLimitBytes else {
            return PreparedUploadPayload(
                data: data,
                filename: "\(suggestedBaseName).\(fileExtension(for: originalMimeType, sourceURL: sourceURL))",
                mimeType: originalMimeType
            )
        }

        let summary = OversizedImageSummary(
            sourceURL: sourceURL.absoluteString,
            byteCount: data.count,
            uploadLimitBytes: uploadLimitBytes
        )

        switch behavior {
        case .direct:
            throw UploadError.uploadRejected(statusCode: 413, description: "原图超过 5 MB 上传限制")
        case .askBeforeCompressing:
            throw UploadError.oversizedImageRequiresCompression(summary)
        case .compressOversizedImages:
            return try compressPayload(
                data: data,
                sourceURL: sourceURL,
                suggestedBaseName: suggestedBaseName,
                originalMimeType: originalMimeType
            )
        }
    }

    private static func compressPayload(
        data: Data,
        sourceURL: URL,
        suggestedBaseName: String,
        originalMimeType: String
    ) throws -> PreparedUploadPayload {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lark2pad-upload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        let inputExtension = fileExtension(for: originalMimeType, sourceURL: sourceURL)
        let inputURL = tempDirectory.appendingPathComponent("source.\(inputExtension)")
        try data.write(to: inputURL, options: .atomic)

        let options = ImageCompressor.CompressionOptions(
            resizeMode: .none,
            quality: 0.8,
            deleteOriginal: false,
            autoCompressTo5MB: true,
            targetFormat: preferredOutputFormat(for: inputExtension),
            gifFrameRate: nil,
            gifColorDepth: nil,
            gifCompressionPriority: nil
        )

        let compressedURL: URL
        do {
            compressedURL = try ImageCompressor.compress(inputURL: inputURL, options: options)
        } catch {
            throw UploadError.automaticCompressionFailed(description: error.localizedDescription)
        }

        let compressedData: Data
        do {
            compressedData = try Data(contentsOf: compressedURL)
        } catch {
            throw UploadError.automaticCompressionFailed(description: "无法读取压缩结果")
        }

        guard compressedData.count <= uploadLimitBytes else {
            throw UploadError.automaticCompressionFailed(description: "自动压缩后仍超过 5 MB 限制")
        }

        let outputExtension = compressedURL.pathExtension.isEmpty ? inputExtension : compressedURL.pathExtension.lowercased()
        let outputMimeType = mimeType(for: outputExtension, fallback: originalMimeType)
        print("[ImageUploader] ✅ 自动压缩完成: \(data.count / 1024) KB → \(compressedData.count / 1024) KB")

        return PreparedUploadPayload(
            data: compressedData,
            filename: "\(suggestedBaseName).\(outputExtension)",
            mimeType: outputMimeType
        )
    }
    
    /// 执行具体的 API 上传行为
    private static func performUpload(data: Data, 
                                     filename: String, 
                                     mimeType: String, 
                                     retryCount: Int = 0,
                                     onProgress: @escaping (Double, String) -> Void) async throws -> String {
        let sanitizedName = sanitizeFilename(filename)
        let maxRetries = 2
        let cookies = CookieManager.shared.cookieHeaderValue
        let padId = SecureRuntimeConfig.padIdentifier
        let endpoint = SecureRuntimeConfig.uploadEndpoint(for: padId)
        guard let url = URL(string: endpoint) else {
            throw UploadError.invalidUploadResponse(description: "上传地址无效")
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue(SecureRuntimeConfig.etherpadBaseURL, forHTTPHeaderField: "Origin")
        request.setValue("\(SecureRuntimeConfig.etherpadBaseURL)/p/\(padId)", forHTTPHeaderField: "Referer")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        
        if !cookies.isEmpty {
            request.setValue(cookies, forHTTPHeaderField: "Cookie")
        }
        
        let boundary = "----WebKitFormBoundary\(UUID().uuidString.prefix(16).lowercased())"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(sanitizedName)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        
        // 使用 Delegate 追踪进度
        let delegate = UploadProgressDelegate()
        delegate.onProgress = { sent, total in
            guard total > 0 else { return }
            let fraction = Double(sent) / Double(total)
            let speed = delegate.calculateSpeed(sent: sent)
            onProgress(fraction, speed)
        }
        
        do {
            let (responseData, response) = try await session.upload(for: request, from: body, delegate: delegate)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let responseString = String(data: responseData, encoding: .utf8) ?? "空响应"
            
            if statusCode == 200 || statusCode == 201 {
                if let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                   let resultUrl = json["url"] as? String {
                    print("[ImageUploader] ✅ 上传成功 (JSON): \(resultUrl)")
                    ImageGalleryStore.shared.recordUpload(
                        url: resultUrl,
                        filename: sanitizedName,
                        mimeType: mimeType,
                        byteCount: data.count
                    )
                    return resultUrl
                }
                
                var finalUrl = responseString.trimmingCharacters(in: .whitespacesAndNewlines)
                if finalUrl.hasPrefix("\"") && finalUrl.hasSuffix("\"") {
                    finalUrl = String(finalUrl.dropFirst().dropLast())
                }
                
                if finalUrl.hasPrefix("http") {
                    print("[ImageUploader] ✅ 上传成功 (String): \(finalUrl)")
                    ImageGalleryStore.shared.recordUpload(
                        url: finalUrl,
                        filename: sanitizedName,
                        mimeType: mimeType,
                        byteCount: data.count
                    )
                    return finalUrl
                }
                throw UploadError.invalidUploadResponse(description: responseString)
            } else {
                print("[ImageUploader] ❌ 服务器拒绝 (\(statusCode)): \(responseString)")
                throw UploadError.uploadRejected(statusCode: statusCode, description: responseString)
            }
        } catch {
            print("[ImageUploader] ⚠️ 上传阶段网络错误 (重试 \(retryCount)/\(maxRetries)): \(error.localizedDescription)")
            if retryCount < maxRetries, shouldRetry(for: error) {
                try? await Task.sleep(for: .seconds(Double(retryCount + 1) * 2.0))
                return try await performUpload(data: data, filename: filename, mimeType: mimeType, retryCount: retryCount + 1, onProgress: onProgress)
            } else {
                throw error
            }
        }
    }

    private static func shouldRetry(for error: Error) -> Bool {
        if let uploadError = error as? UploadError {
            switch uploadError {
            case .oversizedImageRequiresCompression, .automaticCompressionFailed, .uploadRejected, .invalidUploadResponse:
                return false
            }
        }
        return true
    }

    private static func preferredOutputFormat(for fileExtension: String) -> UTType {
        switch fileExtension.lowercased() {
        case "jpg", "jpeg":
            return .jpeg
        case "png":
            return .png
        case "gif":
            return .gif
        case "webp":
            return .webP
        case "heic", "heif":
            return .heic
        case "tif", "tiff":
            return .tiff
        default:
            return .jpeg
        }
    }

    private static func fileExtension(for mimeType: String, sourceURL: URL) -> String {
        if mimeType.contains("jpeg") { return "jpg" }
        if mimeType.contains("gif") { return "gif" }
        if mimeType.contains("webp") { return "webp" }
        if mimeType.contains("heic") || mimeType.contains("heif") { return "heic" }
        if mimeType.contains("tiff") { return "tiff" }
        if mimeType.contains("png") { return "png" }

        let ext = sourceURL.pathExtension.lowercased()
        return ext.isEmpty ? "png" : ext
    }

    private static func mimeType(for fileExtension: String, fallback: String) -> String {
        switch fileExtension.lowercased() {
        case "jpg", "jpeg":
            return "image/jpeg"
        case "gif":
            return "image/gif"
        case "webp":
            return "image/webp"
        case "heic", "heif":
            return "image/heic"
        case "tif", "tiff":
            return "image/tiff"
        case "png":
            return "image/png"
        default:
            return fallback
        }
    }
    
    /// 将非 JPEG 图片统一转换为 JPEG 格式，确保上传兼容性
    /// - Returns: (转换后的数据, MIME 类型)
    private static func normalizeToJPEG(data: Data, originalMimeType: String) -> (Data, String) {
        // 已经是 JPEG 的直接返回
        if originalMimeType.contains("jpeg") || originalMimeType.contains("jpg") {
            return (data, originalMimeType)
        }
        
        // GIF 保留原格式（动图）
        if originalMimeType.contains("gif") {
            return (data, originalMimeType)
        }
        
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            print("[ImageUploader] ⚠️ 无法解码图片，保留原格式上传")
            return (data, originalMimeType)
        }
        
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutableData, UTType.jpeg.identifier as CFString, 1, nil
        ) else {
            print("[ImageUploader] ⚠️ 无法创建 JPEG 编码器，保留原格式上传")
            return (data, originalMimeType)
        }
        
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.85
        ]
        CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)
        
        guard CGImageDestinationFinalize(destination) else {
            print("[ImageUploader] ⚠️ JPEG 编码失败，保留原格式上传")
            return (data, originalMimeType)
        }
        
        let jpegData = mutableData as Data
        print("[ImageUploader] 🔄 \(originalMimeType) → image/jpeg (\(data.count / 1024) KB → \(jpegData.count / 1024) KB)")
        return (jpegData, "image/jpeg")
    }
    
    static func sanitizeFilename(_ filename: String) -> String {
        let parts = filename.components(separatedBy: ".")
        guard parts.count > 0 else {
            return "l2p_\(UUID().uuidString.prefix(8)).png"
        }
        
        let ext = parts.last?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "png"
        let nameWithoutExt = parts.dropLast().joined(separator: "_")
        
        // 过滤主文件名：只允许英文字母、数字、dash(-)、underscore(_)
        let namePattern = "[^a-zA-Z0-9_-]"
        var cleanName = nameWithoutExt.replacingOccurrences(of: namePattern, with: "", options: .regularExpression)
        if cleanName.isEmpty {
            cleanName = "l2p_\(UUID().uuidString.prefix(8))"
        }
        
        // 过滤扩展名：只允许英文字母、数字
        let extPattern = "[^a-zA-Z0-9]"
        var cleanExt = ext.replacingOccurrences(of: extPattern, with: "", options: .regularExpression)
        
        let allowedExtensions = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff"]
        if cleanExt.isEmpty || !allowedExtensions.contains(cleanExt) {
            cleanExt = "png"
        }
        
        return "\(cleanName).\(cleanExt)"
    }
}

/// 内部 Delegate 用于捕获上传进度
private class UploadProgressDelegate: NSObject, URLSessionTaskDelegate {
    var onProgress: ((Int64, Int64) -> Void)?
    private let startTime = Date()
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        onProgress?(totalBytesSent, totalBytesExpectedToSend)
    }
    
    /// 计算并格式化当前网速
    func calculateSpeed(sent: Int64) -> String {
        let elapsed = Date().timeIntervalSince(startTime)
        guard elapsed > 0 else { return "0 B/s" }
        
        let bytesPerSec = Double(sent) / elapsed
        
        if bytesPerSec >= 1024 * 1024 {
            return String(format: "%.1f MB/s", bytesPerSec / (1024 * 1024))
        }
        
        if bytesPerSec >= 1024 {
            return String(format: "%.1f KB/s", bytesPerSec / 1024)
        }
        
        return "\(Int(bytesPerSec)) B/s"
    }
}

private actor UploadProgressTracker {
    private let total: Int
    private var fractions: [Double]
    private var activePositions: Set<Int> = []
    private var completedPositions: Set<Int> = []
    private var latestSpeed = "准备中..."

    init(total: Int) {
        self.total = total
        self.fractions = Array(repeating: 0, count: total)
    }

    func snapshot() -> ImageUploader.UploadBatchProgress {
        buildSnapshot()
    }

    func markStarted(position: Int) -> ImageUploader.UploadBatchProgress {
        activePositions.insert(position)
        return buildSnapshot()
    }

    func update(position: Int, fraction: Double, speed: String) -> ImageUploader.UploadBatchProgress {
        guard fractions.indices.contains(position) else {
            return buildSnapshot()
        }

        activePositions.insert(position)
        fractions[position] = max(fractions[position], min(max(fraction, 0), 1))
        if !speed.isEmpty {
            latestSpeed = "\(activePositions.count) 路并发 · \(speed)"
        }
        return buildSnapshot()
    }

    func markFinished(position: Int) -> ImageUploader.UploadBatchProgress {
        if fractions.indices.contains(position) {
            fractions[position] = 1
        }
        activePositions.remove(position)
        completedPositions.insert(position)
        latestSpeed = activePositions.isEmpty ? "已完成" : latestSpeed
        return buildSnapshot()
    }

    private func buildSnapshot() -> ImageUploader.UploadBatchProgress {
        let overall = total == 0 ? 1 : fractions.reduce(0, +) / Double(total)
        return ImageUploader.UploadBatchProgress(
            completed: completedPositions.count,
            total: total,
            overallFraction: min(max(overall, 0), 1),
            activeUploads: activePositions.count,
            speedMessage: latestSpeed
        )
    }
}
