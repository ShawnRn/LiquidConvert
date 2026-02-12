//
//  ImageStitcher.swift
//  LiquidConvert
//
//  Created by Shawn Rain.
//

import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum StitchDirection: Sendable, Equatable {
    case vertical
    case horizontal
}

struct ImageStitcher {
    
    /// 处理多张图片拼接 (自动按文件名排序，智能判断方向)
    static func process(imageURLs: [URL], isSilent: Bool = false) async {
        let sortedURLs = imageURLs.sorted { $0.lastPathComponent < $1.lastPathComponent }
        
        // 智能判断方向
        var landscapeCount = 0
        var portraitCount = 0
        var squareCount = 0
        
        for url in sortedURLs {
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
               let width = props[kCGImagePropertyPixelWidth] as? Int,
               let height = props[kCGImagePropertyPixelHeight] as? Int {
                if width > height {
                    landscapeCount += 1
                } else if height > width {
                    portraitCount += 1
                } else {
                    squareCount += 1
                }
            }
        }
        
        // 策略:
        // Landscape (宽图) -> 适合上下拼接 (Vertical)
        // Portrait (长图) -> 适合左右拼接 (Horizontal)
        // Square (方图) -> 优先左右拼接 (Horizontal)
        
        var direction: StitchDirection = .vertical
        
        if portraitCount + squareCount >= landscapeCount {
            direction = .horizontal
        } else {
            direction = .vertical
        }
        
        print("🧩 [智能拼图] L:\(landscapeCount) P:\(portraitCount) S:\(squareCount) -> 方向: \(direction)")
        
        // 调用 processOrdered 时使用默认参数
        _ = await processOrdered(imageURLs: sortedURLs, direction: direction, targetFormat: .jpeg, quality: 0.9, mobileOptimize: false, isSilent: isSilent)
    }

    /// 处理多张图片拼接 (保持传入顺序)
    nonisolated static func processOrdered(
        imageURLs: [URL],
        direction: StitchDirection,
        targetFormat: ImageConverter.TargetFormat = .jpeg,
        quality: Double = 0.9,
        mobileOptimize: Bool = false,
        isSilent: Bool = false
    ) async -> Bool {
        guard imageURLs.count > 1 else { return false }
        
        print("🧩 [拼图] 开始后台处理 \(imageURLs.count) 张图片, 方向: \(direction), 格式: \(targetFormat), 移动端优化: \(mobileOptimize)")
        
        // 1. 读取所有图片 (后台)
        var validImages: [(image: CGImage, width: Int, height: Int)] = []
        for url in imageURLs {
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                validImages.append((cgImage, cgImage.width, cgImage.height))
            }
        }
        
        guard !validImages.isEmpty else {
            await MainActor.run { notify(title: "拼图失败", subtitle: "无法读取有效的图片文件") }
            return false
        }
        
        // 2. 计算画布尺寸 (后台)
        var canvasWidth: Int = 0
        var canvasHeight: Int = 0
        struct DrawRect { let width: CGFloat; let height: CGFloat }
        var drawRects: [DrawRect] = []
        
        // 移动端优化基准: iPhone 17 标准版短边 1206px
        let mobileBaseline: CGFloat = 1206.0
        
        if direction == .vertical {
            let targetWidth = mobileOptimize ? mobileBaseline : CGFloat(validImages.map { $0.width }.max() ?? 0)
            canvasWidth = Int(targetWidth)
            var totalHeight: CGFloat = 0
            for item in validImages {
                let scale = targetWidth / CGFloat(item.width)
                let scaledHeight = CGFloat(item.height) * scale
                drawRects.append(DrawRect(width: targetWidth, height: scaledHeight))
                totalHeight += scaledHeight
            }
            canvasHeight = Int(ceil(totalHeight))
        } else {
            let targetHeight = mobileOptimize ? mobileBaseline : CGFloat(validImages.map { $0.height }.max() ?? 0)
            canvasHeight = Int(targetHeight)
            var totalWidth: CGFloat = 0
            for item in validImages {
                let scale = targetHeight / CGFloat(item.height)
                let scaledWidth = CGFloat(item.width) * scale
                drawRects.append(DrawRect(width: scaledWidth, height: targetHeight))
                totalWidth += scaledWidth
            }
            canvasWidth = Int(ceil(totalWidth))
        }
        
