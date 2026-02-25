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
    case grid
}

struct ImageStitcher {
    
    /// 处理多张图片拼接 (自动按文件名排序，智能判断方向)
    @MainActor
    static func process(imageURLs: [URL], isSilent: Bool = false) async {
        // 🔥 修复顺序：使用自然排序确保 1.jpg, 2.jpg, 10.jpg 顺序正确，不受 Finder 传入顺序影响
        let sortedURLs = imageURLs.sorted { 
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending 
        }
        
        // 1. 收集图片信息及其比例
        var landscapeCount = 0
        var portraitCount = 0
        var squareCount = 0
        var ratios: [Float] = []
        
        for url in sortedURLs {
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
               let width = props[kCGImagePropertyPixelWidth] as? Int,
               let height = props[kCGImagePropertyPixelHeight] as? Int {
                
                let ratio = Float(width) / Float(height)
                ratios.append(ratio)
                
                if width > height {
                    landscapeCount += 1
                } else if height > width {
                    portraitCount += 1
                } else {
                    squareCount += 1
                }
            }
        }
        
        // 2. 策略判断
        var direction: StitchDirection = .vertical
        
        // 特殊逻辑：4 张图片且比例相似 (误差 < 0.05) -> 优先四宫格
        if sortedURLs.count == 4 && ratios.count == 4 {
            let firstRatio = ratios[0]
            let allSameRatio = ratios.allSatisfy { abs($0 - firstRatio) < 0.05 }
            if allSameRatio {
                direction = .grid
                print("🧩 [智能拼图] 检测到 4 张等比例图片 -> 强制进入四宫格布局")
            }
        }
        
        // 如果不是四宫格，则走原有逻辑
        if direction != .grid {
            if portraitCount + squareCount >= landscapeCount {
                direction = .horizontal
            } else {
                direction = .vertical
            }
            print("🧩 [智能拼图] L:\(landscapeCount) P:\(portraitCount) S:\(squareCount) -> 方向: \(direction)")
        }
        
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
        struct DrawRect { let x: CGFloat; let y: CGFloat; let width: CGFloat; let height: CGFloat }
        var drawRects: [DrawRect] = []
        
        // 移动端优化基准: iPhone 17 标准版短边 1206px
        let mobileBaseline: CGFloat = 1206.0
        
        switch direction {
        case .grid:
            if validImages.count == 4 {
                // 四宫格逻辑: 2x2
                let maxWidth = CGFloat(validImages.map { $0.width }.max() ?? 0)
                let maxHeight = CGFloat(validImages.map { $0.height }.max() ?? 0)
                
                // 如果开启移动端优化，单张图的基准宽度
                let cellWidth = mobileOptimize ? mobileBaseline : maxWidth
                let cellHeight = cellWidth * (maxHeight / maxWidth)
                
                canvasWidth = Int(cellWidth * 2)
                canvasHeight = Int(cellHeight * 2)
                
                // 坐标计算 (Core Graphics 坐标系 y 轴向上)
                // 第一行 (视觉上): 0,1 (y 较大)
                // 第二行 (视觉上): 2,3 (y 较小)
                drawRects.append(DrawRect(x: 0, y: cellHeight, width: cellWidth, height: cellHeight))         // 左上
                drawRects.append(DrawRect(x: cellWidth, y: cellHeight, width: cellWidth, height: cellHeight)) // 右上
                drawRects.append(DrawRect(x: 0, y: 0, width: cellWidth, height: cellHeight))                  // 左下
                drawRects.append(DrawRect(x: cellWidth, y: 0, width: cellWidth, height: cellHeight))          // 右下
            } else {
                // Fallback to vertical if not 4 images for grid
                // This logic is similar to the .vertical case, but needs to calculate drawRects correctly for y-axis
                let targetWidth = mobileOptimize ? mobileBaseline : CGFloat(validImages.map { $0.width }.max() ?? 0)
                canvasWidth = Int(targetWidth)
                var totalHeight: CGFloat = 0
                var tempRects: [(w: CGFloat, h: CGFloat)] = []
                for item in validImages {
                    let scale = targetWidth / CGFloat(item.width)
                    let scaledHeight = CGFloat(item.height) * scale
                    tempRects.append((targetWidth, scaledHeight))
                    totalHeight += scaledHeight
                }
                canvasHeight = Int(ceil(totalHeight))

                var currentY = CGFloat(canvasHeight)
                for rect in tempRects {
                    currentY -= rect.h
                    drawRects.append(DrawRect(x: 0, y: currentY, width: rect.w, height: rect.h))
                }
            }
        case .vertical:
            let targetWidth = mobileOptimize ? mobileBaseline : CGFloat(validImages.map { $0.width }.max() ?? 0)
            canvasWidth = Int(targetWidth)
            var totalHeight: CGFloat = 0
            var tempRects: [(w: CGFloat, h: CGFloat)] = []
            for item in validImages {
                let scale = targetWidth / CGFloat(item.width)
                let scaledHeight = CGFloat(item.height) * scale
                tempRects.append((targetWidth, scaledHeight))
                totalHeight += scaledHeight
            }
            canvasHeight = Int(ceil(totalHeight))
            
            var currentY = CGFloat(canvasHeight)
            for rect in tempRects {
                currentY -= rect.h
                drawRects.append(DrawRect(x: 0, y: currentY, width: rect.w, height: rect.h))
            }
        case .horizontal:
            let targetHeight = mobileOptimize ? mobileBaseline : CGFloat(validImages.map { $0.height }.max() ?? 0)
            canvasHeight = Int(targetHeight)
            var totalWidth: CGFloat = 0
            var tempRects: [(w: CGFloat, h: CGFloat)] = []
            for item in validImages {
                let scale = targetHeight / CGFloat(item.height)
                let scaledWidth = CGFloat(item.width) * scale
                tempRects.append((scaledWidth, targetHeight))
                totalWidth += scaledWidth
            }
            canvasWidth = Int(ceil(totalWidth))
            
            var currentX: CGFloat = 0
            for rect in tempRects {
                drawRects.append(DrawRect(x: currentX, y: 0, width: rect.w, height: rect.h))
                currentX += rect.w
            }
        }
        
        // 3. 绘制拼接图 (后台)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: canvasWidth, height: canvasHeight, bitsPerComponent: 8, bytesPerRow: 0,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return false }
        
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight))
        
        for (index, item) in validImages.enumerated() {
            let r = drawRects[index]
            context.draw(item.image, in: CGRect(x: r.x, y: r.y, width: r.width, height: r.height))
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
