import Foundation
import CoreGraphics
import ImageIO
import Vision

enum ImageOCRService {
    private struct RecognizedLine {
        let text: String
        let boundingBox: CGRect
    }

    nonisolated static func canHandleFile(_ url: URL) -> Bool {
        let supported = Set(ImageSourceSupport.supportedImageExtensions).subtracting(["svg"])
        return supported.contains(url.pathExtension.lowercased())
    }

    nonisolated static func recognizeText(inFile url: URL) async throws -> String {
        let data = try await Task.detached(priority: .userInitiated) {
            try Data(contentsOf: url, options: .mappedIfSafe)
        }.value
        return try await recognizeText(in: data, errorDomain: "ImageOCRService", failureMessage: "无法读取图片内容。")
    }

    nonisolated static func recognizeText(
        in data: Data,
        errorDomain: String = "ImageOCRService",
        failureMessage: String = "无法读取图片内容。"
    ) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else {
                throw NSError(
                    domain: errorDomain,
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: failureMessage]
                )
            }

            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]

            try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
            let lines = (request.results ?? [])
                .compactMap { observation -> RecognizedLine? in
                    guard let text = observation.topCandidates(1).first?.string else { return nil }
                    let normalized = normalizeLine(text)
                    guard !normalized.isEmpty else { return nil }
                    return RecognizedLine(text: normalized, boundingBox: observation.boundingBox)
                }

            return normalizedDocument(from: lines)
        }.value
    }

    nonisolated private static func normalizedDocument(from lines: [RecognizedLine]) -> String {
        let sortedLines = lines.sorted { lhs, rhs in
            let verticalDelta = abs(lhs.boundingBox.midY - rhs.boundingBox.midY)
            let sameVisualLine = verticalDelta < max(lhs.boundingBox.height, rhs.boundingBox.height) * 0.45
            if sameVisualLine {
                return lhs.boundingBox.minX < rhs.boundingBox.minX
            }
            return lhs.boundingBox.midY > rhs.boundingBox.midY
        }

        var paragraphs: [RecognizedLine] = []

        for line in sortedLines {
            guard let previous = paragraphs.last else {
                paragraphs.append(line)
                continue
            }

            if shouldStartNewParagraph(after: previous, before: line) {
                paragraphs.append(line)
                continue
            }

            let merged = RecognizedLine(
                text: joinedText(previous.text, line.text),
                boundingBox: previous.boundingBox.union(line.boundingBox)
            )
            paragraphs[paragraphs.count - 1] = merged
        }

        return paragraphs
            .map(\.text)
            .joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func shouldStartNewParagraph(after previous: RecognizedLine, before current: RecognizedLine) -> Bool {
        if current.text.range(of: #"^([\-•*]|\d+[.)、])\s*.+"#, options: .regularExpression) != nil {
            return true
        }

        let verticalGap = previous.boundingBox.minY - current.boundingBox.maxY
        let lineHeight = max(previous.boundingBox.height, current.boundingBox.height)
        if verticalGap > max(0.025, lineHeight * 0.9) {
            return true
        }

        let indentationDelta = current.boundingBox.minX - previous.boundingBox.minX
        if indentationDelta > 0.12, endsWithSentencePunctuation(previous.text) {
            return true
        }

        return false
    }

    nonisolated private static func joinedText(_ previous: String, _ current: String) -> String {
        guard let previousLast = previous.last, let currentFirst = current.first else {
            return previous + current
        }

        if noSpaceBetween(previousLast, currentFirst) || containsCJK(previous) || containsCJK(current) {
            return previous + current
        }

        return previous + " " + current
    }

    nonisolated private static func normalizeLine(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func noSpaceBetween(_ previous: Character, _ current: Character) -> Bool {
        let noLeadingSpace = CharacterSet(charactersIn: "，。！？；：,.!?;:%)]}）】》、")
        let noTrailingSpace = CharacterSet(charactersIn: "([（【《")

        if String(current).unicodeScalars.allSatisfy({ noLeadingSpace.contains($0) }) {
            return true
        }
        if String(previous).unicodeScalars.allSatisfy({ noTrailingSpace.contains($0) }) {
            return true
        }
        return false
    }

    nonisolated private static func endsWithSentencePunctuation(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return "。！？!?；;.".contains(last)
    }

    nonisolated private static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF:
                return true
            default:
                return false
            }
        }
    }
}
