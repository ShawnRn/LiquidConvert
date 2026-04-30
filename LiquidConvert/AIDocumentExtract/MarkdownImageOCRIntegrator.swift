import Foundation

enum MarkdownImageOCRIntegrator {
    private static let supportedArchiveExtensions = Set(["docx", "pptx", "xlsx", "xlsm"])
    private static let supportedImageExtensions = Set(ImageSourceSupport.supportedImageExtensions).subtracting(["svg"])
    private static let imagePattern = #"!\[[^\]]*\]\(([^)]+)\)"#
    private static let genericUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    struct ImageReference {
        let lineIndex: Int
        let destination: String
    }

    struct ArchiveImage: Sendable {
        let path: String
        let data: Data
    }

    static func insertOCRIfNeeded(
        into markdown: String,
        source: AIDocumentSource,
        progress: (@Sendable (String) -> Void)?
    ) async -> String {
        let references = imageReferences(in: markdown)
        guard !references.isEmpty else { return markdown }

        let archiveImages = await archiveImagesIfAvailable(for: source)
        let sourceDirectory = sourceDirectory(for: source)
        var archiveIndex = 0
        var insertions: [Int: [String]] = [:]
        var failedCount = 0

        progress?("正在 OCR 文档图片 0/\(references.count)…")

        for (referenceIndex, reference) in references.enumerated() {
            let statusSuffix = failedCount > 0 ? "（\(failedCount) 张失败）" : ""
            progress?("正在 OCR 文档图片 \(referenceIndex + 1)/\(references.count)…\(statusSuffix)")

            // Throttle requests to mmbiz CDN to avoid rate limiting.
            if referenceIndex > 0, isMmbizDestination(reference.destination) {
                try? await Task.sleep(for: .milliseconds(350))
            }

            do {
                guard let image = try await imageForReference(
                    reference,
                    sourceDirectory: sourceDirectory,
                    archiveImages: archiveImages,
                    archiveIndex: &archiveIndex
                ) else {
                    continue
                }

                let text = try await ImageOCRService.recognizeText(
                    in: image.data,
                    errorDomain: "MarkdownImageOCRIntegrator",
                    failureMessage: "无法读取文档图片。"
                )

                let block = formatOCRBlock(text, imageNumber: referenceIndex + 1, imageName: image.displayName)
                if !block.isEmpty {
                    insertions[reference.lineIndex, default: []].append(block)
                }
            } catch {
                failedCount += 1
                print("[AI Document OCR] image \(referenceIndex + 1) failed: \(error.localizedDescription)")
            }
        }

        guard !insertions.isEmpty else { return markdown }
        return insertBlocks(insertions, into: markdown)
    }

    private static func isMmbizDestination(_ destination: String) -> Bool {
        destination.contains("mmbiz") || destination.contains("qpic.cn")
    }

    private static func imageForReference(
        _ reference: ImageReference,
        sourceDirectory: URL?,
        archiveImages: [ArchiveImage],
        archiveIndex: inout Int
    ) async throws -> (data: Data, displayName: String)? {
        if let data = try await dataFromMarkdownDestination(reference.destination, sourceDirectory: sourceDirectory) {
            return (data, displayName(from: reference.destination, fallback: "图片"))
        }

        guard archiveIndex < archiveImages.count else { return nil }
        let image = archiveImages[archiveIndex]
        archiveIndex += 1
        return (image.data, URL(fileURLWithPath: image.path).lastPathComponent)
    }

    private static func dataFromMarkdownDestination(_ destination: String, sourceDirectory: URL?) async throws -> Data? {
        let cleaned = cleanMarkdownDestination(destination)
        guard !cleaned.isEmpty else { return nil }

        if cleaned.hasPrefix("data:image/") {
            return dataFromDataURI(cleaned)
        }

        if let url = URL(string: cleaned), let scheme = url.scheme?.lowercased() {
            switch scheme {
            case "http", "https":
                return try await downloadImageData(from: url)
            case "file":
                return try await readLocalImageData(from: url)
            default:
                return nil
            }
        }

        let localURL: URL
        if cleaned.hasPrefix("/") {
            localURL = URL(fileURLWithPath: cleaned)
        } else if let sourceDirectory {
            localURL = sourceDirectory.appendingPathComponent(cleaned)
        } else {
            return nil
        }

        return try await readLocalImageData(from: localURL)
    }

