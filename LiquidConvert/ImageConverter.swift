//
//  ImageConverter.swift
//  LiquidConvert
//
//  Created by Shawn Rain.
//

import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ImageConverter {

    enum TargetFormat: String, CaseIterable, Sendable {
        case jpeg = "JPG"
        case png = "PNG"
        case heic = "HEIC"
        case webp = "WEBP"
        case tiff = "TIFF"

        nonisolated var utType: UTType {
            switch self {
            case .jpeg: return .jpeg
            case .png: return .png
            case .heic: return .heic
            case .webp: return .webP
            case .tiff: return .tiff
            }
        }

        // 🔥 强制使用 .jpg 而不是 .jpeg
        nonisolated var fileExtension: String {
            switch self {
            case .jpeg: return "jpg"
            case .png: return "png"
            case .heic: return "heic"
            case .webp: return "webp"
            case .tiff: return "tiff"
            }
        }
    }

    static func convert(
        inputURL: URL, to format: TargetFormat, quality: Double = 0.9,
        autoCompressTo5MB: Bool = false
    ) throws -> URL {
        let rasterImage = try ImageSourceSupport.loadRasterImage(
            from: inputURL, errorDomain: "ImageConverter")
        var destProperties = rasterImage.properties

        // 2. 构造干净的输出路径 (移除时间戳)
        let originalFolder = inputURL.deletingLastPathComponent()
        let baseFileName = inputURL.deletingPathExtension().lastPathComponent

        // 使用智能去重命名逻辑 - 🔥 使用自定义 fileExtension 确保 jpg 而非 jpeg
        let outputURL = getUniqueFileURL(
            folder: originalFolder, fileName: baseFileName,
            extension: format.fileExtension)

        // 3. 如果启用自动压缩到5MB，使用二分查找算法调整质量
        if autoCompressTo5MB {
            let targetSizeBytes: Int64 = 5 * 1024 * 1024  // 5MB
            let finalQuality = try findOptimalQuality(
                rasterImage: rasterImage,
                format: format,
                targetSize: targetSizeBytes,
                properties: rasterImage.properties
            )
            destProperties[kCGImageDestinationLossyCompressionQuality] = finalQuality
        } else {
            // 使用用户指定的质量
            destProperties[kCGImageDestinationLossyCompressionQuality] = quality
        }

        guard
            let destination = CGImageDestinationCreateWithURL(
                outputURL as CFURL, format.utType.identifier as CFString, 1, nil)
        else {
            throw NSError(
                domain: "ImageConverter", code: -2,
                userInfo: [NSLocalizedDescriptionKey: "无法创建输出文件"])
        }

        // 4. 执行写入，带上元数据
        addImage(rasterImage, to: destination, properties: destProperties)

        if CGImageDestinationFinalize(destination) {
            return outputURL
        } else {
            throw NSError(
                domain: "ImageConverter", code: -3, userInfo: [NSLocalizedDescriptionKey: "写入文件失败"])
        }
    }

    /// 获取文件大小（字节）
    private static func getFileSize(url: URL) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = attrs[.size] as? Int64
        else {
            return nil
        }
        return size
    }

    /// 使用二分查找算法找到满足目标文件大小的最佳质量参数
    private static func findOptimalQuality(
        rasterImage: ImageSourceSupport.RasterImage,
        format: TargetFormat,
        targetSize: Int64,
        properties: [CFString: Any]
    ) throws -> Double {
        var minQuality = 0.1
        var maxQuality = 0.95
        var bestQuality = maxQuality
        let maxIterations = 10

        // 创建临时文件用于测试
        let tempFolder = FileManager.default.temporaryDirectory
        let tempURL = tempFolder.appendingPathComponent(
            "temp_compress_test.\(format.fileExtension)")

        defer {
            // 清理临时文件
            try? FileManager.default.removeItem(at: tempURL)
        }

        for iteration in 0..<maxIterations {
            let testQuality = (minQuality + maxQuality) / 2.0
            var testProperties = properties
            testProperties[kCGImageDestinationLossyCompressionQuality] = testQuality

            // 移除已存在的临时文件
            try? FileManager.default.removeItem(at: tempURL)

            // 创建临时输出
            guard
                let destination = CGImageDestinationCreateWithURL(
                    tempURL as CFURL, format.utType.identifier as CFString, 1, nil
                )
            else {
                throw NSError(
                    domain: "ImageConverter", code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "无法创建临时文件"])
            }

            addImage(rasterImage, to: destination, properties: testProperties)

            guard CGImageDestinationFinalize(destination) else {
                throw NSError(
                    domain: "ImageConverter", code: -3,
                    userInfo: [NSLocalizedDescriptionKey: "写入临时文件失败"])
            }

            guard let fileSize = getFileSize(url: tempURL) else {
                throw NSError(
                    domain: "ImageConverter", code: -4,
                    userInfo: [NSLocalizedDescriptionKey: "无法获取文件大小"])
            }

            print(
                "🔍 压缩测试 [\(iteration + 1)/\(maxIterations)]: 质量=\(Int(testQuality * 100))%, 大小=\(fileSize / 1024)KB, 目标=\(targetSize / 1024)KB"
            )

            if fileSize <= targetSize {
                // 文件小于等于目标大小，尝试提高质量
                bestQuality = testQuality
                minQuality = testQuality

                // 如果已经足够接近，可以提前结束
                if fileSize > targetSize * 9 / 10 {  // 如果大于目标的90%，认为足够好
                    break
                }
            } else {
                // 文件过大，降低质量
                maxQuality = testQuality
            }

            // 如果质量范围已经很小，提前结束
            if maxQuality - minQuality < 0.01 {
                break
            }
        }

        print("✅ 最终压缩质量: \(Int(bestQuality * 100))%")
        return bestQuality
    }

    private static func addImage(
        _ rasterImage: ImageSourceSupport.RasterImage,
        to destination: CGImageDestination,
        properties: [CFString: Any]
    ) {
        if let source = rasterImage.source {
            CGImageDestinationAddImageFromSource(destination, source, 0, properties as CFDictionary)
        } else {
            CGImageDestinationAddImage(destination, rasterImage.image, properties as CFDictionary)
        }
    }

    /// 辅助方法：生成不重复的文件路径
    /// 逻辑：如果 Target.jpg 存在，则尝试 Target 1.jpg, Target 2.jpg...
    private static func getUniqueFileURL(folder: URL, fileName: String, extension ext: String)
        -> URL
    {
        let fileManager = FileManager.default
        var destination = folder.appendingPathComponent("\(fileName).\(ext)")
        var counter = 1

        while fileManager.fileExists(atPath: destination.path) {
            destination = folder.appendingPathComponent("\(fileName) \(counter).\(ext)")
            counter += 1
        }

        return destination
    }

    /// 🔥 Dock 图标拖拽时的静默转换方法
    /// 转换为 JPG 格式，自动压缩到 5MB 以内，并删除源文件
    /// 不进行尺寸调整，保持原始分辨率
    static func convertSilently(imageURLs: [URL]) async {
        var successCount = 0
        var failCount = 0

        for url in imageURLs {
            do {
                let rasterImage = try ImageSourceSupport.loadRasterImage(
                    from: url, errorDomain: "ImageConverter")
                let srcProperties = rasterImage.properties

                let originalExtension = url.pathExtension.lowercased()
                let isAlreadyJPG = (originalExtension == "jpg" || originalExtension == "jpeg")

                let outputURL: URL
                if isAlreadyJPG {
                    // 原文件是JPG，使用临时文件名，稍后会替换原文件
                    outputURL = url.deletingLastPathComponent().appendingPathComponent(
                        "\(url.deletingPathExtension().lastPathComponent)_temp.jpg"
                    )
                } else {
                    // 🔥 修复：使用 getUniqueFileURL 避免覆盖已有同名文件
                    let originalFolder = url.deletingLastPathComponent()
                    let baseFileName = url.deletingPathExtension().lastPathComponent
                    outputURL = getUniqueFileURL(
                        folder: originalFolder, fileName: baseFileName, extension: "jpg")
                }

                let fileSize = getFileSize(url: url) ?? 0
                let targetSizeBytes: Int64 = 5 * 1024 * 1024  // 5MB

                // 🔥 智能判断：如果已经是 JPG 且小于 5MB，直接跳过处理，杜绝变大
                if isAlreadyJPG && fileSize <= targetSizeBytes {
                    successCount += 1
                    print("⏭️ 跳过处理: \(url.lastPathComponent) (已是 JPG 且 <5MB)")
                    continue
                }

                let finalQuality: Double
                if fileSize < targetSizeBytes {
                    // 文件已小于 5MB，使用高质量（0.95）仅转格式，不压缩
                    finalQuality = 0.95
                    print("✓ 文件已 <5MB (\(fileSize/1024)KB)，使用高质量仅转格式")
                } else {
                    // 文件 >=5MB，使用二分查找算法找到最佳压缩质量（≤5MB）
                    print("⚙️ 文件 ≥5MB (\(fileSize/1024)KB)，启动智能压缩")
                    finalQuality = try findOptimalQuality(
                        rasterImage: rasterImage,
                        format: .jpeg,
                        targetSize: targetSizeBytes,
                        properties: srcProperties
                    )
                }

                var destProperties = srcProperties
                destProperties[kCGImageDestinationLossyCompressionQuality] = finalQuality

                // 创建 JPEG 输出
                guard
                    let destination = CGImageDestinationCreateWithURL(
                        outputURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
                else {
                    throw NSError(
                        domain: "ImageConverter", code: -2,
                        userInfo: [NSLocalizedDescriptionKey: "无法创建输出文件"])
                }

                // 写入图片（普通位图直接从源添加，SVG 使用已栅格化图像）
                addImage(rasterImage, to: destination, properties: destProperties)

                guard CGImageDestinationFinalize(destination) else {
                    throw NSError(
                        domain: "ImageConverter", code: -3,
                        userInfo: [NSLocalizedDescriptionKey: "写入文件失败"])
                }

                // 🔥 转换已成功，先计数
                successCount += 1

                // 🔥 后续处理：删除/替换源文件（失败不影响成功计数）
                if isAlreadyJPG {
                    // 原文件是JPG：删除原文件，临时文件重命名为原文件名
                    do {
                        try FileSafeHandler.safeTrashItem(at: url)
                        try FileSafeHandler.safeMoveItem(at: outputURL, to: url)
                        print("✅ 已替换原JPG: \(url.lastPathComponent) (自动压缩至 ≤5MB)")
                    } catch {
                        print("⚠️ 替换原JPG失败，保留临时文件: \(error.localizedDescription)")
                    }
                } else {
                    // 原文件不是JPG：删除源文件，保留新生成的.jpg
                    do {
                        try FileSafeHandler.safeTrashItem(at: url)
                        print("✅ 已转换并删除: \(url.lastPathComponent) -> \(outputURL.lastPathComponent)")
                    } catch {
                        // 废纸篓失败，尝试直接删除
                        print("⚠️ 废纸篓失败，尝试直接删除: \(error.localizedDescription)")
                        do {
                            try FileManager.default.removeItem(at: url)
                            print("✅ 已直接删除源文件: \(url.lastPathComponent)")
                        } catch {
                            print("⚠️ 直接删除也失败: \(error.localizedDescription)")
                        }
                    }
                }
            } catch {
                failCount += 1
                print("❌ 转换失败: \(url.lastPathComponent) - \(error.localizedDescription)")
            }
        }

        // 发送通知
        await MainActor.run {
            let title = "图片转换完成"
            let subtitle: String
            if failCount == 0 {
                subtitle = "已成功处理 \(successCount) 个文件"
            } else {
                subtitle = "成功 \(successCount) 个，失败 \(failCount) 个"
            }
            NotificationManager.send(title: title, subtitle: subtitle)
            NSSound(named: "Glass")?.play()
        }
    }
}
