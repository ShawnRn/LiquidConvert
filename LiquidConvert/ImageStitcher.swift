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

struct ImageStitcher {
    
    enum StitchDirection {
        case vertical
        case horizontal
    }
    
    /// 处理多张图片拼接 (自动按文件名排序，智能判断方向)
    static func process(imageURLs: [URL]) async {
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
        
        await processOrdered(imageURLs: sortedURLs, direction: direction)
    }

    /// 处理多张图片拼接 (保持传入顺序)
    @discardableResult
    static func processOrdered(imageURLs: [URL], direction: StitchDirection) async -> Bool {
        guard imageURLs.count > 1 else { return false }
        
        let sortedURLs = imageURLs
        
        print("🧩 [拼图] 开始处理 \(sortedURLs.count) 张图片, 方向: \(direction)")
        
        // 1. 读取所有图片
        var validImages: [(image: CGImage, width: Int, height: Int)] = []
        
        for url in sortedURLs {
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                validImages.append((cgImage, cgImage.width, cgImage.height))
            } else {
                print("⚠️ [拼图] 无法读取图片: \(url.lastPathComponent)")
            }
        }
        
        guard !validImages.isEmpty else {
            notify(title: "拼图失败", subtitle: "无法读取任何有效的图片文件")
            return false
        }
        
        // 2. 计算画布尺寸 (基于等比缩放)
        var canvasWidth: Int = 0
        var canvasHeight: Int = 0
        
        struct DrawRect {
            let width: CGFloat
            let height: CGFloat
        }
        var drawRects: [DrawRect] = []
        
        switch direction {
        case .vertical:
            let targetWidth = CGFloat(validImages.map { $0.width }.max() ?? 0)
            canvasWidth = Int(targetWidth)
            
            var totalHeight: CGFloat = 0
            for item in validImages {
                let scale = targetWidth / CGFloat(item.width)
                let scaledHeight = CGFloat(item.height) * scale
                drawRects.append(DrawRect(width: targetWidth, height: scaledHeight))
                totalHeight += scaledHeight
            }
            canvasHeight = Int(ceil(totalHeight))
            
        case .horizontal:
            let targetHeight = CGFloat(validImages.map { $0.height }.max() ?? 0)
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
        
        guard canvasWidth > 0, canvasHeight > 0 else {
            notify(title: "拼图失败", subtitle: "图片尺寸计算错误")
            return false
        }
        
        // 3. 绘制拼接图
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: canvasWidth,
                height: canvasHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else {
            notify(title: "拼图失败", subtitle: "无法创建绘图上下文")
            return false
        }
        
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight))
        
        if direction == .vertical {
            var currentY = CGFloat(canvasHeight)
            for (index, item) in validImages.enumerated() {
                let rectInfo = drawRects[index]
                currentY -= rectInfo.height
                let drawRect = CGRect(x: 0, y: currentY, width: rectInfo.width, height: rectInfo.height)
                context.draw(item.image, in: drawRect)
            }
        } else {
            var currentX: CGFloat = 0
            for (index, item) in validImages.enumerated() {
                let rectInfo = drawRects[index]
                let drawRect = CGRect(x: currentX, y: 0, width: rectInfo.width, height: rectInfo.height)
                context.draw(item.image, in: drawRect)
                currentX += rectInfo.width
            }
        }

        guard let stitchedImage = context.makeImage() else {
            notify(title: "拼图失败", subtitle: "无法生成拼接图片")
            return false
        }
        
        // 4. 保存为临时文件
        let tempFolder = FileManager.default.temporaryDirectory
        let tempFileName = "stitched_temp_\(UUID().uuidString).jpg"
        let tempURL = tempFolder.appendingPathComponent(tempFileName)
        
        guard let destination = CGImageDestinationCreateWithURL(tempURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            notify(title: "系统错误", subtitle: "无法创建临时文件")
            return false
        }
        
        CGImageDestinationAddImage(destination, stitchedImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            notify(title: "系统错误", subtitle: "无法写入临时文件")
            return false
        }
        
        // 5. 弹出保存对话框 (NSSavePanel)
        let finalDestination = await MainActor.run { () -> URL? in
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType.jpeg]
            panel.canCreateDirectories = true
            panel.isExtensionHidden = false
            panel.title = "保存拼接图片"
            panel.message = "选择保存位置"
            panel.nameFieldStringValue = "\(sortedURLs.first?.deletingPathExtension().lastPathComponent ?? "Untitled")_stitched"
            
            return panel.runModal() == .OK ? panel.url : nil
        }
        
        guard let finalURL = finalDestination else {
            notify(title: "取消保存", subtitle: "用户取消了操作")
            return false
        }
        
        // 6. 调用压缩逻辑
        let options = ImageCompressor.CompressionOptions(
            resizeMode: .none,
            quality: 0.9,
            deleteOriginal: true,
            autoCompressTo5MB: true,
            targetFormat: .jpeg
        )
        
        do {
            let compressedTempURL = try ImageCompressor.compress(inputURL: tempURL, options: options)
            
            if FileManager.default.fileExists(atPath: finalURL.path) {
                try FileManager.default.removeItem(at: finalURL)
            }
            try FileManager.default.moveItem(at: compressedTempURL, to: finalURL)
            
            print("✅ [完成] 拼图已保存: \(finalURL.path)")
            
            await MainActor.run {
                notify(title: "拼图完成", subtitle: "已保存为 \(finalURL.lastPathComponent)")
                NSSound(named: "Glass")?.play()
                NSWorkspace.shared.activateFileViewerSelecting([finalURL])
            }
            
            return true
            
        } catch {
            print("❌ [错误] 压缩失败: \(error.localizedDescription)")
            notify(title: "处理失败", subtitle: error.localizedDescription)
            return false
        }
    }
    
    private static func notify(title: String, subtitle: String) {
        NotificationManager.send(title: title, subtitle: subtitle)
    }
    
    /// 获取不重复的文件路径
    private static func getUniqueFileURL(folder: URL, fileName: String, extension ext: String) -> URL {
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