        // 3. 绘制拼接图 (后台)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: canvasWidth, height: canvasHeight, bitsPerComponent: 8, bytesPerRow: 0,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return false }
        
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight))
        
        if direction == .vertical {
            var currentY = CGFloat(canvasHeight)
            for (index, item) in validImages.enumerated() {
                let rectInfo = drawRects[index]
                currentY -= rectInfo.height
                context.draw(item.image, in: CGRect(x: 0, y: currentY, width: rectInfo.width, height: rectInfo.height))
            }
        } else {
            var currentX: CGFloat = 0
            for (index, item) in validImages.enumerated() {
                let rectInfo = drawRects[index]
                context.draw(item.image, in: CGRect(x: currentX, y: 0, width: rectInfo.width, height: rectInfo.height))
                currentX += rectInfo.width
            }
        }

        guard let stitchedImage = context.makeImage() else { return false }
        
        // 4. 保存临时文件
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("stitched_\(UUID().uuidString).\(targetFormat.fileExtension)")
        guard let dest = CGImageDestinationCreateWithURL(tempURL as CFURL, targetFormat.utType.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, stitchedImage, nil)
        guard CGImageDestinationFinalize(dest) else { return false }
        
        // 5. 确定保存位置 (Sheet 样式)
        let finalDestination: URL?
        if isSilent {
            let folder = imageURLs.first?.deletingLastPathComponent() ?? FileManager.default.temporaryDirectory
            let baseName = imageURLs.first?.deletingPathExtension().lastPathComponent ?? "Stitched"
            finalDestination = getUniqueFileURL(folder: folder, fileName: "\(baseName)_stitched", extension: targetFormat.fileExtension)
        } else {
            finalDestination = await withCheckedContinuation { continuation in
                Task { @MainActor in
                    let panel = NSSavePanel()
                    panel.allowedContentTypes = [targetFormat.utType]
                    panel.nameFieldStringValue = "\(imageURLs.first?.deletingPathExtension().lastPathComponent ?? "Stitched")_stitched"
                    
                    // 寻找主窗口或当前的可见主窗口
                    let window = NSApplication.shared.mainWindow ?? NSApplication.shared.windows.first { $0.isVisible && $0.identifier?.rawValue == "main_window" }
                    
                    if let window = window {
                        panel.beginSheetModal(for: window) { response in
                            continuation.resume(returning: response == .OK ? panel.url : nil)
                        }
                    } else {
                        // 极端情况下退回到普通窗口模式，但也尽量避免影响体验
                        let response = panel.runModal()
                        continuation.resume(returning: response == .OK ? panel.url : nil)
                    }
                }
            }
        }
        
        guard let finalURL = finalDestination else { return false }
        
        // 6. 最终压缩与移动
        do {
            let options = ImageCompressor.CompressionOptions(resizeMode: .none, quality: quality, deleteOriginal: false, autoCompressTo5MB: true, targetFormat: targetFormat.utType)
            let compressedURL = try ImageCompressor.compress(inputURL: tempURL, options: options)
            
            // 清理临时拼接文件 (用 removeItem，因为是系统生成的临时文件，不进废纸篓)
            try? FileManager.default.removeItem(at: tempURL)
            
            if FileManager.default.fileExists(atPath: finalURL.path) { try FileManager.default.removeItem(at: finalURL) }
            try FileManager.default.moveItem(at: compressedURL, to: finalURL)
            
            await MainActor.run {
                notify(title: "拼图完成", subtitle: "已保存为 \(finalURL.lastPathComponent)")
                NSSound(named: "Glass")?.play()
                NSWorkspace.shared.activateFileViewerSelecting([finalURL])
            }
            return true
        } catch {
            await MainActor.run { notify(title: "处理失败", subtitle: error.localizedDescription) }
            return false
        }
    }
    
    nonisolated private static func notify(title: String, subtitle: String) {
        Task { @MainActor in
            NotificationManager.send(title: title, subtitle: subtitle)
        }
    }
    
    /// 获取不重复的文件路径
    nonisolated private static func getUniqueFileURL(folder: URL, fileName: String, extension ext: String) -> URL {
        let fileManager = FileManager.default
        var destination = folder.appendingPathComponent("\(fileName).\(ext)")
        var counter = 1
        
        while fileManager.fileExists(atPath: destination.path) {
            destination = folder.appendingPathComponent("\(fileName) \(counter).\(ext)")
            counter += 1
        }
        
        return destination
    }
}
