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
        let bodyContent = markdownToHTML(markdown)
        return wrapInHTMLDocument(body: bodyContent)
    }

    /// Build the raw (export) HTML document preserving Markdown syntax.
    static func buildRawHTML(from markdown: String) -> String {
        let bodyContent = markdown
            .replacingOccurrences(of: "\n", with: "<br>\n")
        return wrapInHTMLDocument(body: bodyContent)
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
        img { max-width: 100%; margin: 10px 0; border-radius: 4px; }
        strong, b { font-weight: bold; }
        </style>
        </head>
        <body>
        \(body)
        </body>
        </html>
        """
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

    /// Parse inline styles like bold and italic.
    private static func parseInline(_ text: String) -> String {
        var result = text
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
