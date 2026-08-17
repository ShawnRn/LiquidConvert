import Foundation

enum EtherpadSyncService {
    struct SyncResult: Sendable {
        let padID: String
        let url: URL
        let renamed: Bool
    }

    enum SyncError: LocalizedError {
        case emptyDocument
        case missingSession
        case invalidURL
        case invalidResponse(String)
        case serverRejected(statusCode: Int, message: String)

        var errorDescription: String? {
            switch self {
            case .emptyDocument:
                return "没有可同步的文档内容。"
            case .missingSession:
                return "尚未登录公司 Etherpad，请先完成登录。"
            case .invalidURL:
                return "无法生成 Etherpad 同步地址。"
            case .invalidResponse(let message):
                return "Etherpad 返回了无法识别的响应：\(message)"
            case .serverRejected(let statusCode, let message):
                return "Etherpad 拒绝同步（HTTP \(statusCode)）：\(message)"
            }
        }
    }

    private struct ImportResponse: Decodable {
        let code: Int
        let message: String
    }

    private static let syncedPadIDsKey = "lark2pad_synced_pad_ids"

    static func sync(markdown: String, html: String, preferredPadID: String? = nil) async throws -> SyncResult {
        // 同步必须和“复制 Etherpad 格式”使用同一份导出结果。
        // html 参数保留用于兼容旧调用方，但不再作为第二个内容来源，避免
        // markdown 已更新而传入的 HTML 仍是旧内容，导致两种操作结果不一致。
        _ = html
        let trimmedHTML = EtherpadExporter
            .buildRawHTML(from: markdown)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHTML.isEmpty else {
            throw SyncError.emptyDocument
        }

        let cookies = CookieManager.shared.cookieHeaderValue
        guard CookieManager.shared.hasValidSession, !cookies.isEmpty else {
            throw SyncError.missingSession
        }

        let requestedPadID = preferredPadID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let basePadID = requestedPadID.map(sanitizePadID) ?? suggestedPadID(from: markdown)
        let padID = nextAvailablePadID(basePadID)
        let encodedPadID = try encodedPathComponent(padID)
        guard let importURL = URL(string: "\(SecureRuntimeConfig.etherpadBaseURL)/p/\(encodedPadID)/import"),
              let padURL = URL(string: "\(SecureRuntimeConfig.etherpadBaseURL)/p/\(encodedPadID)") else {
            throw SyncError.invalidURL
        }

        var request = URLRequest(url: importURL)
        request.httpMethod = "POST"
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue(SecureRuntimeConfig.etherpadBaseURL, forHTTPHeaderField: "Origin")
        request.setValue(padURL.absoluteString, forHTTPHeaderField: "Referer")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue(cookies, forHTTPHeaderField: "Cookie")

        let boundary = "----LiquidConvertPadBoundary\(UUID().uuidString.prefix(12))"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let body = multipartBody(
            html: trimmedHTML,
            filename: "\(padID).html",
            boundary: boundary
        )

        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        let responseText = String(data: data, encoding: .utf8) ?? ""

        guard statusCode == 200 || statusCode == 201 else {
            throw SyncError.serverRejected(statusCode: statusCode, message: responseText)
        }

        let importResponse = try? JSONDecoder().decode(ImportResponse.self, from: data)
        guard importResponse?.code == 0 else {
            throw SyncError.invalidResponse(responseText)
        }

        recordSyncedPadID(padID)
        return SyncResult(padID: padID, url: padURL, renamed: padID != basePadID)
    }

    static func suggestedPadID(from markdown: String) -> String {
        let normalized = EtherpadExporter.normalizeMarkdownSpacing(markdown)
        let firstMeaningfulLine = normalized
            .components(separatedBy: .newlines)
            .compactMap { line -> String? in
                let cleaned = cleanTitleLine(line)
                return cleaned.isEmpty ? nil : cleaned
            }
            .first ?? "LiquidConvert_文档"

        return sanitizePadID(firstMeaningfulLine)
    }

