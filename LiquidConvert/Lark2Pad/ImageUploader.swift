import Foundation
import UniformTypeIdentifiers
import ImageIO
import CoreGraphics
import SwiftUI

/// 处理飞书图片下载并自动上传到公司私有图床的工具类
final class ImageUploader {
    /// 静态内存缓存，用于避免在转换出错重试时重复下载和上传相同的图片
    private static let cacheLock = NSLock()
    private static var uploadedCache: [String: String] = [:]
    private static var dataURICache: [String: String] = [:]
    
    private static func getCachedURL(for url: String) -> String? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return uploadedCache[url]
    }
    
    private static func setCachedURL(_ uploadedURL: String, for url: String) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        uploadedCache[url] = uploadedURL
    }

    private static func getCachedDataURI(for url: String) -> String? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return dataURICache[url]
    }

    private static func setCachedDataURI(_ dataURI: String, for urls: String...) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        for u in urls {
            if !u.isEmpty {
                dataURICache[u] = dataURI
            }
        }
    }

    /// 将 HTML 中的图床 URL 替换为存储在内存缓存中的 Base64 Data URI（仅供复制到公众号使用，不影响 Pad 发送）
    static func convertImageURLsToBase64DataURIs(in html: String) -> String {
        cacheLock.lock()
        let mapping = dataURICache
        cacheLock.unlock()
        
        var result = html
        for (url, dataURI) in mapping {
            if !url.isEmpty && !dataURI.isEmpty {
                result = result.replacingOccurrences(of: url, with: dataURI)
            }
        }
        return result
    }
    
    /// 强支持 100% 写入剪贴板：异步确保 HTML 中所有非 data: 的 <img> src 均在第一时间补齐并转为 Base64 Data URI
    static func convertImageURLsToBase64DataURIsAsync(in html: String) async -> String {
        var result = await MainActor.run { convertImageURLsToBase64DataURIs(in: html) }
        
        let pattern = #"<img\b[^>]*?\bsrc=["'](https?://[^"']+)["']"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return result
        }
        
        let nsString = result as NSString
        let matches = regex.matches(in: result, options: [], range: NSRange(location: 0, length: nsString.length))
        
        var urlsToFetch: Set<String> = []
        for match in matches {
            if match.numberOfRanges > 1 {
                let urlStr = nsString.substring(with: match.range(at: 1))
                let cached = await MainActor.run { getCachedDataURI(for: urlStr) }
                if cached == nil {
                    urlsToFetch.insert(urlStr)
                }
            }
        }
        
        if urlsToFetch.isEmpty {
            return result
        }
        
        await withTaskGroup(of: (String, String?).self) { group in
            for urlStr in urlsToFetch {
                group.addTask {
                    guard let url = URL(string: urlStr),
                          let (data, response) = try? await session.data(from: url),
                          (response as? HTTPURLResponse)?.statusCode == 200 else {
                        return (urlStr, nil)
                    }
                    let mime = response.mimeType ?? "image/png"
                    let validMime = mime.contains("image") ? mime : "image/png"
                    let base64 = data.base64EncodedString()
                    let dataURI = "data:\(validMime);base64,\(base64)"
                    return (urlStr, dataURI)
                }
            }
            
            for await (urlStr, dataURI) in group {
                if let dataURI {
                    await MainActor.run { setCachedDataURI(dataURI, for: urlStr) }
                    result = result.replacingOccurrences(of: urlStr, with: dataURI)
                }
            }
        }
        
        return result
    }
    
    private struct DownloadResult: Sendable {
        let data: Data
        let statusCode: Int
        let mimeType: String
    }

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
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 90
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
                            if let snapshot = await tracker.update(position: position, fraction: fileProgress, speed: speed) {
                                await MainActor.run { progress?(snapshot) }
                            }
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
        // 优先检查静态缓存，实现秒传，防止由于个别图片失败重试时导致全部图片重头下载上传
        if let cachedURL = getCachedURL(for: url) {
            print("[ImageUploader] ⚡️ 命中图片上传缓存: \(url) -> \(cachedURL)")
            onProgress(1.0, "已缓存")
            return cachedURL
        }

        guard let imageURL = URL(string: url) else {
            throw UploadError.invalidUploadResponse(description: "无效图片地址")
        }
        
        do {
            // 1. 下载图片数据 (引入 withTimeout 45秒限时保护，防止下载在 data_stall 网络环境下挂死)
            let downloadResult = try await withTimeout(seconds: 45.0) {
                let (rawData, response) = try await session.data(from: imageURL)
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                let mimeType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? "image/png"
                return DownloadResult(data: rawData, statusCode: statusCode, mimeType: mimeType)
            }
            
            guard downloadResult.statusCode == 200 else { 
                print("[ImageUploader] ❌ 下载失败: \(url), 状态码: \(downloadResult.statusCode)")
                throw UploadError.uploadRejected(statusCode: downloadResult.statusCode, description: "原图下载失败") 
            }
            
            let rawData = downloadResult.data
            let originalMimeType = downloadResult.mimeType
            let baseName = "l2p_\(UUID().uuidString.prefix(8))"
            
            // 2. 处理图片并应用贝塞尔曲线圆角（对于静态图），并统一输出为 PNG 以支持透明底色
            let (data, mimeType) = processAndApplyContinuousCorners(data: rawData, originalMimeType: originalMimeType)
            
            print("[ImageUploader] 已下载数据 (\(rawData.count / 1024) KB → \(data.count / 1024) KB \(mimeType)), 准备上传...")

            let payload = try preparePayload(
                data: data,
                sourceURL: imageURL,
                behavior: behavior,
                suggestedBaseName: baseName,
                originalMimeType: mimeType
            )
            
            // 2. 执行上传 (传入进度回调)
            let uploadedURL = try await performUpload(
                data: payload.data,
                filename: payload.filename,
                mimeType: payload.mimeType,
                onProgress: onProgress
            )
            let dataURI = "data:\(payload.mimeType);base64,\(payload.data.base64EncodedString())"
            setCachedURL(uploadedURL, for: url)
            setCachedDataURI(dataURI, for: url, uploadedURL)
            return uploadedURL
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
            targetFormat: originalMimeType.contains("gif") ? .gif : .jpeg,
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
            let responseString = try await withTimeout(seconds: 60.0) {
                let (responseData, response) = try await session.upload(for: request, from: body, delegate: delegate)
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                let responseStr = String(data: responseData, encoding: .utf8) ?? "空响应"
                
                guard statusCode == 200 || statusCode == 201 else {
                    print("[ImageUploader] ❌ 服务器拒绝 (\(statusCode)): \(responseStr)")
                    throw UploadError.uploadRejected(statusCode: statusCode, description: responseStr)
                }
                return responseStr
            }
            
            if let responseData = responseString.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
               let resultUrl = json["url"] as? String {
                print("[ImageUploader] ✅ 上传成功 (JSON): \(resultUrl)")
                return resultUrl
            }
            
            var finalUrl = responseString.trimmingCharacters(in: .whitespacesAndNewlines)
            if finalUrl.hasPrefix("\"") && finalUrl.hasSuffix("\"") {
                finalUrl = String(finalUrl.dropFirst().dropLast())
            }
            
            if finalUrl.hasPrefix("http") {
                print("[ImageUploader] ✅ 上传成功 (String): \(finalUrl)")
                return finalUrl
            }
            throw UploadError.invalidUploadResponse(description: responseString)
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

    /// 在指定的秒数内执行异步块，如果超时则主动取消并抛出 Timeout 错误，防止 URLSession data_stall 挂起不退出
    private static func withTimeout<T: Sendable>(
        seconds: Double,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw URLError(.timedOut, userInfo: [NSLocalizedDescriptionKey: "请求执行超时（安全限制 \(Int(seconds)) 秒）"])
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
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

    private static var shouldApplyCorners: Bool {
        if UserDefaults.standard.object(forKey: "lark2pad_round_images") == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: "lark2pad_round_images")
    }

    private static func processWithoutCorners(data: Data, originalMimeType: String) -> (Data, String) {
        if originalMimeType.contains("gif") {
            return (data, originalMimeType)
        }
        
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return (data, originalMimeType)
        }
        
        let width = cgImage.width
        let height = cgImage.height
        
        // 限制最大展示宽度在 1280px 以内（按宽度等比例缩放），避免长图高度大导致宽度被过度压缩变模糊
        let maxAllowedWidth: CGFloat = 1280.0
        let needsResize = CGFloat(width) > maxAllowedWidth
        
        let targetWidth: Int
        let targetHeight: Int
        if needsResize {
            let scale = maxAllowedWidth / CGFloat(width)
            targetWidth = Int(maxAllowedWidth)
            targetHeight = Int(CGFloat(height) * scale)
        } else {
            targetWidth = width
            targetHeight = height
        }
        
        // 无论是否缩放，一律重新编码为 JPEG 以确保上传体积可控
        // 对于有 Alpha 通道的图片，填充白色背景后再输出 JPEG
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            return (data, originalMimeType)
        }
        
        // 先填充白色背景（消除 Alpha 透明区域的黑色底色问题）
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        
        // 绘制图片
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        
        guard let resultImage = context.makeImage() else {
            return (data, originalMimeType)
        }
        
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutableData, UTType.jpeg.identifier as CFString, 1, nil
        ) else {
            return (data, originalMimeType)
        }
        
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.85
        ]
        CGImageDestinationAddImage(destination, resultImage, options as CFDictionary)
        
        guard CGImageDestinationFinalize(destination) else {
            return (data, originalMimeType)
        }
        
        if needsResize {
            print("[ImageUploader] 📏 缩放+转 JPEG (不裁剪圆角): \(width)x\(height) -> \(targetWidth)x\(targetHeight), \(data.count / 1024) KB -> \(mutableData.length / 1024) KB")
        } else {
            print("[ImageUploader] 📏 转 JPEG (不裁剪圆角,保持原尺寸): \(width)x\(height), \(data.count / 1024) KB -> \(mutableData.length / 1024) KB")
        }
        return (mutableData as Data, "image/jpeg")
    }
    
    /// 将图片规范化为 PNG 格式（除了 GIF）并添加精细的 iOS 贝塞尔曲线连续圆角（超椭圆）。
    /// 同时根据设计宽度动态调整圆角半径，以确保在文章排版中视觉大小一致。
    private static func processAndApplyContinuousCorners(data: Data, originalMimeType: String) -> (Data, String) {
        // GIF 动图不进行圆角处理以保证动图效果及性能
        if originalMimeType.contains("gif") {
            return (data, originalMimeType)
        }

        // 如果未开启圆角开关，则执行纯分辨率缩放规范化，不进行圆角裁剪
        guard shouldApplyCorners else {
            return processWithoutCorners(data: data, originalMimeType: originalMimeType)
        }

        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            print("[ImageUploader] ⚠️ 无法解码图片，保留原格式上传")
            return (data, originalMimeType)
        }

        let width = cgImage.width
        let height = cgImage.height

        // 限制最大展示宽度在 1280px 以内（按宽度等比例缩放），避免长图因高度较大导致宽度被过度压缩变模糊
        let maxAllowedWidth: CGFloat = 1280.0
        var targetWidth = CGFloat(width)
        var targetHeight = CGFloat(height)
        
        if targetWidth > maxAllowedWidth {
            let scale = maxAllowedWidth / targetWidth
            targetWidth = maxAllowedWidth
            targetHeight = targetHeight * scale
            print("[ImageUploader] 📏 图片宽度超过 1280px，按宽度等比例缩放: \(width)x\(height) -> \(Int(targetWidth))x\(Int(targetHeight))")
        }

        let roundedWidth = Int(targetWidth)
        let roundedHeight = Int(targetHeight)

        // 核心等比圆角计算（几何相似性定理）：
        // 为了让图片在任何终端（手机、电脑）缩放展示时其圆角比例观感都绝对一致，
        // 我们在物理裁剪时让圆角半径与图片的物理宽度保持恒定的 2.0% 比例（即以 800px 宽度视觉圆角 16px 为基准）。
        // 这样无论如何缩放，屏幕上的“圆角/宽度”比率永远是 2.0%，彻底解决大小图及跨端视觉不一致问题。
        let cornerRadius = targetWidth * 0.02

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: roundedWidth,
            height: roundedHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            print("[ImageUploader] ⚠️ 无法创建 CGContext，保留原格式上传")
            return (data, originalMimeType)
        }

        // 在离屏位图上下文中，直接绘制和导出 CGImage，由于没有上层 UI 系统的坐标系变换，因此不需要进行任何 Y 轴镜像翻转。
        // 圆角矩形路径在 (0, 0, W, H) 下对称分布，直接应用即可。

        // 使用 SwiftUI RoundedRectangle(..., style: .continuous) 产生完美的连续贝塞尔圆角
        let rect = CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight)
        let path = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).path(in: rect).cgPath

        context.addPath(path)
        context.clip()

        // 绘制图片
        context.draw(cgImage, in: rect)

        guard let roundedCGImage = context.makeImage() else {
            print("[ImageUploader] ⚠️ 制作圆角 CGImage 失败，保留原格式")
            return (data, originalMimeType)
        }

        // 转换为 PNG（以支持透明度）
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutableData, UTType.png.identifier as CFString, 1, nil
        ) else {
            print("[ImageUploader] ⚠️ 无法创建 PNG 编码器，保留原格式")
            return (data, originalMimeType)
        }

        CGImageDestinationAddImage(destination, roundedCGImage, nil)

        guard CGImageDestinationFinalize(destination) else {
            print("[ImageUploader] ⚠️ 导出为 PNG 失败，保留原格式")
            return (data, originalMimeType)
        }

        let pngData = mutableData as Data
        print("[ImageUploader] 🔄 已成功应用贝塞尔曲线圆角并转换为 PNG (\(data.count / 1024) KB → \(pngData.count / 1024) KB), 圆角半径: \(Int(cornerRadius))px")
        return (pngData, "image/png")
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
private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
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
    private var lastReportTime = Date.distantPast

    init(total: Int) {
        self.total = total
        self.fractions = Array(repeating: 0, count: total)
    }

    func snapshot() -> ImageUploader.UploadBatchProgress {
        buildSnapshot()
    }

    func markStarted(position: Int) -> ImageUploader.UploadBatchProgress {
        activePositions.insert(position)
        lastReportTime = Date()
        return buildSnapshot()
    }

    func update(position: Int, fraction: Double, speed: String) -> ImageUploader.UploadBatchProgress? {
        guard fractions.indices.contains(position), !completedPositions.contains(position) else {
            return nil
        }

        activePositions.insert(position)
        fractions[position] = max(fractions[position], min(max(fraction, 0), 1))
        if !speed.isEmpty {
            latestSpeed = "\(activePositions.count) 路并发 · \(speed)"
        }
        
        let now = Date()
        if now.timeIntervalSince(lastReportTime) >= 0.08 || completedPositions.count == total {
            lastReportTime = now
            return buildSnapshot()
        }
        return nil
    }

    func markFinished(position: Int) -> ImageUploader.UploadBatchProgress {
        if fractions.indices.contains(position) {
            fractions[position] = 1
        }
        activePositions.remove(position)
        completedPositions.insert(position)
        latestSpeed = activePositions.isEmpty ? "已完成" : latestSpeed
        lastReportTime = Date()
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
