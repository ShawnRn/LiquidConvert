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

    /// Build HTML document formatted specifically for WordPress / CMS editor pasting.
    static func buildWordPressHTML(from markdown: String) -> String {
        let lines = normalizeMarkdownSpacing(markdown)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        // Pre-scan for slider blocks (bidirectional image collection)
        var sliderBlocks: [Int: SliderBlock] = [:]
        var processedIndices = Set<Int>()

        for i in 0..<lines.count {
            if processedIndices.contains(i) { continue }
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            let stripped = trimmed
                .replacingOccurrences(of: "*", with: "")
                .replacingOccurrences(of: ">", with: "")
                .replacingOccurrences(of: "#", with: "")
                .trimmingCharacters(in: .whitespaces)

            let isHoriz = stripped.contains("左右滑动")
            let isVert = stripped.contains("上下滑动")

            if isHoriz || isVert {
                var startIdx = i
                var endIdx = i
                var urls: [String] = []

                // Look backwards
                var prevIdx = i - 1
                var backURLs: [String] = []
                while prevIdx >= 0 {
                    let candidateTrimmed = lines[prevIdx].trimmingCharacters(in: .whitespaces)
                    if candidateTrimmed.isEmpty {
                        prevIdx -= 1
                        continue
                    }
                    if let u = extractImageURL(from: lines[prevIdx]) {
                        backURLs.insert(u, at: 0)
                        startIdx = prevIdx
                        prevIdx -= 1
                    } else {
                        break
                    }
                }
                urls.append(contentsOf: backURLs)

                // Look forwards
                var nextIdx = i + 1
                while nextIdx < lines.count {
                    let candidateTrimmed = lines[nextIdx].trimmingCharacters(in: .whitespaces)
                    if candidateTrimmed.isEmpty {
                        nextIdx += 1
                        continue
                    }
                    if let u = extractImageURL(from: lines[nextIdx]) {
                        urls.append(u)
                        endIdx = nextIdx
                        nextIdx += 1
                    } else {
                        break
                    }
                }

                if !urls.isEmpty {
                    let kind: SliderBlock.Kind = isHoriz ? .horizontal : .vertical
                    sliderBlocks[startIdx] = SliderBlock(endIndex: endIdx, kind: kind, urls: urls)
                    for k in startIdx...endIdx {
                        processedIndices.insert(k)
                    }
                }
            }
        }

        var result = ""
        var inList = false
        var index = 0

        while index < lines.count {
            if let block = sliderBlocks[index] {
                if inList { result += "</ul>\n\n"; inList = false }
                switch block.kind {
                case .horizontal:
                    result += buildHorizontalSliderHTML(imageURLs: block.urls) + "\n\n"
                case .vertical:
                    result += buildVerticalSliderHTML(imageURLs: block.urls) + "\n\n"
                }
                index = block.endIndex + 1
                continue
            }

            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                if inList { result += "</ul>\n\n"; inList = false }
                index += 1
                continue
            }

            // Callout / Highlight Blocks (<section data-type="callout"> or <callout>)
            let lowerTrimmed = trimmed.lowercased()
            if lowerTrimmed.hasPrefix("<section data-type=\"callout\"") || lowerTrimmed.hasPrefix("<callout") {
                if inList { result += "</ul>\n\n"; inList = false }
                var calloutLines: [String] = []
                let endTag = lowerTrimmed.hasPrefix("<callout") ? "</callout>" : "</section>"
                var subIdx = index

                while subIdx < lines.count {
                    let currentLine = lines[subIdx]
                    let currentLower = currentLine.trimmingCharacters(in: .whitespaces).lowercased()

                    let cleaned = currentLine
                        .replacingOccurrences(of: "<section data-type=\"callout\">", with: "", options: .caseInsensitive)
                        .replacingOccurrences(of: "</section>", with: "", options: .caseInsensitive)
                        .replacingOccurrences(of: "<callout>", with: "", options: .caseInsensitive)
                        .replacingOccurrences(of: "</callout>", with: "", options: .caseInsensitive)
                        .trimmingCharacters(in: .whitespaces)

                    if !cleaned.isEmpty {
                        calloutLines.append(cleaned)
                    }

                    if currentLower.contains(endTag) {
                        subIdx += 1
                        break
                    }
                    subIdx += 1
                }

                if !calloutLines.isEmpty {
                    result += buildCalloutCardHTML(lines: calloutLines) + "\n\n"
                    index = subIdx
                    continue
                }
            }

            // Headers (h3 default for WordPress sections)
            if let (_, level, content) = parseHeaderWithLevel(trimmed) {
                if inList { result += "</ul>\n\n"; inList = false }
                let parsedContent = parseInline(content)
                result += "<h\(level)>\(parsedContent)</h\(level)>\n\n"
                index += 1
                continue
            }

            // Lists
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                if !inList { result += "<ul>\n"; inList = true }
                let content = parseInline(String(trimmed.dropFirst(2)))
                result += " \t<li>\(content)</li>\n"
                index += 1
                continue
            } else if inList {
                result += "</ul>\n\n"
                inList = false
            }

            // Captions (WordPress editor-image-source style)
            if isCaptionText(trimmed) {
                let caption = normalizeCaptionText(trimmed)
                result += "<div class=\"editor-image-source\">\n\n\(caption)\n\n</div>\n\n"
                index += 1
                continue
            }

            // Standalone Images
            if let (alt, url) = parseStandaloneImageData(trimmed) {
                result += "<p><img src=\"\(htmlEscaped(url))\" alt=\"\(htmlEscaped(alt))\" /></p>\n\n"
                index += 1
                continue
            }

            // Blockquotes (WordPress <blockquote>)
            if trimmed.hasPrefix("> ") {
                let content = parseInline(String(trimmed.dropFirst(2)))
                result += "<blockquote>\(content)</blockquote>\n\n"
                index += 1
                continue
            }

            // HTML raw line
            if trimmed.hasPrefix("<") {
                result += line + "\n\n"
                index += 1
                continue
            }

            // Normal paragraphs
            let content = parseInline(line)
            result += "<p>\(content)</p>\n\n"
            index += 1
        }

        if inList { result += "</ul>\n" }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseStandaloneImageData(_ line: String) -> (alt: String, url: String)? {
        let pattern = "^!\\[([^\\]]*)\\]\\(([^)]+)\\)$"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let nsString = line as NSString
        let range = NSRange(location: 0, length: nsString.length)
        guard let match = regex.firstMatch(in: line, options: [], range: range), match.numberOfRanges > 2 else {
            return nil
        }
        let alt = nsString.substring(with: match.range(at: 1))
        let url = nsString.substring(with: match.range(at: 2))
        return (alt, url)
    }

    /// Build HTML document with fully inlined CSS styles optimized for pasting into WeChat Official Account editor (Async image base64 guaranteed).
    static func buildWeChatHTMLAsync(
        from markdown: String,
        roundImages: Bool = true,
        addHeaderBanner: Bool = false,
        addFooterBanner: Bool = false
    ) async -> String {
        var bodyContent = markdownToWeChatHTML(
            normalizeMarkdownSpacing(markdown),
            roundImages: roundImages,
            addHeaderBanner: addHeaderBanner,
            addFooterBanner: addFooterBanner
        )
        bodyContent = await ImageUploader.convertImageURLsToBase64DataURIsAsync(in: bodyContent)
        return """
        <!doctype html>
        <html lang="zh-CN">
        <head>
        <meta charset="utf-8">
        <title>Lark2Pad WeChat Export</title>
        </head>
        <body style="font-family: -apple-system, BlinkMacSystemFont, &quot;Helvetica Neue&quot;, &quot;PingFang SC&quot;, &quot;Hiragino Sans GB&quot;, &quot;Microsoft YaHei UI&quot;, &quot;Microsoft YaHei&quot;, Arial, sans-serif; font-size: 16px; color: #333333; line-height: 1.6; letter-spacing: 0.5px; background-color: #ffffff; padding: 10px; margin: 0;">
        \(bodyContent)
        </body>
        </html>
        """
    }

    /// Build HTML document with fully inlined CSS styles optimized for pasting into WeChat Official Account editor.
    static func buildWeChatHTML(
        from markdown: String,
        roundImages: Bool = true,
        addHeaderBanner: Bool = false,
        addFooterBanner: Bool = false
    ) -> String {
        var bodyContent = markdownToWeChatHTML(
            normalizeMarkdownSpacing(markdown),
            roundImages: roundImages,
            addHeaderBanner: addHeaderBanner,
            addFooterBanner: addFooterBanner
        )
        bodyContent = ImageUploader.convertImageURLsToBase64DataURIs(in: bodyContent)
        return """
        <!doctype html>
        <html lang="zh-CN">
        <head>
        <meta charset="utf-8">
        <title>Lark2Pad WeChat Export</title>
        </head>
        <body>
        <section style="font-family: mp-quote, -apple-system-font, BlinkMacSystemFont, 'PingFang SC', 'Hiragino Sans GB', 'Microsoft YaHei UI', 'Microsoft YaHei', Arial, sans-serif; font-size: 15px; color: #333333; line-height: 1.75; text-align: justify; word-break: break-all; word-wrap: break-word;">
        \(bodyContent)
        </section>
        </body>
        </html>
        """
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
        body { font-family: -apple-system, BlinkMacSystemFont, "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", sans-serif; line-height: 1.6; color: #222222; }
        h1, h2, h3, h4, h5, h6 { margin-top: 20px; margin-bottom: 10px; font-weight: bold; }
        h1 { font-size: 2em; }
        h2 { font-size: 1.5em; }
        h3 { font-size: 1.2em; }
        ol { counter-reset: item; padding-left: 20px; }
        ol > li { display: block; counter-increment: item; margin-bottom: 5px; }
        ol > li:before { content: counters(item, ".") ". "; font-weight: bold; }
        ul { padding-left: 20px; list-style-type: disc; margin-bottom: 15px; }
        li { margin-bottom: 5px; }
        img { max-width: 100%; margin: 8px 0; border-radius: 6px; }
        strong, b { font-weight: bold; }
        [data-image-caption="true"], .image-caption, span.image-caption {
            display: inline-block;
            width: 100%;
            font-family: PingFangSC-Regular, sans-serif;
            font-size: 12px;
            color: rgb(167, 167, 167);
            letter-spacing: 0px;
            text-align: center;
            margin-top: 4px;
            margin-bottom: 12px;
        }
        </style>
        </head>
        <body>
        \(body)
        </body>
        </html>
        """
    }

    private static func parseStandaloneImageTag(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let pattern = "^!\\[([^\\]]*)\\]\\(([^)]+)\\)$"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let nsString = trimmed as NSString
        let range = NSRange(location: 0, length: nsString.length)
        guard let match = regex.firstMatch(in: trimmed, options: [], range: range), match.numberOfRanges > 2 else {
            return nil
        }
        let alt = nsString.substring(with: match.range(at: 1))
        let url = nsString.substring(with: match.range(at: 2))
        let escapedUrl = htmlEscaped(url)
        let escapedAlt = htmlEscaped(alt)
        if !escapedAlt.isEmpty {
            return "<img src=\"\(escapedUrl)\" name=\"\(escapedAlt)\">"
        }
        return "<img src=\"\(escapedUrl)\">"
    }

    private static func escapedMarkdownToHTML(_ markdown: String) -> String {
        let rawLines = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        var result = ""
        var i = 0

        while i < rawLines.count {
            let line = rawLines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            let imgHTML = sanitizedImageTag(from: line) ?? parseStandaloneImageTag(line)
            if let imgHTML {
                result += imgHTML

                // Look ahead for caption, bypassing intermediate empty lines
                var nextIdx = i + 1
                while nextIdx < rawLines.count && rawLines[nextIdx].trimmingCharacters(in: .whitespaces).isEmpty {
                    nextIdx += 1
                }

                if nextIdx < rawLines.count {
                    let nextTrimmed = rawLines[nextIdx].trimmingCharacters(in: .whitespaces)
                    if isCaptionText(nextTrimmed) {
                        let caption = normalizeCaptionText(nextTrimmed)
                        let captionStyle = "display: block; width: 100%; font-family: PingFangSC-Regular; font-size: 12px; color: rgb(167, 167, 167); text-align: center;"
                        result += "\n<span class=\"image-caption\" data-image-caption=\"true\" style=\"\(captionStyle)\">\(htmlEscaped(caption))</span><br>\n"
                        i = nextIdx + 1
                        continue
                    }
                }

                result += "<br>\n"
                i += 1
                continue
            }

            if isCaptionText(trimmed) {
                let caption = normalizeCaptionText(trimmed)
                let captionStyle = "display: block; width: 100%; font-family: PingFangSC-Regular; font-size: 12px; color: rgb(167, 167, 167); text-align: center;"
                result += "<span class=\"image-caption\" data-image-caption=\"true\" style=\"\(captionStyle)\">\(htmlEscaped(caption))</span><br>\n"
                i += 1
                continue
            }

            result += htmlEscaped(line) + "<br>\n"
            i += 1
        }

        return result
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
        
        // Pre-scan for slider blocks (bidirectional image collection)
        var sliderBlocks: [Int: SliderBlock] = [:]
        var processedIndices = Set<Int>()

        for i in 0..<lines.count {
            if processedIndices.contains(i) { continue }
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            let stripped = trimmed
                .replacingOccurrences(of: "*", with: "")
                .replacingOccurrences(of: ">", with: "")
                .replacingOccurrences(of: "#", with: "")
                .trimmingCharacters(in: .whitespaces)

            let isHoriz = stripped.contains("左右滑动")
            let isVert = stripped.contains("上下滑动")

            if isHoriz || isVert {
                var startIdx = i
                var endIdx = i
                var urls: [String] = []

                // Look backwards
                var prevIdx = i - 1
                var backURLs: [String] = []
                while prevIdx >= 0 {
                    let candidateTrimmed = lines[prevIdx].trimmingCharacters(in: .whitespaces)
                    if candidateTrimmed.isEmpty {
                        prevIdx -= 1
                        continue
                    }
                    if let u = extractImageURL(from: lines[prevIdx]) {
                        backURLs.insert(u, at: 0)
                        startIdx = prevIdx
                        prevIdx -= 1
                    } else {
                        break
                    }
                }
                urls.append(contentsOf: backURLs)

                // Look forwards
                var nextIdx = i + 1
                while nextIdx < lines.count {
                    let candidateTrimmed = lines[nextIdx].trimmingCharacters(in: .whitespaces)
                    if candidateTrimmed.isEmpty {
                        nextIdx += 1
                        continue
                    }
                    if let u = extractImageURL(from: lines[nextIdx]) {
                        urls.append(u)
                        endIdx = nextIdx
                        nextIdx += 1
                    } else {
                        break
                    }
                }

                if !urls.isEmpty {
                    let kind: SliderBlock.Kind = isHoriz ? .horizontal : .vertical
                    sliderBlocks[startIdx] = SliderBlock(endIndex: endIdx, kind: kind, urls: urls)
                    for k in startIdx...endIdx {
                        processedIndices.insert(k)
                    }
                }
            }
        }

        var result = ""
        var inList = false
        var index = 0

        while index < lines.count {
            if let block = sliderBlocks[index] {
                if inList { result += "</ul>\n"; inList = false }
                switch block.kind {
                case .horizontal:
                    result += buildHorizontalSliderHTML(imageURLs: block.urls) + "\n"
                case .vertical:
                    result += buildVerticalSliderHTML(imageURLs: block.urls) + "\n"
                }
                index = block.endIndex + 1
                continue
            }

            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            // Handle empty lines
            if trimmed.isEmpty {
                if inList { result += "</ul>\n"; inList = false }
                result += "<p><br></p>\n"
                index += 1
                continue
            }

            // Callout / Highlight Blocks (<section data-type="callout"> or <callout>)
            let lowerTrimmed = trimmed.lowercased()
            if lowerTrimmed.hasPrefix("<section data-type=\"callout\"") || lowerTrimmed.hasPrefix("<callout") {
                if inList { result += "</ul>\n"; inList = false }
                var calloutLines: [String] = []
                let endTag = lowerTrimmed.hasPrefix("<callout") ? "</callout>" : "</section>"
                var subIdx = index
                var foundEnd = false

                while subIdx < lines.count {
                    let currentLine = lines[subIdx]
                    let currentTrimmed = currentLine.trimmingCharacters(in: .whitespaces)
                    let currentLower = currentTrimmed.lowercased()

                    let cleaned = currentLine
                        .replacingOccurrences(of: "<section data-type=\"callout\">", with: "", options: .caseInsensitive)
                        .replacingOccurrences(of: "</section>", with: "", options: .caseInsensitive)
                        .replacingOccurrences(of: "<callout>", with: "", options: .caseInsensitive)
                        .replacingOccurrences(of: "</callout>", with: "", options: .caseInsensitive)
                        .trimmingCharacters(in: .whitespaces)

                    if !cleaned.isEmpty {
                        calloutLines.append(cleaned)
                    }

                    if currentLower.contains(endTag) && subIdx > index {
                        foundEnd = true
                        subIdx += 1
                        break
                    }
                    if currentLower.contains(endTag) && subIdx == index && (currentLower.components(separatedBy: endTag).count > 2 || !cleaned.isEmpty) {
                        foundEnd = true
                        subIdx += 1
                        break
                    }
                    subIdx += 1
                }

                if !calloutLines.isEmpty {
                    result += buildCalloutCardHTML(lines: calloutLines, imgRadius: "8px") + "\n"
                    index = subIdx
                    continue
                }
            }

            // 1. Headers
            if let (tag, content) = parseHeader(trimmed) {
                if inList { result += "</ul>\n"; inList = false }
                result += "<\(tag)>\(parseInline(content))</\(tag)>\n"
                index += 1
                continue
            }

            // 2. Unordered Lists
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                if !inList { result += "<ul>\n"; inList = true }
                let content = parseInline(String(trimmed.dropFirst(2)))
                result += "<li>\(content)</li>\n"
                index += 1
                continue
            } else if inList {
                result += "</ul>\n"
                inList = false
            }

            // 3. HTML tags / Images
            if trimmed.hasPrefix("<") {
                result += line + "\n"
                index += 1
                continue
            }

            // 4. Blockquotes
            if trimmed.hasPrefix("> ") {
                let content = parseInline(String(trimmed.dropFirst(2)))
                result += "<blockquote>\(content)</blockquote>\n"
                index += 1
                continue
            }

            // 5. Image Captions
            if isCaptionText(trimmed) {
                if inList { result += "</ul>\n"; inList = false }
                let caption = normalizeCaptionText(trimmed)
                let captionStyle = "display: inline-block; width: 100%; font-family: PingFangSC-Regular; font-weight: 400; font-size: 12px; color: rgb(167, 167, 167); letter-spacing: 0px; text-align: center; margin-top: 0px !important; margin-bottom: 12px; line-height: 1.2;"
                result += "<div style=\"margin-top: -6px; margin-bottom: 12px;\"><span class=\"image-caption\" style=\"\(captionStyle)\">\(parseInline(caption))</span></div>\n"
                index += 1
                continue
            }

            // 6. Normal paragraphs
            result += "<p>\(parseInline(line))</p>\n"
            index += 1
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

    private static let defaultHeaderBannerURL = "https://mmbiz.qpic.cn/mmbiz_gif/fc90sFPPBCMNz9EtBfUDyjCYbZMtTTBiaUAWvglz5a8etUicmQFMtJn68NOxWbdRBgPTn3ic4tbT1MwKfzoV1P7m36Kmtm8QiaPQHr5jLkqa2Dw/640?wx_fmt=gif&from=appmsg"

    private static func buildHeaderBannerHTML(imgRadius: String) -> String {
        "<section style=\"text-align: left;justify-content: flex-start;display: flex;flex-flow: row;margin: 0px 0px 24px 0px;width: 100%;align-self: flex-start;background-color: rgb(255, 113, 20);border-radius: 10px;overflow: hidden;box-sizing: border-box;\"><section style=\"text-align: center;line-height: 0;width: 100%;box-sizing: border-box;\"><section style=\"max-width: 100%;vertical-align: middle;display: inline-block;line-height: 0;box-sizing: border-box;\" nodeleaf=\"\"><img src=\"\(defaultHeaderBannerURL)\" class=\"rich_pages wxw-img\" data-ratio=\"0.5333333333333333\" data-type=\"gif\" data-w=\"720\" style=\"vertical-align: middle;max-width: 100%;width: 100%;box-sizing: border-box;\"></section></section></section>\n"
    }

    private static let weChatFooterBannerHTML = """
    <p style="margin-left: 16px;margin-right: 16px;margin-bottom: 0px;"><span style="color: rgba(0, 0, 0, 0.9);font-size: 12px;font-weight: bold;font-family: mp-quote, &quot;PingFang SC&quot;, system-ui, -apple-system, BlinkMacSystemFont, &quot;Helvetica Neue&quot;, &quot;Hiragino Sans GB&quot;, &quot;Microsoft YaHei UI&quot;, &quot;Microsoft YaHei&quot;, Arial, sans-serif;line-height: 1.6;letter-spacing: 0.034em;">作者｜ifanr</span></p>
    <p style="margin-left: 16px;margin-right: 16px;margin-bottom: 24px;"><span style="color: rgba(0, 0, 0, 0.9);font-size: 12px;font-weight: bold;font-family: mp-quote, &quot;PingFang SC&quot;, system-ui, -apple-system, BlinkMacSystemFont, &quot;Helvetica Neue&quot;, &quot;Hiragino Sans GB&quot;, &quot;Microsoft YaHei UI&quot;, &quot;Microsoft YaHei&quot;, Arial, sans-serif;line-height: 1.6;letter-spacing: 0.034em;">编辑｜ifanr</span></p>
    <section style="text-align: center;line-height: 0;box-sizing: border-box;"><section style="max-width: 100%;vertical-align: middle;display: inline-block;line-height: 0;box-sizing: border-box;" nodeleaf=""><img src="https://mmbiz.qpic.cn/sz_mmbiz_png/fc90sFPPBCO5sTlJseFUfia8Hu5P9EWwc4YHFvbFXrYWWDVxISzy2Vl3HGU4ibnqLPR6U8BgFRGxhS86OwDH6OCMnIDr4UnyEhYy6dTib2qiaBA/640?wx_fmt=png" class="rich_pages wxw-img" data-ratio="0.05804" data-s="300,640" data-w="1051" style="vertical-align:middle;max-width:100%;width:100%;box-sizing:border-box;" width="100%"></section></section>
    <p style="white-space: normal;margin: 0px;padding: 0px;box-sizing: border-box;"></p>
    <section style="text-align: left;justify-content: flex-start;display: flex;flex-flow: row;box-sizing: border-box;"><section style="display: inline-block;width: 100%;vertical-align: top;align-self: flex-start;flex: 0 0 auto;background-repeat: repeat;background-attachment: scroll;border-radius: 10px;overflow: hidden;background-image: url(&quot;https://mmbiz.qpic.cn/mmbiz_png/fc90sFPPBCMRTjiay36FKj1KwiaibBpEPbK583nGuBnJjNNeR13rq3IA6sia1fzibcJKicGLZcIfTOVU00ATFq7mmDMSKd18TqTmZzT7EmGykuQbk/640?wx_fmt=png&quot;);box-sizing: border-box;background-position: 0% 0% !important;background-size: auto !important;"><section style="justify-content: flex-start;display: flex;flex-flow: row;margin: 50px 0px 0px;box-sizing: border-box;"><section style="display: inline-block;width: 100%;vertical-align: top;align-self: flex-start;flex: 0 0 auto;box-sizing: border-box;"><section style="text-align: center;line-height: 0;box-sizing: border-box;"><section style="max-width: 100%;vertical-align: middle;display: inline-block;line-height: 0;box-sizing: border-box;" nodeleaf=""><img src="https://mmbiz.qpic.cn/sz_mmbiz_png/fc90sFPPBCP8MG80wljJC4cT2s8YibQ2t5hoaVEAoIZ8ftGmllAI5ehMD28ExTwBdfsibfyOqZBmTyjhrdXklbqcCa3CeMiaAXdeyzjKY11lIE/640?wx_fmt=png" class="rich_pages wxw-img" data-ratio="0.6003805899143673" data-s="300,640" data-w="1051" style="vertical-align: middle;max-width: 100%;width: 100%;box-sizing: border-box;"></section></section></section></section><section style="justify-content: flex-start;display: flex;flex-flow: row;box-sizing: border-box;"><section style="display: inline-block;width: 100%;vertical-align: top;align-self: flex-start;flex: 0 0 auto;box-sizing: border-box;"><section style="text-align: center;line-height: 0;box-sizing: border-box;"><section style="max-width: 100%;vertical-align: middle;display: inline-block;line-height: 0;box-sizing: border-box;"><a href="https://mp.weixin.qq.com/s?__biz=MjgzMTAwODI0MA==&amp;mid=2652396877&amp;idx=2&amp;sn=dfef25453a6bf0dca147b0adca3deaf7&amp;scene=21#wechat_redirect" target="_blank"><span style="width:100%" class="js_jump_icon h5_image_link"><img src="https://mmbiz.qpic.cn/sz_mmbiz_png/fc90sFPPBCPyDFWbJT8y9ibibmFbtvMJbwHxCAZQskte81K91q7QwkwXPevnDR7bvHUD9ntPN43bDibM6svwxrCkBaVruzvjKVBLnTwJYk5pOk/640?wx_fmt=png" class="rich_pages wxw-img" data-ratio="0.14367269267364416" data-s="300,640" data-w="1051" style="vertical-align: middle;max-width: 100%;width: 100%;box-sizing: border-box;"></span></a></section></section><section style="text-align: justify;box-sizing: border-box;"><p style="white-space: normal;margin: 0px;padding: 0px;box-sizing: border-box;"></p></section></section></section></section></section>
    <section style="text-align: center;line-height: 0;box-sizing: border-box;margin-top: 16px;"><section style="max-width: 100%;vertical-align: middle;display: inline-block;line-height: 0;border-radius: 10px;overflow: hidden;box-sizing: border-box;" nodeleaf=""><img src="https://mmbiz.qpic.cn/mmbiz_png/fc90sFPPBCNnChuCqY5TK78KORbHN3ficOaIgpjRfNqQWMJqRxxNGpMb2Om3ebIfpJGIs7nfu2WrCYzYjLkH6qicYms1ibfJbFujmoNFYaavpw/640?wx_fmt=png" class="rich_pages wxw-img" data-ratio="1.3333333333333333" data-s="300,640" data-w="1080" style="vertical-align: middle;max-width: 100%;width: 100%;box-sizing: border-box;"></section></section>
    """

    private static func isCaptionText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("图") else { return false }
        let afterTu = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
        guard let firstChar = afterTu.first else { return false }
        return firstChar == "｜" || firstChar == "|" || firstChar == "：" || firstChar == ":"
    }

    private static func normalizeCaptionText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isCaptionText(trimmed) else { return text }
        let afterTu = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
        let content = afterTu.dropFirst().trimmingCharacters(in: .whitespaces)
        return "图｜\(content)"
    }

    private static func hasNextCaptionLine(from index: Int, in lines: [String]) -> Bool {
        var nextIdx = index + 1
        while nextIdx < lines.count {
            let candidate = lines[nextIdx].trimmingCharacters(in: .whitespaces)
            if candidate.isEmpty {
                nextIdx += 1
                continue
            }
            return isCaptionText(candidate)
        }
        return false
    }

    private static func extractImageURL(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let mdPattern = "^!\\[[^\\]]*\\]\\(([^)]+)\\)$"
        if let regex = try? NSRegularExpression(pattern: mdPattern, options: []),
           let match = regex.firstMatch(in: trimmed, options: [], range: NSRange(location: 0, length: (trimmed as NSString).length)),
           match.numberOfRanges > 1 {
            return (trimmed as NSString).substring(with: match.range(at: 1))
        }
        if trimmed.lowercased().contains("<img"),
           let src = firstAttribute("src", in: trimmed) {
            return src
        }
        return nil
    }

    private static func buildHorizontalSliderHTML(imageURLs: [String]) -> String {
        let count = imageURLs.count
        guard count > 0 else { return "" }
        var itemsHTML = ""
        for url in imageURLs {
            itemsHTML += "<div style=\"display: inline-block; width: 85%; max-width: 85%; margin-right: 10px; vertical-align: top; white-space: normal;\"><img src=\"\(htmlEscaped(url))\" style=\"width: 100%; max-width: 100%; height: auto; border-radius: 8px; display: block;\"></div>"
        }
        return """
        <div style="margin: 26px 0; padding: 0; width: 100%; overflow-x: auto; white-space: nowrap; -webkit-overflow-scrolling: touch; font-size: 0px;" data-type="custom-block">
        \(itemsHTML)</div>
        <p style="margin: 6px 0 20px 0; font-size: 12px; line-height: 17px; color: #a7a7a7; text-align: center;">向左滑动查看更多内容</p>
        """
    }

    private static func buildVerticalSliderHTML(imageURLs: [String]) -> String {
        guard !imageURLs.isEmpty else { return "" }
        var imgsHTML = ""
        for url in imageURLs {
            imgsHTML += "<img src=\"\(htmlEscaped(url))\" style=\"display: block; width: 100%; max-width: 100%; margin: 0; padding: 0; border: none;\">\n"
        }
        return """
        <div style="margin: 26px 0; width: 100%; height: 360px; max-height: 360px; overflow-y: auto; overflow-x: hidden; -webkit-overflow-scrolling: touch; border-radius: 8px; box-sizing: border-box;" data-type="custom-block">
        \(imgsHTML)</div>
        <p style="margin: 6px 0 20px 0; font-size: 12px; line-height: 17px; color: #a7a7a7; text-align: center;">上下滑动查看更多内容</p>
        """
    }

    private static func buildCalloutCardHTML(lines: [String], imgRadius: String = "8px") -> String {
        var innerParagraphs = ""
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            let content = parseWeChatInline(trimmed, imgRadius: imgRadius)
            innerParagraphs += "<p style=\"margin: 0 0 12px 0; padding: 0; line-height: 28px;\"><span>\(content)</span></p>\n"
        }
        guard !innerParagraphs.isEmpty else { return "" }
        return """
        <div style="margin: 26px 0; padding: 20px 18px 8px; font-size: 14px; line-height: 28px; background: #f8f8f8; color: #696969; border-radius: 12px; text-align: justify; box-sizing: border-box;" data-type="custom-block">
        \(innerParagraphs)</div>
        """
    }

    private struct SliderBlock {
        enum Kind {
            case horizontal
            case vertical
        }
        let endIndex: Int
        let kind: Kind
        let urls: [String]
    }

    private static func markdownToWeChatHTML(
        _ markdown: String,
        roundImages: Bool,
        addHeaderBanner: Bool = false,
        addFooterBanner: Bool = false
    ) -> String {
        let lines = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        var result = ""
        let imgRadius = roundImages ? "8px" : "0"

        if addHeaderBanner {
            result += buildHeaderBannerHTML(imgRadius: imgRadius)
        }

        // Pad Exact Spec:
        let pStyle = "margin: 26px 0; padding: 0 14px; font-size: 15px; color: #222222; text-align: justify; line-height: 27px; word-break: break-all; word-wrap: break-word; font-family: &quot;PingFangSC-Light&quot;;"

        // Pre-scan for slider blocks (bidirectional image collection)
        var sliderBlocks: [Int: SliderBlock] = [:]
        var processedIndices = Set<Int>()

        for i in 0..<lines.count {
            if processedIndices.contains(i) { continue }
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            let stripped = trimmed
                .replacingOccurrences(of: "*", with: "")
                .replacingOccurrences(of: ">", with: "")
                .replacingOccurrences(of: "#", with: "")
                .trimmingCharacters(in: .whitespaces)

            let isHoriz = stripped.contains("左右滑动")
            let isVert = stripped.contains("上下滑动")

            if isHoriz || isVert {
                var startIdx = i
                var endIdx = i
                var urls: [String] = []

                // Look backwards
                var prevIdx = i - 1
                var backURLs: [String] = []
                while prevIdx >= 0 {
                    let candidateTrimmed = lines[prevIdx].trimmingCharacters(in: .whitespaces)
                    if candidateTrimmed.isEmpty {
                        prevIdx -= 1
                        continue
                    }
                    if let u = extractImageURL(from: lines[prevIdx]) {
                        backURLs.insert(u, at: 0)
                        startIdx = prevIdx
                        prevIdx -= 1
                    } else {
                        break
                    }
                }
                urls.append(contentsOf: backURLs)

                // Look forwards
                var nextIdx = i + 1
                while nextIdx < lines.count {
                    let candidateTrimmed = lines[nextIdx].trimmingCharacters(in: .whitespaces)
                    if candidateTrimmed.isEmpty {
                        nextIdx += 1
                        continue
                    }
                    if let u = extractImageURL(from: lines[nextIdx]) {
                        urls.append(u)
                        endIdx = nextIdx
                        nextIdx += 1
                    } else {
                        break
                    }
                }

                if !urls.isEmpty {
                    let kind: SliderBlock.Kind = isHoriz ? .horizontal : .vertical
                    sliderBlocks[startIdx] = SliderBlock(endIndex: endIdx, kind: kind, urls: urls)
                    for k in startIdx...endIdx {
                        processedIndices.insert(k)
                    }
                }
            }
        }

        var inWeChatList = false
        var index = 0

        while index < lines.count {
            if let block = sliderBlocks[index] {
                if inWeChatList {
                    result += "</section>\n"
                    inWeChatList = false
                }
                switch block.kind {
                case .horizontal:
                    result += buildHorizontalSliderHTML(imageURLs: block.urls) + "\n"
                case .vertical:
                    result += buildVerticalSliderHTML(imageURLs: block.urls) + "\n"
                }
                index = block.endIndex + 1
                continue
            }

            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Empty lines
            if trimmed.isEmpty {
                if inWeChatList {
                    result += "</section>\n"
                    inWeChatList = false
                }
                index += 1
                continue
            }

            // Lists (supports - , * , ▪ , • , ■ )
            let isListItem = trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("▪ ") || trimmed.hasPrefix("• ") || trimmed.hasPrefix("■ ")
            if isListItem {
                if !inWeChatList {
                    result += "<section style=\"margin: 32px 0; padding: 0 11px;\">\n"
                    inWeChatList = true
                }
                var rawText = trimmed
                if rawText.hasPrefix("- ") || rawText.hasPrefix("* ") || rawText.hasPrefix("▪ ") || rawText.hasPrefix("• ") || rawText.hasPrefix("■ ") {
                    rawText = String(rawText.dropFirst(2))
                }
                let content = parseWeChatInline(rawText, imgRadius: imgRadius)
                let itemStyle = "display: flex; margin-bottom: 8px; font-family: &quot;PingFangSC-Light&quot;; font-size: 15px; color: #363636; letter-spacing: 0; text-align: justify; line-height: 27px;"
                let dotStyle = "margin-top: 10px; margin-right: 12px; width: 6px; height: 6px; background: #363636;"
                result += "<section style=\"\(itemStyle)\"><section style=\"\(dotStyle)\"></section><section style=\"flex: 1;\">\(content)</section></section>\n"
                index += 1
                continue
            } else if inWeChatList {
                result += "</section>\n"
                inWeChatList = false
            }

            // Standalone Markdown Images: ![alt](url)
            let hasCaption = hasNextCaptionLine(from: index, in: lines)
            if let imageSection = parseStandaloneImage(trimmed, imgRadius: imgRadius, hasCaption: hasCaption) {
                result += imageSection + "\n"
                index += 1
                continue
            }

            // Image Caption Line: 图｜...
            if isCaptionText(trimmed) {
                let caption = normalizeCaptionText(trimmed)
                let content = parseWeChatInline(caption, imgRadius: imgRadius)
                let captionStyle = "display: inline-block; width: 100%; font-family: &quot;PingFang SC&quot;, system-ui, -apple-system, BlinkMacSystemFont, &quot;Helvetica Neue&quot;, Helvetica, Tahoma, Arial, &quot;Heiti SC&quot;, STHeiti, SimHei, sans-serif; font-weight: 400; font-size: 12px; color: rgb(167, 167, 167); letter-spacing: 0px; text-align: left; margin-left: 16px; margin-right: 16px; margin-bottom: 24px;"
                result += "<section style=\"\(captionStyle)\" data-type=\"custom-block\">\(content)</section>\n"
                index += 1
                continue
            }

            // Headers
            if let header = parseHeaderWithLevel(trimmed) {
                let (_, level, rawContent) = header
                var content = rawContent
                if content.hasPrefix("**") && content.hasSuffix("**") && content.count > 4 {
                    content = String(content.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
                }

                let fontSize: String
                let lineHeight: String
                let margin: String
                switch level {
                case 1:
                    fontSize = "24px"; lineHeight = "32px"; margin = "62px 0 26px 0"
                case 2:
                    fontSize = "22px"; lineHeight = "30px"; margin = "62px 0 26px 0"
                case 3:
                    fontSize = "20px"; lineHeight = "28px"; margin = "62px 0 26px 0"
                default:
                    fontSize = "18px"; lineHeight = "26px"; margin = "42px 0 22px 0"
                }
                let inlineContent = parseWeChatInline(content, imgRadius: imgRadius)
                let hStyle = "font-family: &quot;PingFangSC-Semibold&quot;; font-weight: 600; color: #FD4606; text-align: justify; line-height: \(lineHeight); margin: \(margin); padding: 0 14px; font-size: \(fontSize);"
                result += "<h3 style=\"\(hStyle)\">\(inlineContent)</h3>\n"
                index += 1
                continue
            }

            // Callout / Highlight Blocks (<section data-type="callout"> or <callout>)
            let lowerTrimmed = trimmed.lowercased()
            if lowerTrimmed.hasPrefix("<section data-type=\"callout\"") || lowerTrimmed.hasPrefix("<callout") {
                if inWeChatList {
                    result += "</section>\n"
                    inWeChatList = false
                }
                var calloutLines: [String] = []
                let endTag = lowerTrimmed.hasPrefix("<callout") ? "</callout>" : "</section>"
                var subIdx = index
                var foundEnd = false

                while subIdx < lines.count {
                    let currentLine = lines[subIdx]
                    let currentTrimmed = currentLine.trimmingCharacters(in: .whitespaces)
                    let currentLower = currentTrimmed.lowercased()

                    let cleaned = currentLine
                        .replacingOccurrences(of: "<section data-type=\"callout\">", with: "", options: .caseInsensitive)
                        .replacingOccurrences(of: "</section>", with: "", options: .caseInsensitive)
                        .replacingOccurrences(of: "<callout>", with: "", options: .caseInsensitive)
                        .replacingOccurrences(of: "</callout>", with: "", options: .caseInsensitive)
                        .trimmingCharacters(in: .whitespaces)

                    if !cleaned.isEmpty {
                        calloutLines.append(cleaned)
                    }

                    if currentLower.contains(endTag) && subIdx > index {
                        foundEnd = true
                        subIdx += 1
                        break
                    }
                    if currentLower.contains(endTag) && subIdx == index && (currentLower.components(separatedBy: endTag).count > 2 || !cleaned.isEmpty) {
                        foundEnd = true
                        subIdx += 1
                        break
                    }
                    subIdx += 1
                }

                if !calloutLines.isEmpty {
                    result += buildCalloutCardHTML(lines: calloutLines, imgRadius: imgRadius) + "\n"
                    index = subIdx
                    continue
                }
            }

            // HTML / Images
            if trimmed.hasPrefix("<") {
                if trimmed.lowercased().contains("<img") {
                    let marginStyle = hasCaption ? "margin: 30px 0 0 0;" : "margin: 30px 0 26px 0;"
                    let imageWrapperStyle = "padding: 0 14px; \(marginStyle) text-align: center; box-sizing: border-box;"
                    let styledImg = injectImageStyles(trimmed, imgRadius: imgRadius)
                    result += "<section style=\"\(imageWrapperStyle)\" data-type=\"custom-block\">\(styledImg)</section>\n"
                } else {
                    result += trimmed + "\n"
                }
                index += 1
                continue
            }

            // Blockquotes (> ...)
            if trimmed.hasPrefix("> ") {
                let content = parseWeChatInline(String(trimmed.dropFirst(2)), imgRadius: imgRadius)
                let bqStyle = "padding: 0 15px; border-left: 4px solid #D8D8D8; padding-left: 14px; font-family: &quot;PingFangSC-Light&quot;, sans-serif; font-weight: 600; font-size: 15px; color: #222222; text-align: justify; line-height: 27px; margin: 26px 0;"
                result += "<section style=\"\(bqStyle)\">\(content)</section>\n"
                index += 1
                continue
            }

            if trimmed == ">" {
                index += 1
                continue
            }

            // Paragraphs
            let content = parseWeChatInline(line, imgRadius: imgRadius)
            result += "<section style=\"\(pStyle)\">\(content)</section>\n"
            index += 1
        }

        if inWeChatList {
            result += "</section>\n"
            inWeChatList = false
        }

        if addFooterBanner {
            result += weChatFooterBannerHTML + "\n"
        }

        return result
    }

    private static func parseStandaloneImage(_ line: String, imgRadius: String, hasCaption: Bool = false) -> String? {
        let pattern = "^!\\[([^\\]]*)\\]\\(([^)]+)\\)$"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let nsString = line as NSString
        let range = NSRange(location: 0, length: nsString.length)
        guard let match = regex.firstMatch(in: line, options: [], range: range), match.numberOfRanges > 2 else {
            return nil
        }
        let alt = nsString.substring(with: match.range(at: 1))
        let url = nsString.substring(with: match.range(at: 2))
        let marginStyle = hasCaption ? "margin: 30px 0 0 0;" : "margin: 30px 0 26px 0;"
        let imageWrapperStyle = "padding: 0 14px; \(marginStyle) text-align: center; box-sizing: border-box;"
        let imgStyle = "width: 100%; max-width: 100%; height: auto; display: block; margin: 0 auto; border-radius: \(imgRadius);"
        return "<section style=\"\(imageWrapperStyle)\" data-type=\"custom-block\"><img alt=\"\(alt)\" src=\"\(url)\" style=\"\(imgStyle)\"></section>"
    }

    private static func parseHeaderWithLevel(_ line: String) -> (tag: String, level: Int, content: String)? {
        for i in (1...6).reversed() {
            let hashes = String(repeating: "#", count: i)
            let pattern = "^\(hashes)\\s+(.+)$"
            if let range = line.range(of: pattern, options: .regularExpression) {
                let content = line[range].replacingOccurrences(of: "^\(hashes)\\s+", with: "", options: .regularExpression)
                return ("h\(i)", i, content)
            }
        }
        return nil
    }

    private static func parseWeChatInline(_ text: String, imgRadius: String) -> String {
        var result = text
        // Images: ![alt](url)
        let imgStyle = "width: 100%; max-width: 100%; height: auto; margin: 18px auto; display: block; border-radius: \(imgRadius);"
        result = result.replacingOccurrences(
            of: "!\\[([^\\]]*)\\]\\(([^)]+)\\)",
            with: "<img src=\"$2\" name=\"$1\" style=\"\(imgStyle)\">",
            options: .regularExpression
        )
        // Links: [text](url) → <a>
        let aStyle = "color: #576b95; text-decoration: none;"
        result = result.replacingOccurrences(
            of: "\\[([^\\]]+)\\]\\(([^)]+)\\)",
            with: "<a href=\"$2\" style=\"\(aStyle)\">$1</a>",
            options: .regularExpression
        )
        // Bold: **Bold**
        result = result.replacingOccurrences(
            of: "\\*\\*(.+?)\\*\\*",
            with: "<strong style=\"font-weight: bold;\">$1</strong>",
            options: .regularExpression
        )
        // Italic: *Italic*
        result = result.replacingOccurrences(
            of: "\\*(.+?)\\*",
            with: "<em style=\"font-style: italic;\">$1</em>",
            options: .regularExpression
        )
        return result
    }

    private static func injectImageStyles(_ htmlTag: String, imgRadius: String) -> String {
        guard htmlTag.lowercased().contains("<img") else { return htmlTag }
        let defaultStyle = "width: 100%; max-width: 100%; height: auto; margin: 0 auto; display: block; border-radius: \(imgRadius);"
        if htmlTag.range(of: "style=", options: .caseInsensitive) == nil {
            return htmlTag.replacingOccurrences(of: "<img", with: "<img style=\"\(defaultStyle)\"", options: .caseInsensitive)
        }
        return htmlTag
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