    private static func dataFromDataURI(_ value: String) -> Data? {
        guard !value.contains("..."),
              let comma = value.firstIndex(of: ","),
              value[..<comma].lowercased().contains(";base64")
        else {
            return nil
        }

        return Data(base64Encoded: String(value[value.index(after: comma)...]))
    }

    private static func readLocalImageData(from url: URL) async throws -> Data? {
        guard supportedImageExtensions.contains(url.pathExtension.lowercased()) else { return nil }
        return try await Task.detached(priority: .userInitiated) {
            try Data(contentsOf: url, options: .mappedIfSafe)
        }.value
    }

    private static func downloadImageData(from url: URL) async throws -> Data {
        var candidates = [url]
        if var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           components.query != nil
        {
            components.query = nil
            if let cleanURL = components.url, cleanURL != url {
                candidates.append(cleanURL)
            }
        }

        let isMmbiz = (url.host ?? "").contains("mmbiz")

        var lastError: Error?
        for candidate in candidates {
            for attempt in 0..<3 {
                do {
                    var request = URLRequest(url: candidate)
                    request.timeoutInterval = 30
                    request.setValue(genericUserAgent, forHTTPHeaderField: "User-Agent")
                    if isMmbiz {
                        request.setValue("https://mp.weixin.qq.com/", forHTTPHeaderField: "Referer")
                    }

                    let (data, response) = try await URLSession.shared.data(for: request)
                    if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                        throw NSError(
                            domain: "MarkdownImageOCRIntegrator",
                            code: http.statusCode,
                            userInfo: [NSLocalizedDescriptionKey: "图片下载失败（HTTP \(http.statusCode)，\(candidate.lastPathComponent)）。"]
                        )
                    }

                    // Validate that the response is actual image data, not an HTML error page.
                    guard data.count > 200 else {
                        throw NSError(
                            domain: "MarkdownImageOCRIntegrator",
                            code: -21,
                            userInfo: [NSLocalizedDescriptionKey: "图片数据过小（\(data.count) bytes），可能被 CDN 拒绝。"]
                        )
                    }

                    if looksLikeHTMLErrorPage(data) {
                        throw NSError(
                            domain: "MarkdownImageOCRIntegrator",
                            code: -22,
                            userInfo: [NSLocalizedDescriptionKey: "CDN 返回了 HTML 错误页而非图片数据。"]
                        )
                    }

                    print("[AI Document OCR] downloaded \(candidate.lastPathComponent): \(data.count) bytes")
                    return data
                } catch {
                    lastError = error
                    // Increase backoff for mmbiz CDN to respect rate limits.
                    let delay = isMmbiz ? 800 * (attempt + 1) : 400 * (attempt + 1)
                    try await Task.sleep(for: .milliseconds(delay))
                }
            }
        }

