import Combine
import Foundation
import WebKit

/// 管理 WordPress 媒体库登录态，复用嵌入式 WebView 的 Cookie。
@MainActor
final class WordPressCookieManager: ObservableObject {
    static let shared = WordPressCookieManager()

    @Published private(set) var cachedCookies: [HTTPCookie] = []

    private let cookieKey = "wordpress_media_saved_cookies"

    private init() {
        cachedCookies = loadFromDisk()
        print("[WordPressCookieManager] 初始化，加载 \(cachedCookies.count) 条 Cookie")
    }

    func syncFrom(webView: WKWebView) async {
        let store = webView.configuration.websiteDataStore.httpCookieStore
        let cookies = await store.fetchAllCookies()
        let targetCookies = cookies.filter {
            $0.domain.contains(SecureRuntimeConfig.ifanrDomain) || $0.domain.contains(SecureRuntimeConfig.ifanrCNDomain)
        }

        cachedCookies = targetCookies

        if targetCookies.isEmpty {
            UserDefaults.standard.removeObject(forKey: cookieKey)
            print("[WordPressCookieManager] 未检测到可复用会话，已清理本地缓存")
            return
        }

        saveToDisk(cookies: targetCookies)
        print("[WordPressCookieManager] 已同步 \(targetCookies.count) 条 Cookie")
    }

    var cookieHeaderValue: String {
        cachedCookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    var hasValidSession: Bool {
        cachedCookies.contains { $0.name.hasPrefix(SecureRuntimeConfig.wordPressLoggedInPrefix) && !$0.value.isEmpty }
            || cachedCookies.contains { $0.name == SecureRuntimeConfig.wordPressSessionKeyCookieName && !$0.value.isEmpty }
    }

    func logout() {
        cachedCookies = []
        UserDefaults.standard.removeObject(forKey: cookieKey)
        WordPressHTTPAuthStore.clear()

        let store = WKWebsiteDataStore.default().httpCookieStore
        Task {
            let cookies = await store.fetchAllCookies()
            for cookie in cookies where cookie.domain.contains(SecureRuntimeConfig.ifanrDomain) || cookie.domain.contains(SecureRuntimeConfig.ifanrCNDomain) {
                await store.remove(cookie: cookie)
            }
            print("[WordPressCookieManager] 已清理 ifanr 相关 Cookie")
        }
    }

    private func saveToDisk(cookies: [HTTPCookie]) {
        let cookieData = cookies.compactMap { cookie -> [String: Any]? in
            guard let properties = cookie.properties else { return nil }
            var dict: [String: Any] = [:]
            for (key, value) in properties {
                dict[key.rawValue] = value
            }
            return dict
        }
        UserDefaults.standard.set(cookieData, forKey: cookieKey)
    }

    private func loadFromDisk() -> [HTTPCookie] {
        guard let savedData = UserDefaults.standard.array(forKey: cookieKey) as? [[String: Any]] else {
            return []
        }

        return savedData.compactMap { dict in
            var properties: [HTTPCookiePropertyKey: Any] = [:]
            for (key, value) in dict {
                properties[HTTPCookiePropertyKey(rawValue: key)] = value
            }
            return HTTPCookie(properties: properties)
        }
    }
}

extension WKHTTPCookieStore {
    func remove(cookie: HTTPCookie) async {
        await withCheckedContinuation { continuation in
            delete(cookie) {
                continuation.resume()
            }
        }
    }
}
