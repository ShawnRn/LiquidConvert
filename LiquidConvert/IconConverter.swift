//
//  IconConverter.swift
//  LiquidConvert
//
//  Created by Shawn Rain on 2025/12/2.
//

import AppKit

struct IconConverter {
    
    enum TargetFormat: String, CaseIterable {
        case icns = "ICNS"
        case images = "图片集"
    }
    
    /// 统一转换入口
    static func convert(inputURL: URL, targetFormat: TargetFormat, generateIconSet: Bool) async throws -> URL {
        let ext = inputURL.pathExtension.lowercased()
        
        if ext == "icns" {
            // ICNS -> 图片文件夹 (解包)
            return try extract(inputURL: inputURL)
        } else {
            // 图片 -> ICNS (打包)
            if generateIconSet || targetFormat == .images {
                return try convertToIconSet(inputURL: inputURL)
            } else {
                return try convert(inputURL: inputURL)
            }
        }
    }

    /// macOS 标准图标尺寸规范
    private static let iconSpecs: [(name: String, size: Int)] = [
        ("icon_16x16.png", 16),
        ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32),
        ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128),
        ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256),
        ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512),
        ("icon_512x512@2x.png", 1024),
    ]

    static func convert(inputURL: URL) throws -> URL {
        // 1. 准备路径
        let fileManager = FileManager.default
        let folderName = "LiquidTemp_\(Int(Date().timeIntervalSince1970))"
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(folderName)
        let iconsetDir = tempDir.appendingPathComponent("icons.iconset")

        // 2. 创建临时目录 .iconset 并生成图片
        try createIconSetFiles(from: inputURL, at: iconsetDir)

        // 3. 准备输出路径
        let outputFileName = inputURL.deletingPathExtension().lastPathComponent
        let outputURL = inputURL.deletingLastPathComponent().appendingPathComponent(
            "\(outputFileName).icns")

        // 4. 调用系统 iconutil 命令打包
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        process.arguments = ["-c", "icns", iconsetDir.path, "-o", outputURL.path]

        try process.run()
        process.waitUntilExit()

        // 5. 清理临时文件
        try? fileManager.removeItem(at: tempDir)

        if process.terminationStatus == 0 {
            return outputURL
        } else {
            throw NSError(
                domain: "IconConverter", code: -2,
                userInfo: [NSLocalizedDescriptionKey: "打包 ICNS 失败"])
        }
    }

    static func convertToIconSet(inputURL: URL) throws -> URL {
        let fileManager = FileManager.default
        let outputFileName = inputURL.deletingPathExtension().lastPathComponent
        // 输出文件夹名: "Filename Icons"
        let outputURL = inputURL.deletingLastPathComponent().appendingPathComponent(
            "\(outputFileName) Icons")

        // 如果目录已存在，先删除
        if fileManager.fileExists(atPath: outputURL.path) {
            try fileManager.removeItem(at: outputURL)
        }

        // 生成图片集到目标文件夹
        try createIconSetFiles(from: inputURL, at: outputURL)

        return outputURL
    }

    private static func createIconSetFiles(from inputURL: URL, at destinationDir: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destinationDir, withIntermediateDirectories: true)

        guard let image = NSImage(contentsOf: inputURL) else {
            throw NSError(
                domain: "IconConverter", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法加载源图片"])
        }

        for spec in iconSpecs {
            let resizeURL = destinationDir.appendingPathComponent(spec.name)
            if let resizedData = resize(
                image: image, to: CGSize(width: spec.size, height: spec.size))
            {
                try resizedData.write(to: resizeURL)
            }
        }
    }

    static func extract(inputURL: URL) throws -> URL {
        let fileManager = FileManager.default
        let outputName = inputURL.deletingPathExtension().lastPathComponent
        // 目标是生成一个普通文件夹，但 iconutil 需要输出到 .iconset
        // 我们先输出到 .iconset，然后重命名（去掉扩展名）
        let outputParent = inputURL.deletingLastPathComponent()
        let tempIconsetURL = outputParent.appendingPathComponent("\(outputName).iconset")
        let finalOutputURL = outputParent.appendingPathComponent(outputName)

        // 如果目标文件夹已存在，先删除（或者报错，这里选择覆盖/删除旧的）
        if fileManager.fileExists(atPath: tempIconsetURL.path) {
            try fileManager.removeItem(at: tempIconsetURL)
        }
        if fileManager.fileExists(atPath: finalOutputURL.path) {
            try fileManager.removeItem(at: finalOutputURL)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        process.arguments = ["-c", "iconset", inputURL.path, "-o", tempIconsetURL.path]

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus == 0 {
            // 重命名 .iconset 为普通文件夹
            try fileManager.moveItem(at: tempIconsetURL, to: finalOutputURL)
            return finalOutputURL
        } else {
            throw NSError(
                domain: "IconConverter", code: -3,
                userInfo: [NSLocalizedDescriptionKey: "解包 ICNS 失败"])
        }
    }

    /// 辅助方法：缩放图片并转为 PNG Data
    private static func resize(image: NSImage, to targetSize: CGSize) -> Data? {
        let width = Int(targetSize.width)
        let height = Int(targetSize.height)

        // 🔥 使用 NSBitmapImageRep 显式指定像素尺寸，避免 Retina 屏幕下的 2x 问题
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
                bitsPerPixel: 0
            )
        else { return nil }

        rep.size = targetSize  // 逻辑尺寸匹配

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

        // 设置高质量插值
        NSGraphicsContext.current?.imageInterpolation = .high

        image.draw(
            in: NSRect(origin: .zero, size: targetSize),
            from: NSRect(origin: .zero, size: image.size),
            operation: .copy,
            fraction: 1.0)

        NSGraphicsContext.restoreGraphicsState()

        return rep.representation(using: NSBitmapImageRep.FileType.png, properties: [:])
    }
}
