//
//  ImageCompressorTypes.swift
//  LiquidConvert
//
//  Created by Shawn Rain.
//

import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Types

/// Image resize mode - explicitly Sendable and nonisolated Equatable
enum ImageResizeMode: Sendable {
    case none
    case longEdge(pixels: Int)
    case shortEdge(pixels: Int)
    case to720p
    case to1080p
    case scale50
    case scale30
    case custom(width: Int, height: Int)
}

// Explicit nonisolated Equatable conformance to avoid MainActor isolation
extension ImageResizeMode: Equatable {
    nonisolated static func == (lhs: ImageResizeMode, rhs: ImageResizeMode) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none): return true
        case (.to720p, .to720p): return true
        case (.to1080p, .to1080p): return true
        case (.scale50, .scale50): return true
        case (.scale30, .scale30): return true
        case (.longEdge(let l), .longEdge(let r)): return l == r
        case (.shortEdge(let l), .shortEdge(let r)): return l == r
        case (.custom(let lw, let lh), .custom(let rw, let rh)): return lw == rw && lh == rh
        default: return false
        }
    }
}

/// GIF compression priority - explicitly Sendable and nonisolated Equatable
enum GIFCompressionPriority: Sendable {
    case balanced
    case resolution
    case quality
    case size
}

extension GIFCompressionPriority: Equatable {
    nonisolated static func == (lhs: GIFCompressionPriority, rhs: GIFCompressionPriority) -> Bool {
        switch (lhs, rhs) {
        case (.balanced, .balanced): return true
        case (.resolution, .resolution): return true
        case (.quality, .quality): return true
        case (.size, .size): return true
        default: return false
        }
    }
}

/// Compression options struct
struct ImageCompressionOptions: Sendable {
    var resizeMode: ImageResizeMode = .none
    var quality: Double = 0.8
    var deleteOriginal: Bool = false
    var autoCompressTo5MB: Bool = false
    var targetFormat: UTType? = nil
    var gifFrameRate: Int? = nil
    var gifColorDepth: Int? = nil
    var gifCompressionPriority: GIFCompressionPriority? = nil
}
