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
        config.suppressesIncrementalRendering = false
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
            let imgBorderRadius = (UserDefaults.standard.object(forKey: "lark2pad_round_images") == nil || UserDefaults.standard.bool(forKey: "lark2pad_round_images")) ? "8px" : "0"
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
            img { max-width: 100%; border-radius: \(imgBorderRadius); margin: 10px 0; }
            img[data-lazy-image="true"] {
                min-height: 180px;
                background: rgba(127, 127, 127, 0.10);
            }
        """
        let previewBody = lazyLoadedPreviewBody(extractTagContent(tag: "body", from: html))
        let lazyLoadScript = """
            <script>
            (() => {
                const loadImage = (img) => {
                    const src = img.dataset.src;
                    if (!src) return;
                    img.src = src;
                    img.removeAttribute('data-src');
                    img.removeAttribute('data-lazy-image');
                };

                const lazyImages = Array.from(document.querySelectorAll('img[data-src]'));
                if (!('IntersectionObserver' in window)) {
                    lazyImages.forEach(loadImage);
                    return;
                }

                const observer = new IntersectionObserver((entries) => {
                    entries.forEach((entry) => {
                        if (!entry.isIntersecting) return;
                        loadImage(entry.target);
                        observer.unobserve(entry.target);
                    });
                }, { rootMargin: '900px 0px' });

                lazyImages.forEach((img) => observer.observe(img));
            })();
            </script>
        """

        let styledHTML = """
        <!doctype html>
        <html>
        <head>
            <meta charset="utf-8">
            <style>\(extractedStyles)\n\(localCSS)</style>
        </head>
        <body>\(previewBody)\(lazyLoadScript)</body>
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

    private func lazyLoadedPreviewBody(_ body: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"<img\b([^>]*?)\bsrc=(["'])(.*?)\2([^>]*)>"#,
            options: [.caseInsensitive]
        ) else {
            return body
        }

        let nsBody = body as NSString
        let matches = regex.matches(in: body, options: [], range: NSRange(location: 0, length: nsBody.length))
        guard matches.count > 3 else { return body }

        let placeholder = "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='24' height='16'%3E%3C/svg%3E"
        var result = nsBody

        for (index, match) in matches.enumerated().reversed() {
            guard index >= 3,
                  match.numberOfRanges > 4 else {
                continue
            }

            let beforeSrc = nsBody.substring(with: match.range(at: 1))
            let quote = nsBody.substring(with: match.range(at: 2))
            let src = nsBody.substring(with: match.range(at: 3))
            let afterSrc = nsBody.substring(with: match.range(at: 4))
            let replacement = """
            <img\(beforeSrc)src=\(quote)\(placeholder)\(quote) data-src=\(quote)\(htmlEscaped(src))\(quote) data-lazy-image="true" loading="lazy" decoding="async"\(afterSrc)>
            """
            result = result.replacingCharacters(in: match.range, with: replacement) as NSString
        }

        return result as String
    }

    private func htmlEscaped(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
