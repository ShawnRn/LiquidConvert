import AppKit
import Combine
import Foundation
import OSLog
import UniformTypeIdentifiers
import WebKit

struct WordPressMediaItem: Identifiable, Hashable {
    let id: Int
    let title: String
    let filename: String
    let mimeType: String
    let originalURL: URL?
    let thumbnailURL: URL?
    let width: Int?
    let height: Int?
    let createdAt: String?
}

@MainActor
final class WordPressMediaLibraryStore: ObservableObject {
    static let shared = WordPressMediaLibraryStore()

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "LiquidConvert",
        category: "WordPressGallery"
    )

    @Published private(set) var items: [WordPressMediaItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingNextPage = false
    @Published private(set) var hasMorePages = true
    @Published private(set) var currentPage = 0
    @Published var errorMessage: String?
    @Published private(set) var lastLoadedURL: String = ""

    private let defaultPageSize = 80

    private init() {}

    func refresh(using webView: WKWebView, pageSize: Int = 80) async {
        guard !isLoading else { return }

        isLoading = true
        errorMessage = nil
        currentPage = 0
        hasMorePages = true

        do {
            await WordPressCookieManager.shared.syncFrom(webView: webView)
            let loadedItems = try await loadPage(page: 1, pageSize: pageSize, reset: true)
            logger.info("Loaded \(loadedItems.count, privacy: .public) media items on first page")
        } catch {
            errorMessage = "图库数据加载失败：\(error.localizedDescription)"
            logger.error("Gallery refresh failed: \(error.localizedDescription, privacy: .public)")
        }

        isLoading = false
    }

    func loadNextPage(pageSize: Int? = nil) async {
        guard !isLoading,
              !isLoadingNextPage,
              hasMorePages,
              currentPage > 0 else { return }

        isLoadingNextPage = true
        defer { isLoadingNextPage = false }

        do {
            let nextPage = currentPage + 1
            let loadedItems = try await loadPage(page: nextPage, pageSize: pageSize ?? defaultPageSize, reset: false)
            logger.info("Loaded page \(nextPage, privacy: .public) with \(loadedItems.count, privacy: .public) media items")
        } catch {
            errorMessage = "图库数据加载失败：\(error.localizedDescription)"
            logger.error("Gallery next-page load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func loadPage(page: Int, pageSize: Int, reset: Bool) async throws -> [WordPressMediaItem] {
        let (data, response) = try await requestMediaPage(page: page, pageSize: pageSize)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw WordPressMediaLibraryError.invalidResponse
        }

        let status = httpResponse.statusCode
        let body = String(data: data, encoding: .utf8) ?? ""
        lastLoadedURL = httpResponse.url?.absoluteString ?? SecureRuntimeConfig.wordPressMediaURL

        let bodyPreview = String(body.prefix(240)).replacingOccurrences(of: "\n", with: " ")
        logger.info("status=\(status, privacy: .public), page=\(page, privacy: .public), url=\(self.lastLoadedURL, privacy: .public), preview=\(bodyPreview, privacy: .public)")

        guard status == 200 else {
            throw WordPressMediaLibraryError.httpStatus(status)
        }

        let fetchedItems = try parseItems(from: body)
        currentPage = page
        hasMorePages = fetchedItems.count >= pageSize

        if reset {
            items = fetchedItems
        } else {
            var seen = Set(items.map(\.id))
            let appended = fetchedItems.filter { seen.insert($0.id).inserted }
            items.append(contentsOf: appended)
        }

        return fetchedItems
    }

    private func requestMediaPage(page: Int, pageSize: Int) async throws -> (Data, URLResponse) {
        guard let url = URL(string: SecureRuntimeConfig.wordPressAjaxURL) else {
            throw WordPressMediaLibraryError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = requestBody(page: page, pageSize: pageSize)
        request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue("application/json, text/javascript, */*; q=0.01", forHTTPHeaderField: "Accept")
        request.setValue(SecureRuntimeConfig.wordPressMediaURL, forHTTPHeaderField: "Referer")
        request.setValue(SecureRuntimeConfig.ifanrOriginURL, forHTTPHeaderField: "Origin")

        let cookieHeader = WordPressCookieManager.shared.cookieHeaderValue
        if !cookieHeader.isEmpty {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.timeoutIntervalForRequest = 30

        let session = URLSession(
            configuration: configuration,
            delegate: WordPressAuthenticatedSessionDelegate(),
            delegateQueue: nil
        )
        defer {
            session.finishTasksAndInvalidate()
        }

        return try await session.data(for: request)
    }

    private func requestBody(page: Int, pageSize: Int) -> Data {
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "action", value: "query-attachments"),
            URLQueryItem(name: "post_id", value: "0"),
            URLQueryItem(name: "query[post_mime_type]", value: "image"),
            URLQueryItem(name: "query[posts_per_page]", value: String(pageSize)),
            URLQueryItem(name: "query[paged]", value: String(page)),
            URLQueryItem(name: "query[orderby]", value: "date"),
            URLQueryItem(name: "query[order]", value: "DESC")
        ]

        return Data((components.percentEncodedQuery ?? "").utf8)
    }

    func dragProvider(for item: WordPressMediaItem) -> NSItemProvider {
        if let originalURL = item.originalURL {
            let provider = NSItemProvider(object: originalURL as NSURL)
            provider.suggestedName = item.filename

            let contentType = UTType(mimeType: item.mimeType) ?? .image
            provider.registerDataRepresentation(forTypeIdentifier: contentType.identifier, visibility: .all) { completion in
                Task {
                    do {
                        let (data, _) = try await URLSession.shared.data(from: originalURL)
                        completion(data, nil)
                    } catch {
                        completion(nil, error)
                    }
                }
                return nil
            }

            return provider
        }

        return NSItemProvider(object: item.title as NSString)
    }

    private func parseItems(from body: String) throws -> [WordPressMediaItem] {
        let data = Data(body.utf8)
        let jsonObject = try JSONSerialization.jsonObject(with: data)

        let rawItems: [[String: Any]]
        if let array = jsonObject as? [[String: Any]] {
            rawItems = array
        } else if let payload = jsonObject as? [String: Any],
                  let dataArray = payload["data"] as? [[String: Any]] {
            rawItems = dataArray
        } else {
            throw WordPressMediaLibraryError.invalidPayload
        }

        return rawItems.compactMap { raw in
            let id = raw["id"] as? Int ?? raw["ID"] as? Int ?? -1
            guard id >= 0 else { return nil }

            let title = stringValue(raw["title"])
                ?? nestedString(raw["title"], key: "rendered")
                ?? nestedString(raw["caption"], key: "rendered")
                ?? "未命名图片"

            let originalString = stringValue(raw["url"])
                ?? stringValue(raw["source_url"])
                ?? nestedString(raw["guid"], key: "rendered")

            let sizes = raw["sizes"] as? [String: Any]
            let thumbnailString = nestedString(sizes?["medium_large"], key: "url")
                ?? nestedString(sizes?["medium"], key: "url")
                ?? nestedString(sizes?["thumbnail"], key: "url")
                ?? nestedString(sizes?["full"], key: "url")
                ?? originalString

            let filename = stringValue(raw["filename"])
                ?? URL(string: originalString ?? "")?.lastPathComponent
                ?? "image-\(id)"

            let mimeType = stringValue(raw["mime"])
                ?? stringValue(raw["mime_type"])
                ?? "image/jpeg"

            let width = nestedInt(raw["media_details"], key: "width")
                ?? nestedInt(sizes?["full"], key: "width")
                ?? nestedInt(sizes?["medium_large"], key: "width")
                ?? nestedInt(sizes?["medium"], key: "width")

            let height = nestedInt(raw["media_details"], key: "height")
                ?? nestedInt(sizes?["full"], key: "height")
                ?? nestedInt(sizes?["medium_large"], key: "height")
                ?? nestedInt(sizes?["medium"], key: "height")

            return WordPressMediaItem(
                id: id,
                title: title,
                filename: filename,
                mimeType: mimeType,
                originalURL: originalString.flatMap(URL.init(string:)),
                thumbnailURL: thumbnailString.flatMap(URL.init(string:)),
                width: width,
                height: height,
                createdAt: stringValue(raw["dateFormatted"]) ?? stringValue(raw["date"])
            )
        }
    }

    private func stringValue(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    private func nestedString(_ value: Any?, key: String) -> String? {
        (value as? [String: Any]).flatMap { stringValue($0[key]) }
    }

    private func nestedInt(_ value: Any?, key: String) -> Int? {
        guard let dict = value as? [String: Any] else { return nil }
        if let number = dict[key] as? Int {
            return number
        }
        if let string = dict[key] as? String {
            return Int(string)
        }
        return nil
    }
}

enum WordPressMediaLibraryError: LocalizedError {
    case invalidPayload
    case invalidRequest
    case invalidResponse
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidPayload:
            return "返回数据格式无法识别"
        case .invalidRequest:
            return "图库请求构造失败"
        case .invalidResponse:
            return "图库服务返回了无效响应"
        case .httpStatus(let code):
            return "请求失败（HTTP \(code)）"
        }
    }
}

private final class WordPressAuthenticatedSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let method = challenge.protectionSpace.authenticationMethod
        let supportedMethods = [
            NSURLAuthenticationMethodHTTPBasic,
            NSURLAuthenticationMethodHTTPDigest,
            NSURLAuthenticationMethodDefault
        ]

        guard supportedMethods.contains(method) else {
            Task { @MainActor in
                completionHandler(.performDefaultHandling, nil)
            }
            return
        }

        if let credential = WordPressHTTPAuthStore.defaultCredential(for: challenge.protectionSpace)
            ?? challenge.proposedCredential {
            Task { @MainActor in
                completionHandler(.useCredential, credential)
            }
        } else {
            Task { @MainActor in
                completionHandler(.performDefaultHandling, nil)
            }
        }
    }
}