        throw lastError ?? NSError(
            domain: "MarkdownImageOCRIntegrator",
            code: -20,
            userInfo: [NSLocalizedDescriptionKey: "图片下载失败。"]
        )
    }

    /// Heuristic check: if the first few bytes look like HTML rather than image data.
    private static func looksLikeHTMLErrorPage(_ data: Data) -> Bool {
        guard data.count > 16 else { return false }
        let prefix = data.prefix(64)
        guard let text = String(data: prefix, encoding: .utf8)?.lowercased() else { return false }
        return text.contains("<!doctype") || text.contains("<html") || text.contains("<head")
    }

    private static func imageReferences(in markdown: String) -> [ImageReference] {
        guard let regex = try? NSRegularExpression(pattern: imagePattern) else { return [] }

        // Use matches (not firstMatch) to extract ALL image references per line.
        // htmlDecoded can collapse newlines, merging multiple ![image](...) onto one line.
        var results: [ImageReference] = []
        for (lineIndex, line) in markdown.components(separatedBy: .newlines).enumerated() {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            for match in regex.matches(in: line, range: range) {
                guard match.numberOfRanges > 1,
                      let capture = Range(match.range(at: 1), in: line)
                else { continue }
                results.append(ImageReference(lineIndex: lineIndex, destination: String(line[capture])))
            }
        }
        return results
    }

    private static func insertBlocks(_ insertions: [Int: [String]], into markdown: String) -> String {
        var output: [String] = []

        for (index, line) in markdown.components(separatedBy: .newlines).enumerated() {
            output.append(line)
            guard let blocks = insertions[index], !blocks.isEmpty else { continue }

            if output.last?.isEmpty == false {
                output.append("")
            }
            output.append(contentsOf: blocks.joined(separator: "\n\n").components(separatedBy: .newlines))
            output.append("")
        }

        return output
            .joined(separator: "\n")
            .replacingOccurrences(of: #"\n{4,}"#, with: "\n\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func formatOCRBlock(_ text: String, imageNumber: Int, imageName: String) -> String {
        let normalized = text
            .replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return "" }

        let quotedLines = normalized
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .map { $0.isEmpty ? ">" : "> \($0)" }
            .joined(separator: "\n")

        return "> 图片 \(imageNumber)（\(imageName)）OCR：\n>\n\(quotedLines)"
    }

    private static func cleanMarkdownDestination(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("<"), let close = value.firstIndex(of: ">") {
            value = String(value[value.index(after: value.startIndex)..<close])
        } else if let titleRange = value.range(of: #"\s+["'][^"']*["']\s*$"#, options: .regularExpression) {
            value.removeSubrange(titleRange)
        }

        return value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    private static func displayName(from destination: String, fallback: String) -> String {
        let cleaned = cleanMarkdownDestination(destination)
        if cleaned.hasPrefix("data:image/") { return fallback }
        if let url = URL(string: cleaned), !url.lastPathComponent.isEmpty {
            return url.lastPathComponent
        }
        let filename = URL(fileURLWithPath: cleaned).lastPathComponent
        return filename.isEmpty ? fallback : filename
    }

    private static func sourceDirectory(for source: AIDocumentSource) -> URL? {
        guard case .file(let url) = source else { return nil }
        return url.deletingLastPathComponent()
    }

    private static func archiveImagesIfAvailable(for source: AIDocumentSource) async -> [ArchiveImage] {
        guard case .file(let url) = source,
              supportedArchiveExtensions.contains(url.pathExtension.lowercased())
        else {
            return []
        }

        do {
            switch url.pathExtension.lowercased() {
            case "docx":
                return try await docxImages(in: url)
            case "pptx":
                return try await pptxImages(in: url)
            default:
                return try await mediaImages(in: url, prefixes: ["xl/media/"])
            }
        } catch {
            print("[AI Document OCR] archive image lookup failed: \(error.localizedDescription)")
            return []
        }
    }

    private static func docxImages(in url: URL) async throws -> [ArchiveImage] {
        let documentXML = (try? await archiveText(url, path: "word/document.xml")) ?? ""
        let relationshipsXML = (try? await archiveText(url, path: "word/_rels/document.xml.rels")) ?? ""
        let relationshipTargets = imageRelationshipTargets(in: relationshipsXML, basePath: "word")
        let orderedPaths = embedIDs(in: documentXML).compactMap { relationshipTargets[$0] }

        if !orderedPaths.isEmpty {
            return try await archiveImages(in: url, paths: orderedPaths)
        }

        return try await mediaImages(in: url, prefixes: ["word/media/"])
    }

    private static func pptxImages(in url: URL) async throws -> [ArchiveImage] {
        let slidePaths = try await archivePaths(in: url)
            .filter { $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") }
            .sorted { naturalKey($0) < naturalKey($1) }

        var orderedPaths: [String] = []
        for slidePath in slidePaths {
            let slideXML = (try? await archiveText(url, path: slidePath)) ?? ""
            let relsPath = slidePath.replacingOccurrences(of: "ppt/slides/", with: "ppt/slides/_rels/") + ".rels"
            let relationshipsXML = (try? await archiveText(url, path: relsPath)) ?? ""
            let relationshipTargets = imageRelationshipTargets(in: relationshipsXML, basePath: "ppt/slides")
            orderedPaths.append(contentsOf: embedIDs(in: slideXML).compactMap { relationshipTargets[$0] })
        }

        if !orderedPaths.isEmpty {
            return try await archiveImages(in: url, paths: orderedPaths)
        }

        return try await mediaImages(in: url, prefixes: ["ppt/media/"])
    }

    private static func mediaImages(in url: URL, prefixes: [String]) async throws -> [ArchiveImage] {
        let paths = try await archivePaths(in: url)
            .filter { path in
                prefixes.contains { path.hasPrefix($0) }
                    && supportedImageExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased())
            }
            .sorted { naturalKey($0) < naturalKey($1) }
        return try await archiveImages(in: url, paths: paths)
    }

    private static func archiveImages(in url: URL, paths: [String]) async throws -> [ArchiveImage] {
        var images: [ArchiveImage] = []
        for path in paths {
            guard supportedImageExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased()) else { continue }
            let data = try await archiveData(url, path: path)
            images.append(ArchiveImage(path: path, data: data))
        }
        return images
    }

    private static func archivePaths(in url: URL) async throws -> [String] {
        let output = try await Task.detached(priority: .userInitiated) {
            try runTextCommand(
                executable: URL(fileURLWithPath: "/usr/bin/unzip"),
                args: ["-Z1", url.path]
            )
        }.value

        return output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func archiveText(_ url: URL, path: String) async throws -> String {
        let data = try await archiveData(url, path: path)
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func archiveData(_ url: URL, path: String) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            try runDataCommand(
                executable: URL(fileURLWithPath: "/usr/bin/unzip"),
                args: ["-p", url.path, path]
            )
        }.value
    }

    private static func imageRelationshipTargets(in xml: String, basePath: String) -> [String: String] {
        guard let regex = try? NSRegularExpression(pattern: #"<Relationship\b[^>]+>"#, options: [.caseInsensitive]) else {
            return [:]
        }

        var targets: [String: String] = [:]
        let range = NSRange(xml.startIndex..<xml.endIndex, in: xml)
        for match in regex.matches(in: xml, range: range) {
            guard let matchRange = Range(match.range, in: xml) else { continue }
            let tag = String(xml[matchRange])
            guard attribute("Type", in: tag)?.contains("/image") == true,
                  let id = attribute("Id", in: tag),
                  let target = attribute("Target", in: tag)
            else {
                continue
            }

            targets[id] = normalizedArchivePath(target, relativeTo: basePath)
        }
        return targets
    }

    private static func embedIDs(in xml: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"\br:embed=["']([^"']+)["']"#) else { return [] }

        let range = NSRange(xml.startIndex..<xml.endIndex, in: xml)
        return regex.matches(in: xml, range: range).compactMap { match in
            guard match.numberOfRanges > 1, let capture = Range(match.range(at: 1), in: xml) else { return nil }
            return String(xml[capture])
        }
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = #"\b\#(name)=["']([^"']+)["']"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..<tag.endIndex, in: tag)),
              match.numberOfRanges > 1,
              let capture = Range(match.range(at: 1), in: tag)
        else {
            return nil
        }
        return String(tag[capture])
    }

    private static func normalizedArchivePath(_ target: String, relativeTo basePath: String) -> String {
        let raw = target.hasPrefix("/") ? String(target.dropFirst()) : "\(basePath)/\(target)"
        var parts: [String] = []
        for part in raw.split(separator: "/").map(String.init) {
            if part == "." || part.isEmpty { continue }
            if part == ".." {
                _ = parts.popLast()
            } else {
                parts.append(part)
            }
        }
        return parts.joined(separator: "/")
    }

    private static func naturalKey(_ value: String) -> String {
        var key = ""
        var digitBuffer = ""

        for character in value {
            if character.isNumber {
                digitBuffer.append(character)
            } else {
                if !digitBuffer.isEmpty {
                    key += String(format: "%012d", Int(digitBuffer) ?? 0)
                    digitBuffer.removeAll()
                }
                key.append(character)
            }
        }

        if !digitBuffer.isEmpty {
            key += String(format: "%012d", Int(digitBuffer) ?? 0)
        }
        return key
    }

    nonisolated private static func runTextCommand(executable: URL, args: [String]) throws -> String {
        let data = try runDataCommand(executable: executable, args: args)
        return String(data: data, encoding: .utf8) ?? ""
    }

    nonisolated private static func runDataCommand(executable: URL, args: [String]) throws -> Data {
        let process = Process()
        process.executableURL = executable
        process.arguments = args

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let message = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(
                domain: "MarkdownImageOCRIntegrator",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: message?.isEmpty == false ? message! : "读取文档图片失败。"]
            )
        }

        return output
    }
}
