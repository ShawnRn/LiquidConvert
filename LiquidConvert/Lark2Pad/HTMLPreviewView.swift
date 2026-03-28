// 
//  HTMLPreviewView.swift
//  LiquidConvert
//
//  NSViewRepresentable wrapper for WKWebView to render Etherpad HTML as WYSIWYG preview.
//

import SwiftUI
import WebKit

/// Renders HTML content in a WKWebView for WYSIWYG preview.
struct HTMLPreviewView: NSViewRepresentable {
    let html: String
    var onLoaded: (() -> Void)? = nil

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = true
        let webView = WKWebView(frame: .zero, configuration: config)
        
        // Correct way to make WKWebView transparent on macOS
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        
        // Initial state is hidden to avoid white flash
        webView.alphaValue = 0
        
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Update coordinator reference to closure
        context.coordinator.onLoaded = onLoaded
        
        // Only reload if content actually changed
        guard context.coordinator.lastHTML != html else { return }
        context.coordinator.lastHTML = html
        
        // Reset opacity for new load
        webView.alphaValue = 0

        // Combine extracted styles with local presentation CSS
        let extractedStyles = extractTagContent(tag: "style", from: html)
        let localCSS = """
            body {
                font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif;
                font-size: 14px;
                line-height: 1.7;
                color: \(NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? "#e0e0e0" : "#1d1d1f");
                background: transparent;
                padding: 20px 24px;
                -webkit-font-smoothing: antialiased;
            }
            img { max-width: 100%; border-radius: 8px; margin: 10px 0; }
        """

        let styledHTML = """
        <!doctype html>
        <html>
        <head>
            <meta charset="utf-8">
            <style>\(extractedStyles)\n\(localCSS)</style>
        </head>
        <body>\(extractTagContent(tag: "body", from: html))</body>
        </html>
        """
        webView.loadHTMLString(styledHTML, baseURL: nil)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastHTML: String = ""
        var onLoaded: (() -> Void)?
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                webView.animator().alphaValue = 1.0
            } completionHandler: {
                self.onLoaded?()
            }
        }
    }

    /// Extract content between start and end tags.
    private func extractTagContent(tag: String, from html: String) -> String {
        let startTag = "<\(tag)>"
        let endTag = "</\(tag)>"
        guard let start = html.range(of: startTag, options: .caseInsensitive),
              let end = html.range(of: endTag, options: .caseInsensitive) else {
            return tag == "body" ? html : ""
        }
        return String(html[start.upperBound..<end.lowerBound])
    }
}
