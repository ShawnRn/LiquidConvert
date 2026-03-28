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
        
        // 关注 ifanr 相关域名的关键 Cookie
        let targetCookies = cookies.filter { 
            $0.domain.contains("ifanr.com") || $0.domain.contains("ifanr.cn")
        }
        
        if !targetCookies.isEmpty {
            self.cachedCookies = targetCookies
            saveToDisk(cookies: targetCookies)
            let domains = Set(targetCookies.map { $0.domain }).joined(separator: ", ")
            print("[CookieManager] 已同步 \(targetCookies.count) 条来自 [\(domains)] 的 Cookie")
            
            // 打印关键 Cookie 是否存在
            let hasToken = targetCookies.contains { $0.name == "token" }
            let hasSid = targetCookies.contains { $0.name == "express_sid" }
            print("[CookieManager] 鉴权状态: token=\(hasToken), express_sid=\(hasSid)")
        }
    }
    
    /// 获取完整的 Cookie 字符串用于 HTTP Header
    var cookieHeaderValue: String {
        return cachedCookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }
    
    /// 检查是否存有关键 Token
    var hasValidSession: Bool {
        let hasToken = cachedCookies.contains { $0.name == "token" && !$0.value.isEmpty }
        let hasSid = cachedCookies.contains { $0.name == "express_sid" && !$0.value.isEmpty }
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
