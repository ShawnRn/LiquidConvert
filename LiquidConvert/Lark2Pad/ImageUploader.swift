import Foundation

/// 处理飞书图片下载并自动上传到公司私有图床的工具类
@MainActor
final class ImageUploader {
    
    // MARK: - 配置信息
    
    /// 共享的 URLSession，开启连接复用 (Keep-Alive)
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 1
        config.timeoutIntervalForRequest = 180 // 针对大图进一步放宽请求超时
        config.timeoutIntervalForResource = 300
        return URLSession(configuration: config)
    }()
    
    /// 批量处理图片：下载飞书临时图片并上传至私有图床输出进度
    /// 回调参数：(当前索引, 当前文件进度0-1, 实时速度字符串)
    static func uploadAll(images: [(id: Int, url: String)], 
                        progress: ((Int, Double, String) -> Void)? = nil) async throws -> [(id: Int, base64: String)] {
        if images.isEmpty { return [] }
        
        print("[ImageUploader] 开始串行处理 \(images.count) 张图片，并启用实时进度监控...")
        var results: [(id: Int, base64: String)] = []
        
        for (index, item) in images.enumerated() {
            // 初始化当前图片的进度
            progress?(index + 1, 0.0, "准备中...")
            
            print("[ImageUploader] 正在处理第 \(index + 1)/\(images.count) 张图片: \(item.id)")
            
            if let newURL = try await uploadSingleImage(url: item.url, onProgress: { fileProgress, speed in
                progress?(index + 1, fileProgress, speed)
            }) {
                results.append((id: item.id, base64: newURL))
            }
            
            try? await Task.sleep(for: .milliseconds(300))
        }
        
        print("[ImageUploader] 最终成功上传 \(results.count) / \(images.count) 张图片")
        return results
    }
    
    // MARK: - 私有方法
    
    private static func uploadSingleImage(url: String, onProgress: @escaping (Double, String) -> Void) async throws -> String? {
        guard let imageURL = URL(string: url) else { return nil }
        
        do {
            // 1. 下载图片数据
            let (data, response) = try await session.data(from: imageURL)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard statusCode == 200 else { 
                print("[ImageUploader] ❌ 下载失败: \(url), 状态码: \(statusCode)")
                return nil 
            }
            
            let mimeType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? "image/png"
            let ext = mimeType.contains("jpeg") ? "jpg" : (mimeType.contains("gif") ? "gif" : (mimeType.contains("webp") ? "webp" : "png"))
            let finalFilename = "l2p_\(UUID().uuidString.prefix(8)).\(ext)"
            
            print("[ImageUploader] 已下载数据 (\(data.count / 1024) KB), 准备上传...")
            
            // 2. 执行上传 (传入进度回调)
            return try await performUpload(data: data, filename: finalFilename, mimeType: mimeType, onProgress: onProgress)
        } catch {
            print("[ImageUploader] ❌ 图片下载/处理阶段失败: \(url), 错误: \(error.localizedDescription)")
            throw error
        }
    }
    
    /// 执行具体的 API 上传行为
    private static func performUpload(data: Data, 
                                     filename: String, 
                                     mimeType: String, 
                                     retryCount: Int = 0,
                                     onProgress: @escaping (Double, String) -> Void) async throws -> String? {
        let maxRetries = 2
        let cookies = CookieManager.shared.cookieHeaderValue
        let padId = SecureRuntimeConfig.padIdentifier
        let endpoint = SecureRuntimeConfig.uploadEndpoint(for: padId)
        guard let url = URL(string: endpoint) else { return nil }
        
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
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
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
                        filename: filename,
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
                        filename: filename,
                        mimeType: mimeType,
                        byteCount: data.count
                    )
                    return finalUrl
                }
                return nil
            } else {
                print("[ImageUploader] ❌ 服务器拒绝 (\(statusCode)): \(responseString)")
                return nil
            }
        } catch {
            print("[ImageUploader] ⚠️ 上传阶段网络错误 (重试 \(retryCount)/\(maxRetries)): \(error.localizedDescription)")
            if retryCount < maxRetries {
                try? await Task.sleep(for: .seconds(Double(retryCount + 1) * 2.0))
                return try await performUpload(data: data, filename: filename, mimeType: mimeType, retryCount: retryCount + 1, onProgress: onProgress)
            } else {
                throw error
            }
        }
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
