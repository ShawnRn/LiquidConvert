import AppKit
import Foundation
import WebKit

enum WeChatArticleExtractor {
    private static let mobileUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    private static let noiseKeywords = [
        "微信扫一扫", "继续滑动看下一个", "向上滑动看下一个", "轻触阅读原文", "预览时标签不可点",
        "使用小程序", "允许", "取消", "知道了", "分析", "打开此内容", "完整服务", "赞", "在看",
        "分享", "留言", "收藏", "听过", "关注该公众号", "视频", "小程序", "轻点两下取消赞",
        "轻点两下取消在看", "去验证", "环境异常", "当前环境异常"
    ]

    nonisolated static func canHandle(_ url: URL) -> Bool {
        (url.host ?? "").contains("mp.weixin.qq.com")
    }

    static func extract(from url: URL) async throws -> AIDocumentExtractionResult {
        let article: ParsedArticle
        do {
            article = try await WeChatRenderedPageReader().extract(url: url)
        } catch {
            let html = try await fetchHTML(from: url)
            article = try parseArticle(from: html, url: url)
        }

        return AIDocumentExtractionResult(markdown: article.markdownDocument, source: .link(url))
    }

    fileprivate static func cleanRenderedText(_ text: String) -> String {
        text
            .components(separatedBy: .newlines)
            .map { normalizeLine($0) }
            .filter { line in
                guard !line.isEmpty else { return false }
                guard !["×", "：", "，", "。", ";", "；", ":"].contains(line) else { return false }
                return !noiseKeywords.contains { line.contains($0) }
            }
            .joined(separator: "\n\n")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func fetchHTML(from url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.setValue(mobileUserAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw NSError(
                domain: "WeChatArticleExtractor",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "公众号页面访问失败（HTTP \(http.statusCode)）。"]
            )
        }

        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .unicode) else {
            throw NSError(
                domain: "WeChatArticleExtractor",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "无法读取公众号页面内容。"]
            )
        }

        return html
    }

    private static func parseArticle(from page: String, url: URL) throws -> ParsedArticle {
        let title = cleanTitle(
            firstMatch(
                in: page,
                patterns: [
                    #"var\s+msg_title\s*=\s*'([^']*)';"#,
                    #"<meta property="og:title" content="([^"]*)""#,
                    #"<meta name="twitter:title" content="([^"]*)""#,
                ]
            )
        )

        guard !title.isEmpty else {
            throw NSError(
                domain: "WeChatArticleExtractor",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "无法识别公众号文章标题，页面可能触发了验证或结构已变化。"]
            )
        }

        let author = cleanInlineText(
            firstMatch(
                in: page,
                patterns: [
                    #"var\s+nickname\s*=\s*htmlDecode\("([^"]*)"\)"#,
                    #"nickname=\\x22(.*?)\\x22"#,
                ]
            )
        )
        let summary = cleanInlineText(
            firstMatch(
                in: page,
                patterns: [
                    #"msg_desc\s*=\s*htmlDecode\("([^"]*)"\);"#,
                    #"<meta name="description" content="([^"]*)""#,
                ]
            )
        )

        let bodyHTML = extractBodyHTML(from: page)
        let markdownBody = cleanMarkdownBody(from: bodyHTML)

        guard !markdownBody.isEmpty else {
            throw NSError(
                domain: "WeChatArticleExtractor",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "公众号页面没有提取到可用正文，可能仍处于验证页。"]
            )
        }

        return ParsedArticle(
            url: url,
            title: title,
            author: author.isEmpty ? "未知作者" : author,
            summary: summary,
            bodyMarkdown: markdownBody
        )
    }

    private static func extractBodyHTML(from page: String) -> String {
        guard let contentRange = page.range(of: #"id="js_content""#, options: .regularExpression) else {
            return ""
        }

        var body = String(page[contentRange.lowerBound...])
        let endMarkers = [
            #"<section[^>]*class="wx_profile_card_inner""#,
            #"<div[^>]*id="js_tags""#,
            #"<div[^>]*class="original_area_primary""#,
            #"<div[^>]*id="js_article""#,
            #"<div[^>]*class="rich_media_tool""#,
            #"<script\b"#,
        ]

        for marker in endMarkers {
            if let range = body.range(of: marker, options: .regularExpression) {
                body = String(body[..<range.lowerBound])
                break
            }
        }

        return body
    }

    fileprivate static func cleanMarkdownBody(from bodyHTML: String) -> String {
        guard !bodyHTML.isEmpty else { return "" }

        var text = bodyHTML
        let replacements: [(pattern: String, template: String)] = [
            (#"<!--.*?-->"#, ""),
            (#"<script\b[\s\S]*?</script>"#, ""),
            (#"<style\b[\s\S]*?</style>"#, ""),
            (#"<br\s*/?>"#, "\n"),
            (#"</p>|</section>|</article>|</li>|</h[1-6]>|</blockquote>|</div>"#, "\n"),
            (#"<li[^>]*>"#, "- "),
            (#"<h[1-6][^>]*>"#, "\n"),
            (#"<img[^>]*data-src="([^"]+)"[^>]*>"#, "\n![image]($1)\n"),
            (#"<img[^>]*src="([^"]+)"[^>]*>"#, "\n![image]($1)\n"),
            (#"<[^>]+>"#, ""),
        ]

        for replacement in replacements {
            text = replacing(pattern: replacement.pattern, in: text, with: replacement.template)
        }

        text = htmlDecoded(text)
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\r\n", with: "\n")

        let cleanedLines = text
            .components(separatedBy: .newlines)
            .map { normalizeLine($0) }
            .filter { line in
                guard !line.isEmpty else { return false }
                guard !["×", "：", "，", "。", ";", "；", ":"].contains(line) else { return false }
                return !noiseKeywords.contains { line.contains($0) }
            }

        return collapseMarkdownLines(cleanedLines)
    }

    private static func collapseMarkdownLines(_ lines: [String]) -> String {
        var output: [String] = []

        for line in lines {
            if line.hasPrefix("![image](") {
                output.append(line)
                continue
            }

            if isHeading(line) {
                output.append("### \(line)")
                continue
            }

            output.append(line)
        }

        return output
            .joined(separator: "\n\n")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isHeading(_ line: String) -> Bool {
        if line.count <= 24,
           line.range(of: #"^第?[一二三四五六七八九十0-9]+[、，.]?.{0,20}$"#, options: .regularExpression) != nil
        {
            return true
        }

        return line.count <= 30 && !line.contains("。") && !line.contains("，")
    }

    private static func firstMatch(in text: String, patterns: [String]) -> String {
        for pattern in patterns {
            if let value = firstMatch(in: text, pattern: pattern) {
                return value
            }
        }
        return ""
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let capture = Range(match.range(at: 1), in: text)
        else {
            return nil
        }

        return String(text[capture])
    }

    private static func cleanTitle(_ raw: String) -> String {
        cleanInlineText(raw)
            .replacingOccurrences(of: #"'.html\(false\);.*$"#, with: "", options: .regularExpression)
    }

    private static func cleanInlineText(_ raw: String) -> String {
        normalizeLine(
            htmlDecoded(raw)
                .replacingOccurrences(of: #"\\'"#, with: "'", options: .regularExpression)
                .replacingOccurrences(of: #"\\x26quot;"#, with: "\"", options: .regularExpression)
        )
    }

    private static func normalizeLine(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replacing(pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }

    private static func htmlDecoded(_ text: String) -> String {
        guard let data = text.data(using: .utf8),
              let attributed = try? NSAttributedString(
                data: data,
                options: [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: String.Encoding.utf8.rawValue,
                ],
                documentAttributes: nil
              )
        else {
            return text
        }

        return attributed.string
    }

    fileprivate struct ParsedArticle {
        let url: URL
        let title: String
        let author: String
        let summary: String
        let bodyMarkdown: String

        var markdownDocument: String {
            var sections = ["# \(title)"]

            sections.append("> 来源：\(url.absoluteString)")
            sections.append("> 作者：\(author)")
            if !summary.isEmpty {
                sections.append("> 摘要：\(summary)")
            }

            sections.append(bodyMarkdown)
            return sections.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

@MainActor
private final class WeChatRenderedPageReader: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var navigationContinuation: CheckedContinuation<Void, Error>?

    func extract(url: URL) async throws -> WeChatArticleExtractor.ParsedArticle {
        let webView = buildWebView()
        self.webView = webView

        defer {
            navigationContinuation = nil
            webView.stopLoading()
            self.webView = nil
        }

        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
        webView.load(request)
        try await waitForNavigation()

        for _ in 0..<18 {
            try await Task.sleep(for: .milliseconds(500))
            let snapshot = try await evaluateSnapshot()

            if !snapshot.contentHTML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let cleanedHTML = WeChatArticleExtractor.cleanMarkdownBody(from: snapshot.contentHTML)
                if !cleanedHTML.isEmpty {
                    return WeChatArticleExtractor.ParsedArticle(
                        url: url,
                        title: snapshot.bestTitle,
                        author: snapshot.author.isEmpty ? "未知作者" : snapshot.author,
                        summary: snapshot.summary,
                        bodyMarkdown: cleanedHTML
                    )
                }
            }

            if !snapshot.contentText.isEmpty {
                let cleanedText = WeChatArticleExtractor.cleanRenderedText(snapshot.contentText)
                if !cleanedText.isEmpty {
                    return WeChatArticleExtractor.ParsedArticle(
                        url: url,
                        title: snapshot.bestTitle,
                        author: snapshot.author.isEmpty ? "未知作者" : snapshot.author,
                        summary: snapshot.summary,
                        bodyMarkdown: cleanedText
                    )
                }
            }

            if !snapshot.errorTitle.isEmpty {
                let message = [snapshot.errorTitle, snapshot.errorDescription]
                    .filter { !$0.isEmpty }
                    .joined(separator: "：")
                throw NSError(
                    domain: "WeChatArticleExtractor",
                    code: -20,
                    userInfo: [NSLocalizedDescriptionKey: message.isEmpty ? "公众号页面当前不可访问。" : message]
                )
            }
        }

        let fallbackSnapshot = try await evaluateSnapshot()
        if !fallbackSnapshot.contentText.isEmpty {
            let cleanedText = WeChatArticleExtractor.cleanRenderedText(fallbackSnapshot.contentText)
            return WeChatArticleExtractor.ParsedArticle(
                url: url,
                title: fallbackSnapshot.bestTitle,
                author: fallbackSnapshot.author.isEmpty ? "未知作者" : fallbackSnapshot.author,
                summary: fallbackSnapshot.summary,
                bodyMarkdown: cleanedText.isEmpty ? fallbackSnapshot.contentText : cleanedText
            )
        }

        throw NSError(
            domain: "WeChatArticleExtractor",
            code: -21,
            userInfo: [NSLocalizedDescriptionKey: "公众号页面没有加载出正文，可能需要验证、链接已失效，或当前页面限制了直接提取。"]
        )
    }

    private func buildWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent =
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    private func waitForNavigation() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            navigationContinuation = continuation
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        navigationContinuation?.resume()
        navigationContinuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationContinuation?.resume(throwing: error)
        navigationContinuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigationContinuation?.resume(throwing: error)
        navigationContinuation = nil
    }

    private func evaluateSnapshot() async throws -> WeChatDOMSnapshot {
        guard let webView else {
            throw NSError(
                domain: "WeChatArticleExtractor",
                code: -22,
                userInfo: [NSLocalizedDescriptionKey: "公众号页面读取器未初始化。"]
            )
        }

        let script = #"""
        (() => {
          const text = (selector) => document.querySelector(selector)?.textContent?.trim() || "";
          const html = (selector) => document.querySelector(selector)?.innerHTML || "";
          const meta = (selector) => document.querySelector(selector)?.content?.trim() || "";
          const bodyText = (selector) => document.querySelector(selector)?.innerText?.trim() || "";

          const title =
            text('#activity-name') ||
            text('.rich_media_title') ||
            text('h1') ||
            document.title ||
            "";

          const author =
            text('#js_name') ||
            text('.account_nickname_inner') ||
            text('.wx_follow_nickname') ||
            "";

          const summary =
            meta('meta[name="description"]') ||
            text('.rich_media_meta.rich_media_meta_text') ||
            "";

          const contentHTML =
            html('#js_content') ||
            html('.rich_media_content') ||
            html('article') ||
            "";

          const contentText =
            bodyText('#js_content') ||
            bodyText('.rich_media_content') ||
            bodyText('article') ||
            "";

          const errorTitle =
            text('.weui-msg__title') ||
            text('.full_screen__title') ||
            text('.js_err_wording') ||
            "";

          const errorDescription =
            text('.weui-msg__desc') ||
            text('.weui-msg__tips') ||
            text('.full_screen__desc') ||
            "";

          return JSON.stringify({
            title,
            author,
            summary,
            contentHTML,
            contentText,
            errorTitle,
            errorDescription,
            documentTitle: document.title || ""
          });
        })();
        """#

        let raw = try await webView.evaluateJavaScript(script)
        guard let jsonString = raw as? String,
              let data = jsonString.data(using: .utf8)
        else {
            throw NSError(
                domain: "WeChatArticleExtractor",
                code: -23,
                userInfo: [NSLocalizedDescriptionKey: "无法解析公众号页面 DOM。"]
            )
        }

        return try JSONDecoder().decode(WeChatDOMSnapshot.self, from: data)
    }
}

private struct WeChatDOMSnapshot: Decodable {
    let title: String
    let author: String
    let summary: String
    let contentHTML: String
    let contentText: String
    let errorTitle: String
    let errorDescription: String
    let documentTitle: String

    var bestTitle: String {
        let candidates = [title, documentTitle]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "微信公众平台" }
        return candidates.first ?? "公众号文章"
    }
}
