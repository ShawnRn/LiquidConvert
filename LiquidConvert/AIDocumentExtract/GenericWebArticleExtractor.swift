import Foundation
import WebKit

enum GenericWebArticleExtractor {
    fileprivate static let desktopUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    nonisolated static func canHandle(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    nonisolated static func shouldPreferOverMarkItDown(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        let directDocumentExtensions = [
            ".pdf", ".doc", ".docx", ".ppt", ".pptx", ".xls", ".xlsx", ".csv", ".txt",
            ".rtf", ".md", ".markdown", ".xml", ".json"
        ]
        return !directDocumentExtensions.contains { path.hasSuffix($0) }
    }

    static func extract(from url: URL) async throws -> AIDocumentExtractionResult {
        let article: ParsedArticle
        do {
            article = try await GenericRenderedPageReader().extract(url: url)
        } catch {
            let html = try await fetchHTML(from: url)
            article = try parseArticle(from: html, url: url)
        }

        guard article.bodyMarkdown.count >= 80 else {
            throw NSError(
                domain: "GenericWebArticleExtractor",
                code: -10,
                userInfo: [NSLocalizedDescriptionKey: "网页正文提取结果过短，已放弃通用提取。"]
            )
        }

        return AIDocumentExtractionResult(markdown: article.markdownDocument, source: .link(url))
    }

    private static func fetchHTML(from url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.setValue(desktopUserAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw NSError(
                domain: "GenericWebArticleExtractor",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "网页访问失败（HTTP \(http.statusCode)）。"]
            )
        }

        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .unicode) else {
            throw NSError(
                domain: "GenericWebArticleExtractor",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "无法读取网页内容。"]
            )
        }

        return html
    }

    private static func parseArticle(from html: String, url: URL) throws -> ParsedArticle {
        let title = firstMatch(in: html, patterns: [
            #"<meta property="og:title" content="([^"]+)""#,
            #"<title[^>]*>(.*?)</title>"#,
            #"<h1[^>]*>(.*?)</h1>"#,
        ])
        let summary = firstMatch(in: html, patterns: [
            #"<meta name="description" content="([^"]+)""#,
            #"<meta property="og:description" content="([^"]+)""#,
        ])

        let contentHTML = firstMatch(in: html, patterns: [
            #"<article[^>]*>([\s\S]*?)</article>"#,
            #"<main[^>]*>([\s\S]*?)</main>"#,
            #"<div[^>]*class="[^"]*(?:article-body|entry-content|post-content|c-entry-content)[^"]*"[^>]*>([\s\S]*?)</div>"#,
        ])

        let bodyMarkdown = cleanMarkdownBody(from: contentHTML.isEmpty ? html : contentHTML)
        guard bodyMarkdown.count >= 80 else {
            throw NSError(
                domain: "GenericWebArticleExtractor",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "网页正文提取结果过短。"]
            )
        }

        return ParsedArticle(
            url: url,
            title: cleanText(title).isEmpty ? (url.host ?? "网页内容") : cleanText(title),
            summary: cleanText(summary),
            bodyMarkdown: bodyMarkdown
        )
    }

    fileprivate static func cleanMarkdownBody(from html: String) -> String {
        guard !html.isEmpty else { return "" }

        var text = html
        let replacements: [(String, String)] = [
            (#"<!--.*?-->"#, ""),
            (#"<script\b[\s\S]*?</script>"#, ""),
            (#"<style\b[\s\S]*?</style>"#, ""),
            (#"<noscript\b[\s\S]*?</noscript>"#, ""),
            (#"<figure[^>]*>"#, "\n"),
            (#"</figure>"#, "\n"),
            (#"<br\s*/?>"#, "\n"),
            (#"</p>|</section>|</article>|</main>|</li>|</blockquote>|</div>"#, "\n"),
            (#"<li[^>]*>"#, "- "),
            (#"<h1[^>]*>"#, "\n# "),
            (#"<h2[^>]*>"#, "\n## "),
            (#"<h3[^>]*>"#, "\n### "),
            (#"<h4[^>]*>|<h5[^>]*>|<h6[^>]*>"#, "\n#### "),
            (#"<img[^>]*src="([^"]+)"[^>]*>"#, "\n![image]($1)\n"),
            (#"<img[^>]*data-src="([^"]+)"[^>]*>"#, "\n![image]($1)\n"),
            (#"<[^>]+>"#, ""),
        ]

        for replacement in replacements {
            text = replacing(pattern: replacement.0, in: text, with: replacement.1)
        }

        text = htmlDecoded(text)
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\r\n", with: "\n")

        let lines = text
            .components(separatedBy: .newlines)
            .map(cleanText)
            .filter { !$0.isEmpty }
            .filter { !$0.hasPrefix("function ") && !$0.hasPrefix("{") && !$0.hasPrefix("window.") }

        return lines
            .joined(separator: "\n\n")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func cleanText(_ value: String) -> String {
        htmlDecoded(value)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func firstMatch(in text: String, patterns: [String]) -> String {
        for pattern in patterns {
            if let value = firstMatch(in: text, pattern: pattern) {
                return value
            }
        }
        return ""
    }

    nonisolated private static func firstMatch(in text: String, pattern: String) -> String? {
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

    nonisolated private static func replacing(pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }

    nonisolated private static func htmlDecoded(_ text: String) -> String {
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
        let summary: String
        let bodyMarkdown: String

        var markdownDocument: String {
            var sections = ["# \(title)", "> 来源：\(url.absoluteString)"]
            if !summary.isEmpty {
                sections.append("> 摘要：\(summary)")
            }
            sections.append(bodyMarkdown)
            return sections.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

@MainActor
private final class GenericRenderedPageReader: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var navigationContinuation: CheckedContinuation<Void, Error>?

    func extract(url: URL) async throws -> GenericWebArticleExtractor.ParsedArticle {
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

        try await Task.sleep(for: .milliseconds(1200))
        let snapshot = try await evaluateSnapshot()
        let markdown = GenericWebArticleExtractor.cleanMarkdownBody(from: snapshot.contentHTML)
        let fallbackMarkdown = GenericWebArticleExtractor.cleanMarkdownBody(from: snapshot.contentText)
        let body = markdown.count >= fallbackMarkdown.count ? markdown : fallbackMarkdown

        guard body.count >= 80 else {
            throw NSError(
                domain: "GenericWebArticleExtractor",
                code: -20,
                userInfo: [NSLocalizedDescriptionKey: "网页渲染完成，但没有提取到足够正文。"]
            )
        }

        return GenericWebArticleExtractor.ParsedArticle(
            url: url,
            title: snapshot.bestTitle,
            summary: snapshot.summary,
            bodyMarkdown: body
        )
    }

    private func buildWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = GenericWebArticleExtractor.desktopUserAgent
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

    private func evaluateSnapshot() async throws -> GenericDOMSnapshot {
        guard let webView else {
            throw NSError(
                domain: "GenericWebArticleExtractor",
                code: -21,
                userInfo: [NSLocalizedDescriptionKey: "网页读取器未初始化。"]
            )
        }

        let script = #"""
        (() => {
          const text = (selector) => document.querySelector(selector)?.textContent?.trim() || "";
          const meta = (selector) => document.querySelector(selector)?.content?.trim() || "";

          const selectorCandidates = [
            'article',
            'main article',
            '[role="main"] article',
            'main',
            '[role="main"]',
            '.article-body',
            '.entry-content',
            '.post-content',
            '.c-entry-content',
            '.duet--article--article-body-component-container',
            '.duet--article--article-body-component',
            '.article-page',
            '.story-body'
          ];

          const score = (el) => {
            if (!el) return -1;
            const textLength = (el.innerText || '').trim().length;
            const paragraphCount = el.querySelectorAll('p').length;
            const headingCount = el.querySelectorAll('h1,h2,h3').length;
            const imageCount = el.querySelectorAll('img').length;
            const noiseCount = el.querySelectorAll('nav,aside,footer,header,button,form').length;
            return textLength + paragraphCount * 120 + headingCount * 80 + imageCount * 30 - noiseCount * 500;
          };

          const candidates = [];
          selectorCandidates.forEach((selector) => {
            document.querySelectorAll(selector).forEach((el) => candidates.push(el));
          });
          document.querySelectorAll('div,section,main,article').forEach((el) => {
            if ((el.innerText || '').trim().length > 400 && el.querySelectorAll('p').length >= 3) {
              candidates.push(el);
            }
          });

          const best = candidates
            .sort((a, b) => score(b) - score(a))[0] || document.body;

          return JSON.stringify({
            title:
              meta('meta[property="og:title"]') ||
              text('h1') ||
              document.title ||
              "",
            summary:
              meta('meta[name="description"]') ||
              meta('meta[property="og:description"]') ||
              "",
            contentHTML: best?.innerHTML || "",
            contentText: best?.innerText || "",
            documentTitle: document.title || ""
          });
        })();
        """#

        let raw = try await webView.evaluateJavaScript(script)
        guard let jsonString = raw as? String,
              let data = jsonString.data(using: .utf8)
        else {
            throw NSError(
                domain: "GenericWebArticleExtractor",
                code: -22,
                userInfo: [NSLocalizedDescriptionKey: "无法解析网页 DOM。"]
            )
        }

        return try JSONDecoder().decode(GenericDOMSnapshot.self, from: data)
    }
}

private struct GenericDOMSnapshot: Decodable {
    let title: String
    let summary: String
    let contentHTML: String
    let contentText: String
    let documentTitle: String

    var bestTitle: String {
        let candidates = [title, documentTitle]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return candidates.first ?? "网页内容"
    }
}
