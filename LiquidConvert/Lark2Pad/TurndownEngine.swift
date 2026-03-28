//
//  TurndownEngine.swift
//  LiquidConvert
//
//  Headless WKWebView engine that loads turndown.js + GFM plugin + custom wrapper
//  to convert HTML → Markdown with Lark2Pad-specific rules (keepImages, cleanup).
//

import Foundation
import WebKit

/// Manages a hidden WKWebView that runs Turndown.js for HTML-to-Markdown conversion.
/// All DOM operations (cleaning, image src replacement, conversion) happen inside JS.
@MainActor
final class TurndownEngine: NSObject {

    private var webView: WKWebView!
    private var isReady = false
    private var readyContinuation: CheckedContinuation<Void, Never>?

    override init() {
        super.init()
        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = true
        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
    }

    // MARK: - Public API

    /// Boot the engine: load a blank page and inject all JS libraries.
    func prepare() async {
        guard !isReady else { return }
        
        // Load a minimal HTML page with a proper about:blank baseURL for sandbox sanity
        let bootstrapHTML = "<!DOCTYPE html><html><head><meta charset=\"utf-8\"></head><body></body></html>"
        webView.loadHTMLString(bootstrapHTML, baseURL: URL(string: "about:blank"))
        
        // Wait for page load with a 3-second safety timeout
        try? await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                guard let self = self else { return }
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    Task { @MainActor in
                        self.readyContinuation = continuation
                    }
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(3))
                throw NSError(domain: "TurndownEngine", code: 1, 
                             userInfo: [NSLocalizedDescriptionKey: "WebView initialization timed out"])
            }
            try await group.next()
            group.cancelAll()
        }
        
        // Inject JS libraries sequentially
        try? await injectJS(resourceName: "turndown")
        try? await injectJS(resourceName: "turndown-plugin-gfm")
        try? await injectJS(resourceName: "turndown-wrapper")
        
        isReady = true
    }

    /// Step 1: Feed raw HTML, get back a list of image URLs that need fetching.
    func loadHTMLAndGetImageURLs(_ html: String) async throws -> [(id: Int, url: String)] {
        let js = await prepareJSScript(functionCall: "loadHtmlAndGetImages", argument: html)
        let result = try await webView.evaluateJavaScript(js)
        
        // Parse result in background
        return try await Task.detached {
            guard let jsonString = result as? String,
                  let data = jsonString.data(using: .utf8),
                  let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                return []
            }
            return array.compactMap { dict in
                guard let id = dict["id"] as? Int, let url = dict["url"] as? String else { return nil }
                return (id: id, url: url)
            }
        }.value
    }

    /// Step 2a: Convert loaded HTML directly to Markdown without replacing images (keeps original URLs).
    func convertDirectly() async throws -> String {
        let result = try await webView.evaluateJavaScript("convertToMarkdownDirectly();")
        return (result as? String) ?? ""
    }

    /// Step 2b: After fetching images, pass replacements and get final Markdown.
    func replaceImagesAndConvert(_ replacements: [(id: Int, base64: String)]) async throws -> String {
        // Prepare JS command in background to avoid blocking MainActor
        let jsCommand = try await Task.detached {
            let jsonArray = replacements.map { item -> [String: Any] in
                ["id": item.id, "base64": item.base64]
            }
            let jsonData = try JSONSerialization.data(withJSONObject: jsonArray)
            let jsonStr = String(data: jsonData, encoding: .utf8) ?? "[]"
            
            // Encode the string as a JSON string literal
            let payloadData = try JSONSerialization.data(withJSONObject: [jsonStr])
            guard let escapedJson = String(data: payloadData, encoding: .utf8),
                  escapedJson.count >= 2 else {
                return "replaceImageAndConvertToMarkdown(\"[]\");"
            }
            let payload = String(escapedJson.dropFirst().dropLast())
            return "replaceImageAndConvertToMarkdown(\(payload));"
        }.value

        let result = try await webView.evaluateJavaScript(jsCommand)
        return (result as? String) ?? ""
    }

    // MARK: - Helpers

    private func injectJS(resourceName: String) async throws {
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            print("[TurndownEngine] Failed to load JS resource: \(resourceName)")
            return
        }
        _ = try await webView.evaluateJavaScript(source)
    }

    /// Prepare JS script in background to avoid blocking Main thread
    private func prepareJSScript(functionCall: String, argument: String) async -> String {
        await Task.detached {
            guard let data = try? JSONSerialization.data(withJSONObject: [argument]),
                  let jsonStr = String(data: data, encoding: .utf8),
                  jsonStr.count >= 2 else {
                return "\(functionCall)(\"\");"
            }
            let escaped = String(jsonStr.dropFirst().dropLast())
            return "\(functionCall)(\(escaped));"
        }.value
    }
}

// MARK: - WKNavigationDelegate

extension TurndownEngine: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            readyContinuation?.resume()
            readyContinuation = nil
        }
    }
}
