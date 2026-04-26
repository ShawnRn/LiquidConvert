//
//  ImageSourceSupport.swift
//  LiquidConvert
//
//  Created by Codex.
//

import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

extension UTType {
    static let svgImage = UTType(filenameExtension: "svg") ?? UTType("public.svg-image")!
}

struct ImageSourceSupport {
    static let supportedImageExtensions: [String] = [
        "jpg", "jpeg", "png", "heic", "heif", "webp", "tiff", "tif", "bmp", "gif", "raw", "cr2",
        "nef", "arw", "avif", "svg",
    ]

    struct RasterImage: @unchecked Sendable {
        nonisolated let image: CGImage
        nonisolated let source: CGImageSource?
        nonisolated let properties: [CFString: Any]
    }

    nonisolated static func isSVG(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "svg"
    }

    nonisolated static func loadRasterImage(from url: URL, errorDomain: String) throws -> RasterImage {
        if isSVG(url) {
            let image = try rasterizeSVG(at: url, errorDomain: errorDomain)
            return RasterImage(image: image, source: nil, properties: [:])
        }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw NSError(
                domain: errorDomain, code: -1,
                userInfo: [NSLocalizedDescriptionKey: "无法读取源图片"])
        }

        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw NSError(
                domain: errorDomain, code: -2,
                userInfo: [NSLocalizedDescriptionKey: "无法解码图片"])
        }

        let properties =
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        return RasterImage(image: image, source: source, properties: properties)
    }

    nonisolated private static func rasterizeSVG(at url: URL, errorDomain: String) throws -> CGImage {
        guard let nsImage = NSImage(contentsOf: url) else {
            throw NSError(
                domain: errorDomain, code: -20,
                userInfo: [NSLocalizedDescriptionKey: "无法读取 SVG 图片"])
        }

        let dimensions = svgPixelSize(from: url, fallback: nsImage.size)
        let width = max(1, min(20_000, Int(dimensions.width.rounded())))
        let height = max(1, min(20_000, Int(dimensions.height.rounded())))

        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: width,
                pixelsHigh: height,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0)
        else {
            throw NSError(
                domain: errorDomain, code: -21,
                userInfo: [NSLocalizedDescriptionKey: "无法创建 SVG 渲染画布"])
        }

        let previousContext = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        nsImage.draw(
            in: NSRect(x: 0, y: 0, width: width, height: height),
            from: NSRect(origin: .zero, size: nsImage.size),
            operation: .sourceOver,
            fraction: 1.0)
        NSGraphicsContext.current = previousContext

        guard let cgImage = rep.cgImage else {
            throw NSError(
                domain: errorDomain, code: -22,
                userInfo: [NSLocalizedDescriptionKey: "SVG 渲染失败"])
        }
        return cgImage
    }

    nonisolated private static func svgPixelSize(from url: URL, fallback: CGSize) -> CGSize {
        guard
            let data = try? Data(contentsOf: url, options: .mappedIfSafe),
            let document = try? XMLDocument(data: data, options: [.nodePreserveWhitespace]),
            let root = document.rootElement()
        else {
            return sanitizedSize(fallback)
        }

        let width = numericAttribute("width", in: root)
        let height = numericAttribute("height", in: root)
        if let width, let height, width > 0, height > 0 {
            return CGSize(width: width, height: height)
        }

        if let viewBox = root.attribute(forName: "viewBox")?.stringValue {
            let parts = viewBox
                .split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\t" || $0 == "\n" })
                .compactMap { Double($0) }
            if parts.count == 4, parts[2] > 0, parts[3] > 0 {
                return CGSize(width: parts[2], height: parts[3])
            }
        }

        return sanitizedSize(fallback)
    }

    nonisolated private static func numericAttribute(_ name: String, in element: XMLElement) -> CGFloat? {
        guard let rawValue = element.attribute(forName: name)?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.hasSuffix("%")
        else {
            return nil
        }

        let numericPrefix = rawValue.prefix { character in
            character.isNumber || character == "." || character == "-"
        }
        guard let value = Double(numericPrefix), value > 0 else { return nil }
        return CGFloat(value)
    }

    nonisolated private static func sanitizedSize(_ size: CGSize) -> CGSize {
        let width = size.width.isFinite && size.width > 0 ? size.width : 1024
        let height = size.height.isFinite && size.height > 0 ? size.height : 1024
        return CGSize(width: width, height: height)
    }
}