    private static func cleanTitleLine(_ line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.replacingOccurrences(of: #"^#{1,6}\s*"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"[*_`~\[\]\(\)]"#, with: "", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func sanitizePadID(_ title: String) -> String {
        var result = title
            .replacingOccurrences(of: #"\s+"#, with: "_", options: .regularExpression)
            .replacingOccurrences(of: #"[\/\\?#%&]+"#, with: "_", options: .regularExpression)
            .replacingOccurrences(of: #"_+"#, with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "._- "))

        if result.isEmpty {
            result = "LiquidConvert_文档"
        }

        return String(result.prefix(80))
    }

    private static func nextAvailablePadID(_ basePadID: String) -> String {
        let usedPadIDs = Set(UserDefaults.standard.stringArray(forKey: syncedPadIDsKey) ?? [])
        guard usedPadIDs.contains(basePadID) else {
            return basePadID
        }

        var index = 1
        while true {
            let candidate = "\(basePadID)(\(index))"
            if !usedPadIDs.contains(candidate) {
                return candidate
            }
            index += 1
        }
    }

    private static func recordSyncedPadID(_ padID: String) {
        var padIDs = UserDefaults.standard.stringArray(forKey: syncedPadIDsKey) ?? []
        guard !padIDs.contains(padID) else { return }
        padIDs.append(padID)
        UserDefaults.standard.set(padIDs, forKey: syncedPadIDsKey)
    }

    private static func encodedPathComponent(_ component: String) throws -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        guard let encoded = component.addingPercentEncoding(withAllowedCharacters: allowed), !encoded.isEmpty else {
            throw SyncError.invalidURL
        }
        return encoded
    }

    struct CMSChannel: Identifiable, Hashable, Sendable {
        let id: String
        let name: String
    }

    static let availableCMSChannels: [CMSChannel] = [
        CMSChannel(id: "ifanr-morning-paper", name: "ifanr 早报"),
        CMSChannel(id: "ifanr", name: "ifanr 推文"),
        CMSChannel(id: "appso-morning-paper", name: "APPSO 早报"),
        CMSChannel(id: "appso", name: "APPSO 推文"),
        CMSChannel(id: "intelligentcar-morning-paper", name: "董车会早报"),
        CMSChannel(id: "intelligentcar", name: "董车会推文"),
        CMSChannel(id: "minapp", name: "知晓云"),
        CMSChannel(id: "wordpress", name: "WordPress")
    ]

    static func sendToCMS(padID: String, channel: String) async throws -> String {
        let cookies = CookieManager.shared.cookieHeaderValue
        guard CookieManager.shared.hasValidSession, !cookies.isEmpty else {
            throw SyncError.missingSession
        }

        let encodedPadID = try encodedPathComponent(padID)
        let encodedChannel = try encodedPathComponent(channel)
        guard let cmsURL = URL(string: "\(SecureRuntimeConfig.etherpadBaseURL)/p/\(encodedPadID)/send2cms/\(encodedChannel)"),
              let padURL = URL(string: "\(SecureRuntimeConfig.etherpadBaseURL)/p/\(encodedPadID)") else {
            throw SyncError.invalidURL
        }

        var request = URLRequest(url: cmsURL)
        request.httpMethod = "POST"
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue(SecureRuntimeConfig.etherpadBaseURL, forHTTPHeaderField: "Origin")
        request.setValue(padURL.absoluteString, forHTTPHeaderField: "Referer")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue(cookies, forHTTPHeaderField: "Cookie")

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        let responseText = String(data: data, encoding: .utf8) ?? ""

        guard statusCode == 200 || statusCode == 201 else {
            throw SyncError.serverRejected(statusCode: statusCode, message: responseText)
        }

        return responseText
    }

    private static func multipartBody(html: String, filename: String, boundary: String) -> Data {
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: text/html; charset=utf-8\r\n\r\n".data(using: .utf8)!)
        body.append(html.data(using: .utf8) ?? Data())
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        return body
    }
}
