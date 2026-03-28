import Foundation

/// 处理飞书图片下载并自动上传到公司私有图床的工具类
@MainActor
final class ImageUploader {
    
    // MARK: - 配置信息 (请在此根据 ifanr 图床 API 进行调整)
    
    /// 图床 API 端点 (占位符)
    private static let uploadEndpoint = "https://api.ifanr.com/v1/file/upload/"
    
    /// 认证 Token (占位符)
    private static let apiToken = "YOUR_COMPANY_TOKEN_HERE"
    
    /// 批量处理图片：下载飞书临时图片并上传至私有图床
    static func uploadAll(images: [(id: Int, url: String)]) async -> [(id: Int, base64: String)] {
        if images.isEmpty { return [] }
        
        print("[ImageUploader] 开始串行处理 \(images.count) 张图片，以确保稳定性...")
        var results: [(id: Int, base64: String)] = []
        
        // 彻底改为串行，避免任何并发带来的网络压力或代理冲突
        for item in images {
            print("[ImageUploader] 正在处理图片: \(item.id)")
            if let newURL = await uploadSingleImage(url: item.url) {
                results.append((id: item.id, base64: newURL))
            }
            // 每张图之间给一点缓冲
            try? await Task.sleep(for: .milliseconds(500))
        }
        
        print("[ImageUploader] 最终成功上传 \(results.count) / \(images.count) 张图片")
        return results
    }
    
    // MARK: - 私有方法
    
    private static func uploadSingleImage(url: String) async -> String? {
        guard let imageURL = URL(string: url) else { return nil }
        
        do {
            // 1. 下载图片数据
            let (data, response) = try await URLSession.shared.data(from: imageURL)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard statusCode == 200 else { return nil }
            
            // 获取真实 MIME 类型
            let mimeType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? "image/png"
            let ext = mimeType.contains("jpeg") ? "jpg" : (mimeType.contains("gif") ? "gif" : (mimeType.contains("webp") ? "webp" : "png"))
            let finalFilename = "l2p_\(UUID().uuidString.prefix(8)).\(ext)"
            
            // 2. 执行上传
            return try await performUpload(data: data, filename: finalFilename, mimeType: mimeType)
        } catch {
            print("[ImageUploader] ❌ 下载失败: \(url), 错误: \(error.localizedDescription)")
            return nil
        }
    }
    
    /// 执行具体的 API 上传行为
    private static func performUpload(data: Data, filename: String, mimeType: String, retryCount: Int = 0) async throws -> String? {
        let maxRetries = 2
        
        // 关键安全原则：所有 ifanr 相关的凭据必须保存在本地，
        // 我们通过 CookieManager 从 WebView 提取并存储在 UserDefaults 中，
        // 禁止在此处硬编码任何真实 Token 或将其上传至代码仓库。
        let cookies = CookieManager.shared.cookieHeaderValue
        
        // 使用明确存在的路径，或者随机的一个符合规范的 padId
        let padId = "lark2pad_upload"
        let endpoint = "https://pad.corp.ifanr.com/p/\(padId)/pluginfw/ep_image_upload/upload"
        guard let url = URL(string: endpoint) else { return nil }
        
        // 使用专用配置，限制并发并延长超时
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 1
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        let session = URLSession(configuration: config)
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        
        // 彻底模拟浏览器头部
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("https://pad.corp.ifanr.com", forHTTPHeaderField: "Origin")
        request.setValue("https://pad.corp.ifanr.com/p/\(padId)", forHTTPHeaderField: "Referer")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue("application/json, text/javascript, */*; q=0.01", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        request.setValue("keep-alive", forHTTPHeaderField: "Connection")
        
        if !cookies.isEmpty {
            request.setValue(cookies, forHTTPHeaderField: "Cookie")
        }
        
        let boundary = "----WebKitFormBoundary\(UUID().uuidString.prefix(16).lowercased())"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        // 精确构建 Multipart 报文 (严格遵循浏览器行为)
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!) // 部分服务器要求结尾也有 CRLF
        
        request.httpBody = body
        request.setValue("\(body.count)", forHTTPHeaderField: "Content-Length")
        
        do {
            let (responseData, response) = try await session.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let responseString = String(data: responseData, encoding: .utf8) ?? "空响应"
            
            if statusCode == 200 || statusCode == 201 {
                // 1. 尝试解析为 JSON 字典 (如果有 {"url": "..."})
                if let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                   let resultUrl = json["url"] as? String {
                    print("[ImageUploader] ✅ 上传成功 (JSON): \(resultUrl)")
                    return resultUrl
                }
                
                // 2. 尝试解析为带引号的纯字符串 (如 "https://...")
                var finalUrl = responseString.trimmingCharacters(in: .whitespacesAndNewlines)
                if finalUrl.hasPrefix("\"") && finalUrl.hasSuffix("\"") {
                    finalUrl = String(finalUrl.dropFirst().dropLast())
                }
                
                if finalUrl.hasPrefix("http") {
                    print("[ImageUploader] ✅ 上传成功 (String): \(finalUrl)")
                    return finalUrl
                }
                
                print("[ImageUploader] ⚠️ 响应结构不支持: \(responseString)")
            } else {
                print("[ImageUploader] ❌ 服务器拒绝 (\(statusCode)): \(responseString)")
            }
        } catch {
            print("[ImageUploader] ⚠️ 网络错误 (重试 \(retryCount)/\(maxRetries)): \(error.localizedDescription)")
            if retryCount < maxRetries {
                try? await Task.sleep(for: .seconds(3))
                return try await performUpload(data: data, filename: filename, mimeType: mimeType, retryCount: retryCount + 1)
            }
        }
        
        return nil
    }
}
