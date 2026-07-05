//
//  EtherpadExporter.swift
//  LiquidConvert
//
//  Builds Etherpad-compatible HTML from Markdown and handles file export.
//

import Foundation
import UniformTypeIdentifiers

/// Transforms Markdown with inline `<img>` tags into an Etherpad-importable HTML document.
enum EtherpadExporter {

    /// Build the rendered (preview) HTML document.
    static func buildRenderedHTML(from markdown: String) -> String {
        let bodyContent = markdownToHTML(normalizeMarkdownSpacing(markdown))
        return wrapInHTMLDocument(body: bodyContent)
    }

    /// Build the export HTML document preserving Markdown syntax as editable text.
    static func buildRawHTML(from markdown: String) -> String {
        let bodyContent = escapedMarkdownToHTML(normalizeMarkdownSpacing(markdown))
        return wrapInHTMLDocument(body: bodyContent)
    }

    /// Collapse editor-exported spacer lines while preserving Markdown paragraph breaks.
    static func normalizeMarkdownSpacing(_ markdown: String) -> String {
        let lines = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        var normalized: [String] = []
        var previousWasBlank = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let isBlank = trimmed.isEmpty || trimmed == ">"
            if isBlank {
                if !previousWasBlank && !normalized.isEmpty {
                    normalized.append("")
                }
                previousWasBlank = true
            } else {
                normalized.append(line)
                previousWasBlank = false
            }
        }

        while normalized.last?.isEmpty == true {
            normalized.removeLast()
        }

        return normalized.joined(separator: "\n")
    }

    /// Common HTML wrapper for both modes.
    private static func wrapInHTMLDocument(body: String) -> String {
        """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <title>Lark2Pad Export</title>
        <meta name="generator" content="Etherpad">
        <style>
        body { font-family: sans-serif; line-height: 1.6; }
        h1, h2, h3, h4, h5, h6 { margin-top: 20px; margin-bottom: 10px; font-weight: bold; }
        h1 { font-size: 2em; }
        h2 { font-size: 1.5em; }
        h3 { font-size: 1.2em; }
        ol { counter-reset: item; padding-left: 20px; }
        ol > li { display: block; counter-increment: item; margin-bottom: 5px; }
        ol > li:before { content: counters(item, ".") ". "; font-weight: bold; }
        ul { padding-left: 20px; list-style-type: disc; margin-bottom: 15px; }
        li { margin-bottom: 5px; }
        img { max-width: 100%; margin: 10px 0; }
        strong, b { font-weight: bold; }
        </style>
        </head>
        <body>
        \(body)
        </body>
        </html>
        """
    }

    private static func escapedMarkdownToHTML(_ markdown: String) -> String {
        markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { line in
                if let imageTag = sanitizedImageTag(from: line) {
                    return imageTag
                }
                return htmlEscaped(line)
            }
            .joined(separator: "<br>\n")
    }

    private static func htmlEscaped(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func sanitizedImageTag(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.range(
            of: #"^<img\b[^>]*>$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil else {
            return nil
        }

        guard let src = firstAttribute("src", in: trimmed),
              isAllowedImageSource(src) else {
            return nil
        }

        let name = firstAttribute("name", in: trimmed)
        let escapedSrc = htmlEscaped(src)
        if let name, !name.isEmpty {
            return "<img src=\"\(escapedSrc)\" name=\"\(htmlEscaped(name))\">"
        }
        return "<img src=\"\(escapedSrc)\">"
    }

    private static func firstAttribute(_ name: String, in tag: String) -> String? {
        let pattern = #"\b"# + NSRegularExpression.escapedPattern(for: name) + #"\s*=\s*(['"])(.*?)\1"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let nsString = tag as NSString
        let range = NSRange(location: 0, length: nsString.length)
        guard let match = regex.firstMatch(in: tag, options: [], range: range),
              match.numberOfRanges > 2 else {
            return nil
        }
        return nsString.substring(with: match.range(at: 2))
    }

    private static func isAllowedImageSource(_ src: String) -> Bool {
        let lowercased = src.lowercased()
        return lowercased.hasPrefix("https://")
            || lowercased.hasPrefix("http://")
            || lowercased.hasPrefix("data:image/")
            || lowercased.hasPrefix("file://")
    }

    /// Convert Markdown to basic HTML tags.
    private static func markdownToHTML(_ markdown: String) -> String {
        let lines = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        
        var result = ""
        var inList = false
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            // Handle empty lines
            if trimmed.isEmpty {
                if inList { result += "</ul>\n"; inList = false }
                result += "<p><br></p>\n"
                continue
            }

            // 1. Headers
            if let (tag, content) = parseHeader(trimmed) {
                if inList { result += "</ul>\n"; inList = false }
                result += "<\(tag)>\(parseInline(content))</\(tag)>\n"
                continue
            }

            // 2. Unordered Lists
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                if !inList { result += "<ul>\n"; inList = true }
                let content = parseInline(String(trimmed.dropFirst(2)))
                result += "<li>\(content)</li>\n"
                continue
            } else if inList {
                result += "</ul>\n"
                inList = false
            }

            // 3. HTML tags / Images
            if trimmed.hasPrefix("<") {
                result += line + "\n"
                continue
            }

            // 4. Blockquotes
            if trimmed.hasPrefix("> ") {
                let content = parseInline(String(trimmed.dropFirst(2)))
                result += "<blockquote>\(content)</blockquote>\n"
                continue
            }

            if trimmed == ">" {
                continue
            }

            // 5. Normal paragraphs
            result += "<p>\(parseInline(line))</p>\n"
        }
        
        if inList { result += "</ul>\n" }
        return result
    }

    /// Detects if a line is a header and returns (tag, content).
    private static func parseHeader(_ line: String) -> (tag: String, content: String)? {
        for i in (1...6).reversed() {
            let hashes = String(repeating: "#", count: i)
            let pattern = "^\(hashes)\\s+(.+)$"
            if let range = line.range(of: pattern, options: .regularExpression) {
                let content = line[range].replacingOccurrences(of: "^\(hashes)\\s+", with: "", options: .regularExpression)
                return ("h\(i)", content)
            }
        }
        return nil
    }

    /// Parse inline styles: images, links, bold, italic.
    private static func parseInline(_ text: String) -> String {
        var result = text
        // Images: ![alt](url) → <img> (must come before link rule since ![ is a superset of [)
        result = result.replacingOccurrences(of: "!\\[([^\\]]*)\\]\\(([^)]+)\\)", with: "<img src=\"$2\" name=\"$1\">", options: .regularExpression)
        // Links: [text](url) → <a>
        result = result.replacingOccurrences(of: "\\[([^\\]]+)\\]\\(([^)]+)\\)", with: "<a href=\"$2\">$1</a>", options: .regularExpression)
        // Bold: **Bold**
        result = result.replacingOccurrences(of: "\\*\\*(.+?)\\*\\*", with: "<strong>$1</strong>", options: .regularExpression)
        // Italic: *Italic*
        result = result.replacingOccurrences(of: "\\*(.+?)\\*", with: "<em>$1</em>", options: .regularExpression)
        return result
    }

    /// Generate a default filename with date.
    static func defaultFilename() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        let dateString = formatter.string(from: Date())
        return "Lark2Pad_\(dateString).html"
    }

    /// The UTType for the exported file.
    static var exportUTType: UTType { .html }
}
