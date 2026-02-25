//
//  VideoGifConverter.swift
//  LiquidConvert
//
//  Created by Shawn Rain.
//

import AVFoundation
import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct VideoGifConverter {

    enum TargetFormat: String, CaseIterable {
        case gif = "GIF"
        case mp4 = "MP4"
        case mov = "MOV"

        var extensionName: String {
            switch self {
            case .gif: return "gif"
            case .mp4: return "mp4"
            case .mov: return "mov"
            }
        }
    }

    // 🔥 修改：配置参数结构体
    struct Config {
        var format: TargetFormat
        var fps: Int
        var targetWidth: Int  // 🔥 改为具体宽度 (如 640)
        var speed: Double  // 0.5x ~ 2.0x
        var reverse: Bool  // 是否倒放
        var quality: Double  // 0.0 ~ 1.0 (色彩品质)
        var trimRange: ClosedRange<Double>? // 🔥 新增：剪辑范围 (秒)
    }

    // 统一入口
    static func convert(inputURL: URL, config: Config) async throws -> URL {
        let inputExt = inputURL.pathExtension.lowercased()
        let isInputVideo = ["mp4", "mov", "m4v", "avi", "mkv", "ts"].contains(inputExt)
        let isInputGif = inputExt == "gif"

        let outputURL = getUniqueFileURL(
            folder: inputURL.deletingLastPathComponent(),
            fileName: inputURL.deletingPathExtension().lastPathComponent,
            extension: config.format.extensionName)

        if config.format == .gif && isInputVideo {
            try await convertVideoToGif(
                videoURL: inputURL, destinationURL: outputURL, config: config)
        } else if (config.format == .mp4 || config.format == .mov) && isInputGif {
            try await convertGifToVideo(
                gifURL: inputURL, destinationURL: outputURL, format: config.format)
        } else if isInputVideo && (config.format == .mp4 || config.format == .mov) {
            throw NSError(
                domain: "VideoGifConverter", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "暂不支持视频格式间转换，请选择 GIF 作为目标。"])
        } else {
            throw NSError(
                domain: "VideoGifConverter", code: -2,
                userInfo: [NSLocalizedDescriptionKey: "不支持的转换组合"])
        }

        return outputURL
    }

    // MARK: - Video to GIF (增强版)
    private static func convertVideoToGif(videoURL: URL, destinationURL: URL, config: Config)
        async throws
    {
        let asset = AVURLAsset(url: videoURL)  // 🔥 修复 macOS 15 警告
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        // 1. 设置具体分辨率 (Resolution)
        // maximumSize 设置为 (width, width) 会自动保持原视频宽高比，限制最长边不超过 width
        // 如果设置为 (width, 0) 则无效，必须给高度一个值。这里给 width 即可让系统自适应。
        let pixelWidth = CGFloat(config.targetWidth)
        generator.maximumSize = CGSize(width: pixelWidth, height: pixelWidth)

        // 2. 计算帧与时间
        let assetDuration = try await asset.load(.duration).seconds
        let startTime = config.trimRange?.lowerBound ?? 0
        let endTime = config.trimRange?.upperBound ?? assetDuration
        let trimDuration = endTime - startTime
        
        let totalFrames = Int(trimDuration * Double(config.fps))
        let frameDelay = (1.0 / Double(config.fps)) / config.speed

        // 3. 生成时间点
        var times: [CMTime] = []
        let captureInterval = 1.0 / Double(config.fps)
        for i in 0..<totalFrames {
            let seconds = startTime + (Double(i) * captureInterval)
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            times.append(time)
        }

        // 4. 提取帧
        var extractedImages: [CGImage] = []
        for await imageResult in generator.images(for: times) {
            switch imageResult {
            case .success(requestedTime: _, image: let cgImage, actualTime: _):
                extractedImages.append(cgImage)
            case .failure: break
            }
        }

        // 5. 处理倒放
        if config.reverse {
            extractedImages.reverse()
        }

        // 6. 写入 GIF
        guard
            let destination = CGImageDestinationCreateWithURL(
                destinationURL as CFURL, UTType.gif.identifier as CFString, extractedImages.count,
                nil)
        else {
            throw NSError(
                domain: "VideoGifConverter", code: -3,
                userInfo: [NSLocalizedDescriptionKey: "无法创建 GIF 输出目标"])
        }

        let fileProperties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]]
        CGImageDestinationSetProperties(destination, fileProperties as CFDictionary)

        // 应用色彩品质 (压缩质量)
        let frameProperties: [String: Any] = [
            kCGImagePropertyGIFDictionary as String: [
                kCGImagePropertyGIFDelayTime: frameDelay
            ],
            kCGImageDestinationLossyCompressionQuality as String: config.quality,  // 🔥 对应色彩品质
        ]

        for image in extractedImages {
            CGImageDestinationAddImage(destination, image, frameProperties as CFDictionary)
        }

        if !CGImageDestinationFinalize(destination) {
            throw NSError(
                domain: "VideoGifConverter", code: -4,
                userInfo: [NSLocalizedDescriptionKey: "GIF 生成失败"])
        }
    }

    // MARK: - GIF to Video (保持不变)
    private static func convertGifToVideo(gifURL: URL, destinationURL: URL, format: TargetFormat)
        async throws
    {
        guard let source = CGImageSourceCreateWithURL(gifURL as CFURL, nil) else {
            throw NSError(
                domain: "VideoGifConverter", code: -5,
                userInfo: [NSLocalizedDescriptionKey: "无法读取 GIF"])
        }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else {
            throw NSError(
                domain: "VideoGifConverter", code: -6,
                userInfo: [NSLocalizedDescriptionKey: "GIF 是空的"])
        }

        guard let firstImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
        let width = firstImage.width
        let height = firstImage.height
        let size = CGSize(width: width, height: height)

        let writer = try AVAssetWriter(
            outputURL: destinationURL, fileType: format == .mov ? .mov : .mp4)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        writerInput.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32ARGB),
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])

        if writer.canAdd(writerInput) { writer.add(writerInput) }
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        var currentTime = CMTime.zero
        for i in 0..<count {
            while !writerInput.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            if let cgImage = CGImageSourceCreateImageAtIndex(source, i, nil) {
                let properties =
                    CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [String: Any]
                let gifProperties =
                    properties?[kCGImagePropertyGIFDictionary as String] as? [String: Any]
                let delayTime =
                    gifProperties?[kCGImagePropertyGIFUnclampedDelayTime as String] as? Double
                    ?? gifProperties?[kCGImagePropertyGIFDelayTime as String] as? Double
                    ?? 0.1
                if let buffer = pixelBufferFromCGImage(image: cgImage, size: size) {
                    adaptor.append(buffer, withPresentationTime: currentTime)
                }
                currentTime = CMTimeAdd(
                    currentTime, CMTime(seconds: delayTime, preferredTimescale: 600))
            }
        }
        writerInput.markAsFinished()
        await writer.finishWriting()
    }

    private static func pixelBufferFromCGImage(image: CGImage, size: CGSize) -> CVPixelBuffer? {
        var pxBuffer: CVPixelBuffer?
        let options: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        CVPixelBufferCreate(
            kCFAllocatorDefault, Int(size.width), Int(size.height), kCVPixelFormatType_32ARGB,
            options as CFDictionary, &pxBuffer)
        guard let buffer = pxBuffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        let pxData = CVPixelBufferGetBaseAddress(buffer)
        let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: pxData, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: rgbColorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)
        context?.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

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
}
