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

            let width = CGFloat(cgImage.width)
            let height = CGFloat(cgImage.height)
            
            let maxSliceHeight: CGFloat = 3000
            var slices: [CGRect] = []
            
            if height > maxSliceHeight * 1.2 && width > 0 {
                let overlap: CGFloat = 200
                var currentY: CGFloat = 0
                while currentY < height {
                    let sliceHeight = min(maxSliceHeight + overlap, height - currentY)
                    slices.append(CGRect(x: 0, y: currentY, width: width, height: sliceHeight))
                    currentY += maxSliceHeight
                }
            } else {
                slices.append(CGRect(x: 0, y: 0, width: width, height: height))
            }

            let allMappedLines = try await withThrowingTaskGroup(of: [RecognizedLine].self) { group in
                for cropRect in slices {
                    group.addTask {
                        guard let croppedCGImage = cgImage.cropping(to: cropRect) else { return [] }
                        let request = VNRecognizeTextRequest()
                        request.recognitionLevel = .accurate
                        request.usesLanguageCorrection = true
                        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
                        try VNImageRequestHandler(cgImage: croppedCGImage, options: [:]).perform([request])
                        
                        var lines: [RecognizedLine] = []
                        for observation in request.results ?? [] {
                            guard let text = observation.topCandidates(1).first?.string else { continue }
                            let normalized = normalizeLine(text)
                            guard !normalized.isEmpty else { continue }
                            
                            let localBox = observation.boundingBox
                            let cropHeight = cropRect.height
                            let cropY = cropRect.minY
                            let heightRatio = cropHeight / height
                            let yOffset = (height - cropY - cropHeight) / height
                            
                            let globalBox = CGRect(
                                x: localBox.minX,
                                y: yOffset + localBox.minY * heightRatio,
                                width: localBox.width,
                                height: localBox.height * heightRatio
                            )
                            
                            lines.append(RecognizedLine(text: normalized, boundingBox: globalBox))
                        }
                        return lines
                    }
                }
                
                var results: [RecognizedLine] = []
                for try await lines in group {
                    results.append(contentsOf: lines)
                }
                return results
            }
            
            var deduplicatedLines: [RecognizedLine] = []
            for line in allMappedLines {
                if let duplicateIndex = deduplicatedLines.firstIndex(where: {
                    abs($0.boundingBox.midY - line.boundingBox.midY) < (line.boundingBox.height * 0.5) &&
                    abs($0.boundingBox.minX - line.boundingBox.minX) < 0.05
                }) {
                    if line.text.count > deduplicatedLines[duplicateIndex].text.count {
                        deduplicatedLines[duplicateIndex] = line
                    }
                } else {
                    deduplicatedLines.append(line)
                }
            }

            return normalizedDocument(from: deduplicatedLines)
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
