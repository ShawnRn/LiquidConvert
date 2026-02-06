//
//  ImageCompressor.swift
//  LiquidConvert
//
//  Created by Shawn Rain.
//

import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers


// Types moved to ImageCompressorTypes.swift

struct ImageCompressor {
    // 保持类型嵌套引用别名，防止破坏过多代码，但也支持直接访问顶层类型
    typealias ResizeMode = ImageResizeMode
    typealias CompressionOptions = ImageCompressionOptions

    /// 主压缩方法
    nonisolated static func compress(
        inputURL: URL, options: CompressionOptions, progressCallback: (@Sendable (String) -> Void)? = nil
    ) throws -> URL {
        let ext = inputURL.pathExtension.lowercased()

        // GIF 特殊处理：支持智能自动压缩 + 手动参数压缩
        if ext == "gif" {
            // 智能自动压缩到 5MB
            if options.autoCompressTo5MB {
                return try smartCompressGIF(
                    inputURL: inputURL, options: options, progressCallback: progressCallback)
            }

            // 如果完全不需要任何处理，直接复制文件
            if options.resizeMode == .none && options.gifColorDepth == nil
                && options.gifFrameRate == nil
            {
                let outputURL = generateOutputURL(from: inputURL, targetExtension: "gif")
                try FileManager.default.copyItem(at: inputURL, to: outputURL)
                if options.deleteOriginal {
                    try? FileManager.default.removeItem(at: inputURL)
                }
                return outputURL
            }

            // 手动参数压缩
            return try resizeImage(
                inputURL: inputURL, resizeMode: options.resizeMode, isGIF: true,
                deleteOriginal: options.deleteOriginal, options: options)
        }

        guard let source = CGImageSourceCreateWithURL(inputURL as CFURL, nil) else {
            throw NSError(
                domain: "ImageCompressor", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "无法读取源图片"])
        }

        guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw NSError(
                domain: "ImageCompressor", code: -2,
                userInfo: [NSLocalizedDescriptionKey: "无法解码图片"])
        }

        // 智能自动压缩到 5MB（非 GIF 图片）
        if options.autoCompressTo5MB {
            let targetFormat = options.targetFormat ?? determineOutputFormat(from: ext)
            let fileSize = getFileSize(url: inputURL) ?? 0
            
            // 🔥 智能跳过逻辑：如果格式不需要改变，且已经小于 5MB，且不需要调整尺寸 -> 直接原样输出
            // 杜绝无效处理导致的文件变大
            if targetFormat == determineOutputFormat(from: ext) && 
               fileSize <= 4_800_000 && 
               options.resizeMode == .none {
                print("⏭️ 智能跳过: \(inputURL.lastPathComponent) (已达标)")
                
                let outputURL = generateOutputURL(from: inputURL, targetExtension: ext)
                // 如果输出路径和输入路径不一致（即不是原地覆盖），则复制一份
                if outputURL.path != inputURL.path {
                    if FileManager.default.fileExists(atPath: outputURL.path) {
                        try? FileManager.default.removeItem(at: outputURL)
                    }
                    try FileManager.default.copyItem(at: inputURL, to: outputURL)
                }
                
                if options.deleteOriginal {
                    try? FileManager.default.removeItem(at: inputURL)
                }
                return outputURL
            }

            return try smartCompressImage(
                inputURL: inputURL,
                source: source,
                cgImage: cgImage,
                format: targetFormat,
                options: options
            )
        }

        // 1. 调整分辨率（如果需要）
        var workingImage = cgImage
        if options.resizeMode != .none {
            workingImage = try resizeImage(cgImage: cgImage, resizeMode: options.resizeMode)
        }

        // 2. 确定输出格式
        let outputFormat: UTType
        if let targetFormat = options.targetFormat {
            outputFormat = targetFormat
        } else {
            outputFormat = determineOutputFormat(from: ext)
        }

        // 3. 生成输出路径
        // 3. 生成输出路径
        let outputURL = generateOutputURL(
            from: inputURL, targetExtension: outputFormat.preferredFilenameExtension)

        // 4. 获取元数据
        let srcProperties =
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        var destProperties = srcProperties

        // 5. 质量处理（手动模式）
        destProperties[kCGImageDestinationLossyCompressionQuality] = options.quality

        // 6. 写入输出文件
        guard
            let destination = CGImageDestinationCreateWithURL(
                outputURL as CFURL, outputFormat.identifier as CFString, 1, nil
            )
        else {
            throw NSError(
                domain: "ImageCompressor", code: -3,
                userInfo: [NSLocalizedDescriptionKey: "无法创建输出文件"])
        }

        CGImageDestinationAddImage(destination, workingImage, destProperties as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            throw NSError(
                domain: "ImageCompressor", code: -4,
                userInfo: [NSLocalizedDescriptionKey: "写入文件失败"])
        }

        // 7. 删除源文件（如果需要）
        if options.deleteOriginal {
            try? FileManager.default.removeItem(at: inputURL)
        }

        return outputURL
    }

    // MARK: - 智能图片压缩（非 GIF）

    /// 智能压缩普通图片到目标大小
    nonisolated private static func smartCompressImage(
        inputURL: URL,
        source: CGImageSource,
        cgImage: CGImage,
        format: UTType,
        options: CompressionOptions,
        progressCallback: ((String) -> Void)? = nil
    ) throws -> URL {
        let targetSizeBytes: Int64 = 4_800_000  // 4.8MB (十进制，匹配macOS显示)
        let originalWidth = cgImage.width
        let originalHeight = cgImage.height

        progressCallback?("🤖 智能压缩: \(originalWidth)×\(originalHeight)")
        print(
            "🤖 智能图片压缩: \(originalWidth)×\(originalHeight), 格式: \(format.preferredFilenameExtension ?? "unknown")"
        )

        // 无损格式只能调整分辨率
        let isLossless = (format == .png || format == .tiff)

        if isLossless {
            print("📌 无损格式，仅调整分辨率")
            return try smartCompressLossless(
                inputURL: inputURL,
                source: source,
                cgImage: cgImage,
                format: format,
                targetSize: targetSizeBytes,
                options: options,
                progressCallback: progressCallback
            )
        } else {
            print("📌 有损格式，调整分辨率和质量")
            return try smartCompressLossy(
                inputURL: inputURL,
                source: source,
                cgImage: cgImage,
                format: format,
                targetSize: targetSizeBytes,
                options: options,
                progressCallback: progressCallback
            )
        }
    }

    /// 智能压缩有损格式（JPG/HEIC/WebP）
    nonisolated private static func smartCompressLossy(
        inputURL: URL,
        source: CGImageSource,
        cgImage: CGImage,
        format: UTType,
        targetSize: Int64,
        options: CompressionOptions,
        progressCallback: ((String) -> Void)? = nil
    ) throws -> URL {
        let originalWidth = cgImage.width
        let originalHeight = cgImage.height
        let maxDimension = max(originalWidth, originalHeight)

        // 策略：先降低质量，再降低分辨率，分辨率下限 1080p
        let qualitySteps = [0.9, 0.8, 0.7, 0.6, 0.5, 0.4, 0.3]
        
        // 动态生成分辨率步进
        // 逻辑：从 1.0 开始，每次减少 0.1，直到 longEdge 接近 1080
        var currentScale = 1.0
        let minLongEdge = 1080
        
        while true {
            let currentLongEdge = Int(Double(maxDimension) * currentScale)
            
            // 如果计算出的长边小于 1080，强制设为 1080 尝试一次，然后退出循环
            // (除非原图本身就小于 1080，那就保持原图尺寸)
            let effectiveScale: Double
            let isFinalTry: Bool
            
            if currentLongEdge < minLongEdge && maxDimension > minLongEdge {
                effectiveScale = Double(minLongEdge) / Double(maxDimension)
                isFinalTry = true
            } else {
                effectiveScale = currentScale
                isFinalTry = false
            }
            
            // 内部循环：尝试不同质量
            for quality in qualitySteps {
                let resizeMode: ResizeMode =
                    effectiveScale >= 0.99 ? .none : .longEdge(pixels: Int(Double(maxDimension) * effectiveScale))

                let testImage =
                    effectiveScale >= 0.99
                    ? cgImage : try resizeImage(cgImage: cgImage, resizeMode: resizeMode)
                let fileSize = try estimateFileSize(
                    image: testImage, format: format, quality: quality, source: source)

                let progressMsg =
                    "🔍 测试: 分辨率×\(Int(effectiveScale*100))% (\(testImage.width)x\(testImage.height)), 质量\(Int(quality*100))% → \(String(format: "%.1f", Double(fileSize)/1_000_000))MB"
                progressCallback?(progressMsg)
                print(progressMsg)
                Thread.sleep(forTimeInterval: 0.05)  // 50ms延迟让进度可见

                if fileSize <= targetSize && fileSize > 0 {
                    print("✅ 最佳参数: 分辨率×\(Int(effectiveScale*100))%, 质量\(Int(quality*100))%")
                    return try finalizeCompression(
                        image: testImage,
                        inputURL: inputURL,
                        format: format,
                        quality: quality,
                        source: source,
                        deleteOriginal: options.deleteOriginal
                    )
                }
            }
            
            if isFinalTry { break }
            
            // 准备下一次迭代
            currentScale -= 0.1
            if currentScale < 0.1 { break } // 防止无限循环
        }

        // 兜底策略：使用 1080p + 0.2 质量 (即使超过 5MB 也返回，作为 Best Effort)
        print("⚠️ 无法满足 <5MB，使用兜底参数 (1080p, Q0.2)")
        let minimalLongEdge = maxDimension > minLongEdge ? minLongEdge : maxDimension
        let extremeImage = try resizeImage(
            cgImage: cgImage, resizeMode: .longEdge(pixels: minimalLongEdge))
        return try finalizeCompression(
            image: extremeImage,
            inputURL: inputURL,
            format: format,
            quality: 0.2,
            source: source,
            deleteOriginal: options.deleteOriginal
        )
    }

    /// 智能压缩无损格式（PNG/TIFF）
    nonisolated private static func smartCompressLossless(
        inputURL: URL,
        source: CGImageSource,
        cgImage: CGImage,
        format: UTType,
        targetSize: Int64,
        options: CompressionOptions,
        progressCallback: ((String) -> Void)? = nil
    ) throws -> URL {
        let originalWidth = cgImage.width
        let originalHeight = cgImage.height
        let maxDimension = max(originalWidth, originalHeight)

        // 无损格式只能通过分辨率降低文件大小
        let resolutionSteps = [1.0, 0.9, 0.8, 0.7, 0.6, 0.5, 0.4, 0.3, 0.2]

        for scale in resolutionSteps {
            let resizeMode: ResizeMode =
                scale == 1.0 ? .none : .longEdge(pixels: Int(Double(maxDimension) * scale))
            let testImage =
                scale == 1.0 ? cgImage : try resizeImage(cgImage: cgImage, resizeMode: resizeMode)
            let fileSize = try estimateFileSize(
                image: testImage, format: format, quality: 1.0, source: source)

            progressCallback?("🔍 测试: 分辨率×\(Int(scale*100))%")
            print("🔍 测试: 分辨率×\(Int(scale*100))% → \(fileSize/1024)KB")

            if fileSize <= targetSize && fileSize > 0 {
                print("✅ 最佳参数: 分辨率×\(Int(scale*100))%")
                return try finalizeCompression(
                    image: testImage,
                    inputURL: inputURL,
                    format: format,
                    quality: 1.0,
                    source: source,
                    deleteOriginal: options.deleteOriginal
                )
            }
        }

        // 极限压缩
        print("⚠️ 使用极限压缩参数")
        let extremeImage = try resizeImage(
            cgImage: cgImage, resizeMode: .longEdge(pixels: Int(Double(maxDimension) * 0.15)))
        return try finalizeCompression(
            image: extremeImage,
            inputURL: inputURL,
            format: format,
            quality: 1.0,
            source: source,
            deleteOriginal: options.deleteOriginal
        )
    }

    /// 估算文件大小
    nonisolated private static func estimateFileSize(
        image: CGImage,
        format: UTType,
        quality: Double,
        source: CGImageSource
    ) throws -> Int64 {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "est_\(UUID().uuidString).\(format.preferredFilenameExtension ?? "tmp")")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        guard
            let destination = CGImageDestinationCreateWithURL(
                tempURL as CFURL, format.identifier as CFString, 1, nil)
        else {
            throw NSError(
                domain: "ImageCompressor", code: -30,
                userInfo: [NSLocalizedDescriptionKey: "无法创建估算文件"])
        }

        var properties =
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        properties[kCGImageDestinationLossyCompressionQuality] = quality

        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        CGImageDestinationFinalize(destination)

        return getFileSize(url: tempURL) ?? 0
    }

    /// 完成压缩并输出文件
    nonisolated private static func finalizeCompression(
        image: CGImage,
        inputURL: URL,
        format: UTType,
        quality: Double,
        source: CGImageSource,
        deleteOriginal: Bool
    ) throws -> URL {
        let outputURL = generateOutputURL(
            from: inputURL, targetExtension: format.preferredFilenameExtension)

        guard
            let destination = CGImageDestinationCreateWithURL(
                outputURL as CFURL, format.identifier as CFString, 1, nil)
        else {
            throw NSError(
                domain: "ImageCompressor", code: -3,
                userInfo: [NSLocalizedDescriptionKey: "无法创建输出文件"])
        }

        var properties =
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        properties[kCGImageDestinationLossyCompressionQuality] = quality

        CGImageDestinationAddImage(destination, image, properties as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            throw NSError(
                domain: "ImageCompressor", code: -4, userInfo: [NSLocalizedDescriptionKey: "写入文件失败"]
            )
        }

        if deleteOriginal {
            try? FileManager.default.removeItem(at: inputURL)
        }

        return outputURL
    }

    // MARK: - 分辨率调整

    /// 调整图片分辨率（支持超采样）
    nonisolated private static func resizeImage(cgImage: CGImage, resizeMode: ResizeMode) throws -> CGImage {
        let originalWidth = cgImage.width
        let originalHeight = cgImage.height

        let (newWidth, newHeight) = calculateNewSize(
            originalWidth: originalWidth,
            originalHeight: originalHeight,
            resizeMode: resizeMode
        )

        // 如果尺寸没有变化，直接返回原图
        if newWidth == originalWidth && newHeight == originalHeight {
            return cgImage
        }

        print("📐 调整分辨率: \(originalWidth)x\(originalHeight) -> \(newWidth)x\(newHeight)")

        // 🔥 超采样：如果是缩小操作，使用两步缩放获得更好的质量
        let isDownscaling = newWidth < originalWidth || newHeight < originalHeight

        if isDownscaling {
            // 超采样流程：原始 -> 2倍中间尺寸 -> 目标尺寸
            let intermediateWidth = newWidth * 2
            let intermediateHeight = newHeight * 2

            print(
                "🔬 使用超采样: \(originalWidth)x\(originalHeight) -> \(intermediateWidth)x\(intermediateHeight) -> \(newWidth)x\(newHeight)"
            )

            // 第一步：缩放到2倍中间尺寸
            let intermediateImage = try createResizedImage(
                from: cgImage,
                width: intermediateWidth,
                height: intermediateHeight
            )

            // 第二步：从中间尺寸缩放到目标尺寸
            return try createResizedImage(
                from: intermediateImage,
                width: newWidth,
                height: newHeight
            )
        } else {
            // 放大操作：直接单次缩放
            print("↗️ 单次放大缩放")
            return try createResizedImage(
                from: cgImage,
                width: newWidth,
                height: newHeight
            )
        }
    }

    /// 辅助方法：创建指定尺寸的图片
    nonisolated private static func createResizedImage(
        from cgImage: CGImage,
        width: Int,
        height: Int
    ) throws -> CGImage {
        let colorSpace = cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            throw NSError(
                domain: "ImageCompressor", code: -5,
                userInfo: [NSLocalizedDescriptionKey: "无法创建图片上下文"])
        }

        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let resizedImage = context.makeImage() else {
            throw NSError(
                domain: "ImageCompressor", code: -6,
                userInfo: [NSLocalizedDescriptionKey: "分辨率调整失败"])
        }

        return resizedImage
    }

    /// GIF 分辨率调整和压缩（保持 GIF 格式和动画）
    nonisolated private static func resizeImage(
        inputURL: URL, resizeMode: ResizeMode, isGIF: Bool, deleteOriginal: Bool = false,
        options: CompressionOptions
    ) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(inputURL as CFURL, nil) else {
            throw NSError(
                domain: "ImageCompressor", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "无法读取 GIF 图片"])
        }

        let totalFrameCount = CGImageSourceGetCount(source)
        print("📸 GIF 原始帧数: \(totalFrameCount)")

        // 计算帧采样
        let (selectedFrames, targetFPS) = calculateFrameSampling(
            source: source,
            totalFrames: totalFrameCount,
            targetFPS: options.gifFrameRate
        )

        print("🎬 处理帧数: \(selectedFrames.count)/\(totalFrameCount), 目标FPS: \(targetFPS ?? 0)")

        let outputURL = generateOutputURL(from: inputURL, targetExtension: "gif")

        // 获取 GIF 全局属性
        let fileProperties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any] ?? [:]

        // 设置颜色深度（如果指定）
        if let colorDepth = options.gifColorDepth {
            print("🎨 色深限制: \(colorDepth) 色")
        }

        guard
            let destination = CGImageDestinationCreateWithURL(
                outputURL as CFURL, UTType.gif.identifier as CFString, selectedFrames.count, nil
            )
        else {
            throw NSError(
                domain: "ImageCompressor", code: -3,
                userInfo: [NSLocalizedDescriptionKey: "无法创建 GIF 输出"])
        }

        // 设置 GIF 全局属性
        CGImageDestinationSetProperties(destination, fileProperties as CFDictionary)

        // 处理选中的帧
        for frameIndex in selectedFrames {
            guard let cgImage = CGImageSourceCreateImageAtIndex(source, frameIndex, nil) else {
                print("⚠️ 跳过损坏的帧 \(frameIndex)")
                continue
            }

            // 调整分辨率
            let resizedImage = try resizeImage(cgImage: cgImage, resizeMode: resizeMode)

            // 颜色量化（如果指定）
            let finalImage: CGImage
            if let colorDepth = options.gifColorDepth {
                finalImage = try quantizeColors(image: resizedImage, maxColors: colorDepth)
            } else {
                finalImage = resizedImage
            }

            // 获取并调整帧属性
            var frameProperties =
                CGImageSourceCopyPropertiesAtIndex(source, frameIndex, nil) as? [CFString: Any]
                ?? [:]

            // 调整帧延迟（如果改变了帧率）
            if let targetFPS = targetFPS,
                var gifDict = frameProperties[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            {
                let newDelay = 1.0 / Double(targetFPS)
                gifDict[kCGImagePropertyGIFDelayTime] = newDelay
                gifDict[kCGImagePropertyGIFUnclampedDelayTime] = newDelay
                frameProperties[kCGImagePropertyGIFDictionary] = gifDict
            }

            CGImageDestinationAddImage(destination, finalImage, frameProperties as CFDictionary)
        }

        guard CGImageDestinationFinalize(destination) else {
            throw NSError(
                domain: "ImageCompressor", code: -4,
                userInfo: [NSLocalizedDescriptionKey: "写入 GIF 失败"])
        }

        // 显示压缩结果
        let originalSize =
            try? FileManager.default.attributesOfItem(atPath: inputURL.path)[.size] as? Int64 ?? 0
        let compressedSize =
            try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64 ?? 0
        if let orig = originalSize, let comp = compressedSize {
            let ratio = Double(comp) / Double(orig) * 100
            print(
                "✅ GIF 压缩完成: \(selectedFrames.count) 帧, \(orig/1024)KB → \(comp/1024)KB (\(Int(ratio))%)"
            )
        }

        // 删除源文件（如果需要）
        if deleteOriginal {
            try? FileManager.default.removeItem(at: inputURL)
        }

        return outputURL
    }

    /// 计算帧采样策略
    nonisolated private static func calculateFrameSampling(
        source: CGImageSource, totalFrames: Int, targetFPS: Int?
    ) -> ([Int], Int?) {
        // 如果没有指定目标 FPS，使用所有帧
        guard let targetFPS = targetFPS, totalFrames > 1 else {
            return (Array(0..<totalFrames), nil)
        }

        // 计算原始 FPS
        var totalDuration: Double = 0
        for i in 0..<totalFrames {
            if let properties = CGImageSourceCopyPropertiesAtIndex(source, i, nil)
                as? [CFString: Any],
                let gifDict = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            {
                let delay =
                    gifDict[kCGImagePropertyGIFUnclampedDelayTime] as? Double
                    ?? gifDict[kCGImagePropertyGIFDelayTime] as? Double
                    ?? 0.1
                totalDuration += delay
            }
        }

        let originalFPS = totalDuration > 0 ? Double(totalFrames) / totalDuration : 10
        print("📊 原始 FPS: \(Int(originalFPS))")

        // 如果目标 FPS >= 原始 FPS，不需要抽帧
        if Double(targetFPS) >= originalFPS {
            return (Array(0..<totalFrames), nil)
        }

        // 计算采样间隔
        let samplingRatio = originalFPS / Double(targetFPS)
        var selectedFrames: [Int] = []

        for i in 0..<totalFrames {
            if selectedFrames.isEmpty || Double(i) >= Double(selectedFrames.last!) + samplingRatio {
                selectedFrames.append(i)
            }
        }

        // 确保至少有第一帧和最后一帧
        if !selectedFrames.contains(0) {
            selectedFrames.insert(0, at: 0)
        }
        if !selectedFrames.contains(totalFrames - 1) {
            selectedFrames.append(totalFrames - 1)
        }

        return (selectedFrames, targetFPS)
    }

    /// 颜色量化（减少颜色数量）
    nonisolated private static func quantizeColors(image: CGImage, maxColors: Int) throws -> CGImage {
        // 使用中位切分算法进行颜色量化
        let width = image.width
        let height = image.height

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            throw NSError(
                domain: "ImageCompressor", code: -20,
                userInfo: [NSLocalizedDescriptionKey: "无法创建量化上下文"])
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let quantizedImage = context.makeImage() else {
            throw NSError(
                domain: "ImageCompressor", code: -21,
                userInfo: [NSLocalizedDescriptionKey: "颜色量化失败"])
        }

        return quantizedImage
    }

    /// 计算新尺寸
    nonisolated private static func calculateNewSize(
        originalWidth: Int, originalHeight: Int, resizeMode: ResizeMode
    ) -> (Int, Int) {
        switch resizeMode {
        case .none:
            return (originalWidth, originalHeight)

        case .longEdge(let pixels):
            if originalWidth >= originalHeight {
                // 横图或方图：宽度是长边
                let scale = Double(pixels) / Double(originalWidth)
                return (pixels, Int(Double(originalHeight) * scale))
            } else {
                // 竖图：高度是长边
                let scale = Double(pixels) / Double(originalHeight)
                return (Int(Double(originalWidth) * scale), pixels)
            }

        case .shortEdge(let pixels):
            if originalWidth <= originalHeight {
                // 横图或方图：宽度是短边
                let scale = Double(pixels) / Double(originalWidth)
                return (pixels, Int(Double(originalHeight) * scale))
            } else {
                // 竖图：高度是短边
                let scale = Double(pixels) / Double(originalHeight)
                return (Int(Double(originalWidth) * scale), pixels)
            }

        case .to720p:
            // 长边设为1280
            let targetPixels = 1280
            if originalWidth >= originalHeight {
                let scale = Double(targetPixels) / Double(originalWidth)
                return (targetPixels, Int(Double(originalHeight) * scale))
            } else {
                let scale = Double(targetPixels) / Double(originalHeight)
                return (Int(Double(originalWidth) * scale), targetPixels)
            }

        case .to1080p:
            // 长边设为1920
            let targetPixels = 1920
            if originalWidth >= originalHeight {
                let scale = Double(targetPixels) / Double(originalWidth)
                return (targetPixels, Int(Double(originalHeight) * scale))
            } else {
                let scale = Double(targetPixels) / Double(originalHeight)
                return (Int(Double(originalWidth) * scale), targetPixels)
            }

        case .scale50:
            return (originalWidth / 2, originalHeight / 2)

        case .scale30:
            return (Int(Double(originalWidth) * 0.3), Int(Double(originalHeight) * 0.3))

        case .custom(let width, let height):
            return (width, height)
        }
    }

    // MARK: - 自动压缩到 5MB

    nonisolated private static func findOptimalQuality(
        image: CGImage,
        format: UTType,
        targetSize: Int64,
        properties: [CFString: Any]
    ) throws -> Double {
        var minQuality = 0.1
        var maxQuality = 0.95
        var bestQuality = maxQuality
        let maxIterations = 10

        let tempFolder = FileManager.default.temporaryDirectory
        let tempURL = tempFolder.appendingPathComponent(
            "temp_compress_test.\(format.preferredFilenameExtension ?? "jpg")")

        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        for iteration in 0..<maxIterations {
            let testQuality = (minQuality + maxQuality) / 2.0
            var testProperties = properties
            testProperties[kCGImageDestinationLossyCompressionQuality] = testQuality

            try? FileManager.default.removeItem(at: tempURL)

            guard
                let destination = CGImageDestinationCreateWithURL(
                    tempURL as CFURL, format.identifier as CFString, 1, nil
                )
            else {
                throw NSError(
                    domain: "ImageCompressor", code: -7,
                    userInfo: [NSLocalizedDescriptionKey: "无法创建临时文件"])
            }

            CGImageDestinationAddImage(destination, image, testProperties as CFDictionary)

            guard CGImageDestinationFinalize(destination) else {
                throw NSError(
                    domain: "ImageCompressor", code: -8,
                    userInfo: [NSLocalizedDescriptionKey: "写入临时文件失败"])
            }

            guard let fileSize = getFileSize(url: tempURL) else {
                throw NSError(
                    domain: "ImageCompressor", code: -9,
                    userInfo: [NSLocalizedDescriptionKey: "无法获取文件大小"])
            }

            print(
                "🔍 压缩测试 [\(iteration + 1)/\(maxIterations)]: 质量=\(Int(testQuality * 100))%, 大小=\(fileSize / 1024)KB, 目标=\(targetSize / 1024)KB"
            )

            if fileSize <= targetSize {
                bestQuality = testQuality
                minQuality = testQuality

                if fileSize > targetSize * 9 / 10 {
                    break
                }
            } else {
                maxQuality = testQuality
            }

            if maxQuality - minQuality < 0.01 {
                break
            }
        }

        print("✅ 最终压缩质量: \(Int(bestQuality * 100))%")
        return bestQuality
    }

    // MARK: - 辅助方法

    nonisolated private static func determineOutputFormat(from ext: String) -> UTType {
        switch ext {
        case "jpg", "jpeg": return .jpeg
        case "png": return .png
        case "heic", "heif": return .heic
        case "webp": return .webP
        case "tiff", "tif": return .tiff
        default: return .jpeg
        }
    }

    nonisolated private static func generateOutputURL(from inputURL: URL, targetExtension: String? = nil) -> URL
    {
        let folder = inputURL.deletingLastPathComponent()
        let baseName = inputURL.deletingPathExtension().lastPathComponent
        let ext = targetExtension ?? inputURL.pathExtension

        var counter = 1
        var outputURL = folder.appendingPathComponent("\(baseName)_compressed.\(ext)")

        while FileManager.default.fileExists(atPath: outputURL.path) {
            outputURL = folder.appendingPathComponent("\(baseName)_compressed_\(counter).\(ext)")
            counter += 1
        }

        return outputURL
    }

    nonisolated private static func getFileSize(url: URL) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = attrs[.size] as? Int64
        else {
            return nil
        }
        return size
    }

    nonisolated private static func createTempSource(from image: CGImage, properties: [CFString: Any]) throws
        -> CGImageSource
    {
        // 创建临时数据用于二分查找
        let tempData = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                tempData, UTType.jpeg.identifier as CFString, 1, nil)
        else {
            throw NSError(
                domain: "ImageCompressor", code: -11,
                userInfo: [NSLocalizedDescriptionKey: "创建临时源失败"])
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        CGImageDestinationFinalize(destination)

        guard let source = CGImageSourceCreateWithData(tempData, nil) else {
            throw NSError(
                domain: "ImageCompressor", code: -12, userInfo: [NSLocalizedDescriptionKey: "创建源失败"]
            )
        }
        return source
    }

    nonisolated private static func cleanupTempSource(_ source: CGImageSource?) {
        // CGImageSource 由 ARC 管理，无需手动清理
    }

    // MARK: - 智能 GIF 压缩

    /// 智能压缩 GIF 到目标大小（默认 5MB）
    nonisolated private static func smartCompressGIF(
        inputURL: URL, options: CompressionOptions, progressCallback: ((String) -> Void)? = nil
    ) throws -> URL {
        let targetSizeBytes: Int64 = 4_800_000  // 4.8MB (十进制，匹配macOS显示)
        let priority = options.gifCompressionPriority ?? .resolution

        progressCallback?("🤖 智能 GIF: 目标4.8MB, \(priority == .resolution ? "分辨率优先" : "色彩优先")")
        print("🤖 智能 GIF 压缩开始: 目标 4.8MB, 优先级: \(priority == .resolution ? "分辨率优先" : "色彩优先")")

        // 获取原始信息
        guard let source = CGImageSourceCreateWithURL(inputURL as CFURL, nil) else {
            throw NSError(
                domain: "ImageCompressor", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "无法读取 GIF"])
        }

        guard let firstImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw NSError(
                domain: "ImageCompressor", code: -2,
                userInfo: [NSLocalizedDescriptionKey: "无法读取 GIF 帧"])
        }

        let originalWidth = firstImage.width
        let originalHeight = firstImage.height
        let totalFrames = CGImageSourceGetCount(source)

        // 计算原始 FPS
        var totalDuration: Double = 0
        for i in 0..<totalFrames {
            if let properties = CGImageSourceCopyPropertiesAtIndex(source, i, nil)
                as? [CFString: Any],
                let gifDict = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            {
                let delay =
                    gifDict[kCGImagePropertyGIFUnclampedDelayTime] as? Double
                    ?? gifDict[kCGImagePropertyGIFDelayTime] as? Double ?? 0.1
                totalDuration += delay
            }
        }
        let originalFPS = totalDuration > 0 ? Int(Double(totalFrames) / totalDuration) : 15

        print("📊 原始: \(originalWidth)×\(originalHeight), \(totalFrames)帧, \(originalFPS)fps")

        // 根据优先级选择压缩策略
        if priority == .resolution {
            // 分辨率优先：先降低颜色和帧率，最后才减少分辨率
            return try compressGIFResolutionPriority(
                inputURL: inputURL,
                source: source,
                targetSize: targetSizeBytes,
                originalWidth: originalWidth,
                originalHeight: originalHeight,
                originalFPS: originalFPS,
                options: options
            )
        } else {
            // 色彩优先：先降低分辨率和帧率，尽量保持颜色
            return try compressGIFColorPriority(
                inputURL: inputURL,
                source: source,
                targetSize: targetSizeBytes,
                originalWidth: originalWidth,
                originalHeight: originalHeight,
                originalFPS: originalFPS,
                options: options
            )
        }
    }

    /// 分辨率优先压缩策略
    nonisolated private static func compressGIFResolutionPriority(
        inputURL: URL,
        source: CGImageSource,
        targetSize: Int64,
        originalWidth: Int,
        originalHeight: Int,
        originalFPS: Int,
        options: CompressionOptions
    ) throws -> URL {
        // 策略：保持分辨率，逐步降低 色深 → FPS → 分辨率
        let colorDepthSteps = [256, 128, 64, 32]
        let fpsSteps = [originalFPS, max(15, originalFPS / 2), 10, 8, 5]
        let resolutionSteps = [1.0, 0.8, 0.6, 0.5, 0.4]

        for scale in resolutionSteps {
            for fps in fpsSteps {
                for colorDepth in colorDepthSteps {
                    let testOptions = CompressionOptions(
                        resizeMode: scale == 1.0
                            ? .none
                            : .longEdge(
                                pixels: Int(Double(max(originalWidth, originalHeight)) * scale)),
                        quality: options.quality,
                        deleteOriginal: false,
                        autoCompressTo5MB: false,
                        targetFormat: nil,
                        gifFrameRate: fps,
                        gifColorDepth: colorDepth
                    )

                    let tempURL = try testCompressGIF(inputURL: inputURL, options: testOptions)
                    let fileSize = getFileSize(url: tempURL) ?? 0

                    print(
                        "🔍 测试: 分辨率×\(Int(scale*100))%, \(fps)fps, \(colorDepth)色 → \(fileSize/1024)KB"
                    )

                    if fileSize <= targetSize && fileSize > 0 {
                        // 找到合适的参数，生成最终文件
                        try? FileManager.default.removeItem(at: tempURL)

                        var finalOptions = testOptions
                        finalOptions.deleteOriginal = options.deleteOriginal

                        print("✅ 最佳参数: 分辨率×\(Int(scale*100))%, \(fps)fps, \(colorDepth)色")
                        return try resizeImage(
                            inputURL: inputURL, resizeMode: finalOptions.resizeMode, isGIF: true,
                            deleteOriginal: options.deleteOriginal, options: finalOptions)
                    }

                    try? FileManager.default.removeItem(at: tempURL)
                }
            }
        }

        // 如果所有组合都不行，使用最激进的压缩
        let fallbackOptions = CompressionOptions(
            resizeMode: .longEdge(pixels: Int(Double(max(originalWidth, originalHeight)) * 0.3)),
            quality: 0.9,
            deleteOriginal: options.deleteOriginal,
            autoCompressTo5MB: false,
            targetFormat: nil,
            gifFrameRate: 5,
            gifColorDepth: 32
        )
        print("⚠️ 使用极限压缩参数")
        return try resizeImage(
            inputURL: inputURL, resizeMode: fallbackOptions.resizeMode, isGIF: true,
            deleteOriginal: options.deleteOriginal, options: fallbackOptions)
    }

    /// 色彩优先压缩策略
    nonisolated private static func compressGIFColorPriority(
        inputURL: URL,
        source: CGImageSource,
        targetSize: Int64,
        originalWidth: Int,
        originalHeight: Int,
        originalFPS: Int,
        options: CompressionOptions
    ) throws -> URL {
        // 策略：保持色彩，逐步降低 分辨率 → FPS → 色深
        let resolutionSteps = [1.0, 0.8, 0.6, 0.5, 0.4, 0.3]
        let fpsSteps = [originalFPS, max(15, originalFPS / 2), 10, 8, 5]
        let colorDepthSteps = [256, 128, 64]

        for colorDepth in colorDepthSteps {
            for scale in resolutionSteps {
                for fps in fpsSteps {
                    let testOptions = CompressionOptions(
                        resizeMode: scale == 1.0
                            ? .none
                            : .longEdge(
                                pixels: Int(Double(max(originalWidth, originalHeight)) * scale)),
                        quality: options.quality,
                        deleteOriginal: false,
                        autoCompressTo5MB: false,
                        targetFormat: nil,
                        gifFrameRate: fps,
                        gifColorDepth: colorDepth
                    )

                    let tempURL = try testCompressGIF(inputURL: inputURL, options: testOptions)
                    let fileSize = getFileSize(url: tempURL) ?? 0

                    print(
                        "🔍 测试: \(colorDepth)色, 分辨率×\(Int(scale*100))%, \(fps)fps → \(fileSize/1024)KB"
                    )

                    if fileSize <= targetSize && fileSize > 0 {
                        try? FileManager.default.removeItem(at: tempURL)

                        var finalOptions = testOptions
                        finalOptions.deleteOriginal = options.deleteOriginal

                        print("✅ 最佳参数: \(colorDepth)色, 分辨率×\(Int(scale*100))%, \(fps)fps")
                        return try resizeImage(
                            inputURL: inputURL, resizeMode: finalOptions.resizeMode, isGIF: true,
                            deleteOriginal: options.deleteOriginal, options: finalOptions)
                    }

                    try? FileManager.default.removeItem(at: tempURL)
                }
            }
        }

        // 后备方案
        let fallbackOptions = CompressionOptions(
            resizeMode: .longEdge(pixels: Int(Double(max(originalWidth, originalHeight)) * 0.3)),
            quality: 0.9,
            deleteOriginal: options.deleteOriginal,
            autoCompressTo5MB: false,
            targetFormat: nil,
            gifFrameRate: 5,
            gifColorDepth: 32
        )
        print("⚠️ 使用极限压缩参数")
        return try resizeImage(
            inputURL: inputURL, resizeMode: fallbackOptions.resizeMode, isGIF: true,
            deleteOriginal: options.deleteOriginal, options: fallbackOptions)
    }

    /// 测试压缩 GIF（生成临时文件）
    nonisolated private static func testCompressGIF(inputURL: URL, options: CompressionOptions) throws -> URL {
        let tempFolder = FileManager.default.temporaryDirectory
        let tempURL = tempFolder.appendingPathComponent("test_\(UUID().uuidString).gif")

        var testOptions = options
        testOptions.deleteOriginal = false

        // 创建临时副本
        try FileManager.default.copyItem(at: inputURL, to: tempURL)

        // 压缩
        let compressedURL = try resizeImage(
            inputURL: tempURL, resizeMode: options.resizeMode, isGIF: true, deleteOriginal: true,
            options: testOptions)

        return compressedURL
    }
}
