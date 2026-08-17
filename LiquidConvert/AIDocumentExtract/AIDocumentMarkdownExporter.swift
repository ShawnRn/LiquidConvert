import Foundation

enum AIDocumentMarkdownExporter {
    struct ExportedFile: Sendable {
        nonisolated let source: AIDocumentSource
        nonisolated let url: URL

        nonisolated init(source: AIDocumentSource, url: URL) {
            self.source = source
            self.url = url
        }
    }

    nonisolated static func export(
        markdown: String,
        source: AIDocumentSource,
        suggestedTitle: String?,
        to directory: URL,
        reserving usedNames: inout Set<String>
    ) throws -> ExportedFile {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let preferredStem = suggestedTitle ?? defaultStem(for: source)
        let baseStem = sanitizedStem(preferredStem)
        var candidate = baseStem
        var suffix = 2

        while usedNames.contains(candidate.lowercased()) ||
                FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent(candidate).appendingPathExtension("md").path
                ) {
            candidate = "\(baseStem)-\(suffix)"
            suffix += 1
        }

        usedNames.insert(candidate.lowercased())
        let outputURL = directory.appendingPathComponent(candidate).appendingPathExtension("md")
        let normalized = markdown.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        try normalized.write(to: outputURL, atomically: true, encoding: .utf8)
        return ExportedFile(source: source, url: outputURL)
    }

    nonisolated static func sanitizedStem(_ value: String) -> String {
        let illegal = CharacterSet(charactersIn: "/:\\?%*|\"<>\n\r\t")
        let cleaned = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: illegal)
            .joined(separator: "_")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return cleaned.isEmpty ? "Extracted" : String(cleaned.prefix(180))
    }

    nonisolated private static func defaultStem(for source: AIDocumentSource) -> String {
        switch source {
        case .file(let url):
            return url.deletingPathExtension().lastPathComponent
        case .link(let url):
            let slug = url.pathComponents.last(where: { $0 != "/" && !$0.isEmpty })
            return slug ?? url.host ?? "WebPage"
        }
    }
}
