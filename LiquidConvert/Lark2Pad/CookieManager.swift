import Foundation
import WebKit

/// 负责管理 Etherpad 登录 Session 的工具类
final class CookieManager {
    
    static let shared = CookieManager()
    private let cookieKey = "lark2pad_saved_cookies"
    private var cachedCookies: [HTTPCookie] = []
    
    private init() {
        self.cachedCookies = loadFromDisk()
        print("[CookieManager] 初始化，从磁盘加载了 \(cachedCookies.count) 条 Cookie")
    }
    
    /// 从 WebView 数据存储中提取特定域名的 Cookie
    func syncFrom(webView: WKWebView) async {
        let store = webView.configuration.websiteDataStore.httpCookieStore
        let cookies = await store.fetchAllCookies()
        
        // 仅同步目标域名的 Cookie，避免混入无关站点状态
        let targetCookies = cookies.filter { 
            $0.domain.contains(SecureRuntimeConfig.ifanrDomain) || $0.domain.contains(SecureRuntimeConfig.ifanrCNDomain)
        }

        self.cachedCookies = targetCookies

        if targetCookies.isEmpty {
            UserDefaults.standard.removeObject(forKey: cookieKey)
            print("[CookieManager] 未检测到可复用会话，已清理本地缓存")
            return
        }

        saveToDisk(cookies: targetCookies)
        let domains = Set(targetCookies.map { $0.domain }).joined(separator: ", ")
        print("[CookieManager] 已同步 \(targetCookies.count) 条来自 [\(domains)] 的 Cookie")

        let hasPrimaryCookie = targetCookies.contains { $0.name == SecureRuntimeConfig.etherpadTokenCookieName }
        let hasSessionCookie = targetCookies.contains { $0.name == SecureRuntimeConfig.etherpadSessionCookieName }
        print("[CookieManager] 会话状态: primary=\(hasPrimaryCookie), session=\(hasSessionCookie)")
    }
    
    /// 获取完整的 Cookie 字符串用于 HTTP Header
    var cookieHeaderValue: String {
        return cachedCookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }
    
    /// 检查是否存有关键 Token
    var hasValidSession: Bool {
        let hasToken = cachedCookies.contains { $0.name == SecureRuntimeConfig.etherpadTokenCookieName && !$0.value.isEmpty }
        let hasSid = cachedCookies.contains { $0.name == SecureRuntimeConfig.etherpadSessionCookieName && !$0.value.isEmpty }
        return hasToken || hasSid
    }
    
    /// 清除所有保存的 Cookie (用于注销或重试)
    func logout() {
        print("[CookieManager] 执行登出，清空所有缓存与状态")
        cachedCookies = []
        UserDefaults.standard.removeObject(forKey: cookieKey)
        UserDefaults.standard.synchronize()
        
        // 同时清理 WKWebsiteDataStore 的全部数据
        let dataTypes = Set([WKWebsiteDataTypeCookies, WKWebsiteDataTypeLocalStorage, WKWebsiteDataTypeSessionStorage])
        WKWebsiteDataStore.default().removeData(ofTypes: dataTypes, modifiedSince: .distantPast) {
            print("[CookieManager] 已完成浏览器所有缓存清理")
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
    
    func clear() {
        logout()
    }
}

extension WKHTTPCookieStore {
    func fetchAllCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            self.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
    }
}
