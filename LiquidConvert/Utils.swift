//
//  Utils.swift
//  LiquidConvert
//
//  Created by Shawn Rain.
//

import Foundation
import CommonCrypto
import UserNotifications
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 统一缩略图缓存 (NSCache 版)
final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()
    
    private init() {
        cache.countLimit = 500 // 限制缓存数量
        cache.totalCostLimit = 128 * 1024 * 1024 // 额外限制总内存 (128MB)
    }
    
    func image(for url: URL, size: CGFloat) -> NSImage? {
        let key = "\(url.path)_\(Int(size))" as NSString
        return cache.object(forKey: key)
    }
    
    func insert(_ image: NSImage, for url: URL, size: CGFloat) {
        let key = "\(url.path)_\(Int(size))" as NSString
        cache.setObject(image, forKey: key)
    }
}

// MARK: - 通知管理器
struct NotificationManager {
    static func send(title: String, subtitle: String = "") {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = subtitle
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

// MARK: - 文件扫描器 (无锁版)
struct FileScanner {
    // 递归扫描文件夹，过滤后缀
    nonisolated static func scan(urls: [URL], allowedExtensions: [String]) -> [URL] {
        var result: [URL] = []
        let fileManager = FileManager.default
        let options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
        let allowed = Set(allowedExtensions.map { $0.lowercased() })
        
        for url in urls {
            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: url.path, isDirectory: &isDir) {
                if isDir.boolValue {
                    if let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: nil, options: options) {
                        for case let fileURL as URL in enumerator {
                            if allowed.contains(fileURL.pathExtension.lowercased()) {
                                result.append(fileURL)
                            }
                        }
                    }
                } else {
                    if allowed.contains(url.pathExtension.lowercased()) {
                        result.append(url)
                    }
                }
            }
        }
        return result
    }
}

// MARK: - NCM 解密器 (优化版)
struct NcmDecryptor {

    nonisolated static func decrypt(ncmURL: URL) throws -> (Data, String, String?) {
        // Local key for metadata decryption (avoids actor isolation issues)
        let ncmMetaKey: [UInt8] = [
            0x23, 0x31, 0x34, 0x6C, 0x6A, 0x6B, 0x5F, 0x21,
            0x5C, 0x5D, 0x26, 0x30, 0x55, 0x3C, 0x27, 0x28
        ]

        // 使用 mappedIfSafe 避免一次性加载大文件进内存
        let fileData = try Data(contentsOf: ncmURL, options: .mappedIfSafe)
        let totalSize = fileData.count
        
        guard totalSize > 14,
              fileData[0...7].elementsEqual([0x43, 0x54, 0x45, 0x4e, 0x46, 0x44, 0x41, 0x4d]) else {
            throw NSError(domain: "NcmDecryptor", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效的 NCM 文件"])
        }
        
        var offset = 10
        let keyLen = Int(fileData.getUInt32Safe(at: offset))
        offset += 4
        
        guard offset + keyLen < totalSize else {
            throw NSError(domain: "NcmDecryptor", code: -2, userInfo: [NSLocalizedDescriptionKey: "NCM 文件损坏"])
        }
        
        let keyDataCrypted = fileData.subdata(in: offset..<(offset + keyLen)).map { $0 ^ 0x64 }
        offset += keyLen
        
        guard let keyBox = generateKeyBox(cipherBytes: keyDataCrypted) else {
            throw NSError(domain: "NcmDecryptor", code: -3, userInfo: [NSLocalizedDescriptionKey: "Key 解密失败"])
        }
        
        guard offset + 4 < totalSize else { throw NSError(domain: "NcmDecryptor", code: -4, userInfo: [NSLocalizedDescriptionKey: "文件截断"]) }
        let metaLen = Int(fileData.getUInt32Safe(at: offset))
        offset += 4
        
        var suggestedFilename: String? = nil
        if metaLen > 0 && offset + metaLen < totalSize {
            let metaBytes = fileData.subdata(in: offset..<(offset + metaLen)).map { $0 ^ 0x63 }
            // 简单的 JSON 提取逻辑
            if metaBytes.count > 22 {
                let base64Data = Data(metaBytes[22...])
                if let base64String = String(data: base64Data, encoding: .utf8),
                   let encryptedMeta = Data(base64Encoded: base64String),
                   let decryptedMetaBytes = aesDecrypt(data: encryptedMeta, key: Data(ncmMetaKey)),
                   let jsonStr = String(data: decryptedMetaBytes, encoding: .utf8)?.replacingOccurrences(of: "music:", with: "") {
                    
                    if let data = jsonStr.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        let name = json["musicName"] as? String ?? "Unknown"
                        var artist = "Unknown"
                        if let arr = json["artist"] as? [[Any]], let first = arr.first, first.count > 0 {
                            artist = first[0] as? String ?? "Unknown"
                        }
                        suggestedFilename = "\(artist) - \(name)"
                    }
                }
            }
        }
        offset += metaLen
        
        if offset + 9 <= totalSize {
            let crcAndGap = Int(fileData.getUInt32Safe(at: offset + 5))
            offset += (crcAndGap + 13)
        }
        
        guard offset < totalSize else {
            throw NSError(domain: "NcmDecryptor", code: -5, userInfo: [NSLocalizedDescriptionKey: "没有音频数据"])
        }
        
        let audioStart = offset
        // 极速 XOR 处理
        var audioData = fileData.subdata(in: audioStart..<totalSize)
        audioData.withUnsafeMutableBytes { (ptr: UnsafeMutableRawBufferPointer) in
            guard let base = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for i in 0..<ptr.count {
                base[i] ^= keyBox[i & 0xff]
            }
        }
        
        let format = audioData.prefix(4).map { Character(UnicodeScalar($0)) }.starts(with: "fLaC") ? "flac" : "mp3"
        return (audioData, format, suggestedFilename)
    }
    
    nonisolated private static func generateKeyBox(cipherBytes: [UInt8]) -> [UInt8]? {
        let ncmCoreKey: [UInt8] = [
            0x68, 0x7a, 0x48, 0x52, 0x41, 0x6d, 0x73, 0x6f,
            0x35, 0x6b, 0x49, 0x6e, 0x62, 0x61, 0x78, 0x57
        ]
        guard let plainKey = aesDecrypt(data: Data(cipherBytes), key: Data(ncmCoreKey)) else { return nil }
        let key = Array(plainKey[17...])
        let keyLen = key.count
        var box = Array(0...255).map { UInt8($0) }
        var j = 0
        for i in 0..<256 {
            j = (Int(box[i]) + j + Int(key[i % keyLen])) & 0xff
            box.swapAt(i, j)
        }
        var result = [UInt8](repeating: 0, count: 256)
        for i in 0..<256 {
            let i_plus_1 = (i + 1) & 0xff
            let si = Int(box[i_plus_1])
            let sj = Int(box[(i_plus_1 + si) & 0xff])
            result[i] = box[(si + sj) & 0xff]
        }
        return result
    }
    
    nonisolated private static func aesDecrypt(data: Data, key: Data) -> Data? {
        let keyLength = kCCKeySizeAES128
        let dataLength = data.count
        var buffer = Data(count: dataLength + kCCBlockSizeAES128)
        var numBytesDecrypted: size_t = 0
        let bufferCount = buffer.count // Capture before closure
        let cryptStatus = buffer.withUnsafeMutableBytes { bufferBytes in
            data.withUnsafeBytes { dataBytes in
                key.withUnsafeBytes { keyBytes in
                    CCCrypt(
                        CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode),
                        keyBytes.baseAddress, keyLength, nil,
                        dataBytes.baseAddress, dataLength,
                        bufferBytes.baseAddress, bufferCount,
                        &numBytesDecrypted
                    )
                }
            }
        }
        return cryptStatus == kCCSuccess ? buffer.prefix(numBytesDecrypted) : nil
    }
}

extension Data {
    nonisolated func getUInt32Safe(at offset: Int) -> UInt32 {
        guard offset + 4 <= self.count else { return 0 }
        return self.subdata(in: offset..<offset+4).withUnsafeBytes { $0.load(as: UInt32.self) }
    }
}

// MARK: - 🔥 核心修复：NSItemProvider 安全加载扩展
extension NSItemProvider {
    /// 终极无锁加载方案：直接获取 URL 引用，不进行数据转换
    func loadSafeURL() async -> URL? {
        let typeIdentifier = UTType.fileURL.identifier
        
        return await withCheckedContinuation { continuation in
            if self.hasItemConformingToTypeIdentifier(typeIdentifier) {
                // 使用 loadItem 而不是 loadObject 或 loadDataRepresentation
                // 这能拿到最原始的路径引用，绝对不会触发 Finder 死锁
                self.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, error in
                    if let url = item as? URL {
                        continuation.resume(returning: url)
                    } else if let url = item as? NSURL {
                        continuation.resume(returning: url as URL)
                    } else if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                        continuation.resume(returning: url)
                    } else {
                        continuation.resume(returning: nil)
                    }
                }
            } else if let fallbackType = self.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .data) == true }) {
                self.loadFileRepresentation(forTypeIdentifier: fallbackType) { url, error in
                    guard let url else {
                        continuation.resume(returning: nil)
                        return
                    }

                    let ext = UTType(fallbackType)?.preferredFilenameExtension ?? url.pathExtension
                    let filename = ext.isEmpty
                        ? "liquidconvert-drop-\(UUID().uuidString)"
                        : "liquidconvert-drop-\(UUID().uuidString).\(ext)"
                    let destination = FileManager.default.temporaryDirectory.appendingPathComponent(filename)

                    do {
                        if FileManager.default.fileExists(atPath: destination.path) {
                            try FileManager.default.removeItem(at: destination)
                        }
                        try FileManager.default.copyItem(at: url, to: destination)
                        continuation.resume(returning: destination)
                    } catch {
                        continuation.resume(returning: nil)
                    }
                }
            } else {
                continuation.resume(returning: nil)
            }
        }
    }
}

// MARK: - DropDelegate (标准化)
struct FileDropDelegate: DropDelegate {
    let action: @MainActor @Sendable ([URL]) -> Void
    var isTargeted: Binding<Bool>? = nil

    func validateDrop(info: DropInfo) -> Bool {
        return info.hasItemsConforming(to: [.fileURL])
    }

    func dropEntered(info: DropInfo) {
        Task { @MainActor in withAnimation { isTargeted?.wrappedValue = true } }
    }

    func dropExited(info: DropInfo) {
        Task { @MainActor in withAnimation { isTargeted?.wrappedValue = false } }
    }

    func performDrop(info: DropInfo) -> Bool {
        let providers = info.itemProviders(for: [.fileURL])
        Task { @MainActor in withAnimation { isTargeted?.wrappedValue = false } }

        // 🔥 必须使用 detached，彻底隔离主线程
        Task.detached(priority: .userInitiated) {
            var urls: [URL] = []
            for provider in providers {
                // 调用上面的 loadSafeURL
                if let url = await provider.loadSafeURL() {
                    urls.append(url)
                }
            }
            if !urls.isEmpty {
                await action(urls)
            }
        }
        return true
    }
}

// MARK: - 🔥 安全文件处理器 (针对 iCloud/同步盘优化)
struct FileSafeHandler {
    /// 安全地移动文件到废纸篓，带协调器和重试机制
    static func safeTrashItem(at url: URL) throws {
        let fileManager = FileManager.default
        var lastError: Error?
        
        // 最多重试 3 次，每次间隔增加
        for attempt in 1...3 {
            do {
                let coordinator = NSFileCoordinator()
                var coordinatorError: NSError?
                var internalError: Error?
                
                coordinator.coordinate(writingItemAt: url, options: .forDeleting, error: &coordinatorError) { newURL in
                    do {
                        try fileManager.trashItem(at: newURL, resultingItemURL: nil)
                    } catch {
                        internalError = error
                    }
                }
                
                if let error = internalError ?? coordinatorError {
                    throw error
                }
                
                if attempt > 1 { print("✅ [重试成功] 文件已移至废纸篓: \(url.lastPathComponent) (第 \(attempt) 次尝试)") }
                return
            } catch {
                lastError = error
                print("⚠️ [删除失败] \(url.lastPathComponent) - 尝试 \(attempt)/3: \(error.localizedDescription)")
                
                if attempt < 3 {
                    // 递增延迟: 0.2s, 0.5s
                    Thread.sleep(forTimeInterval: attempt == 1 ? 0.2 : 0.5)
                }
            }
        }
        
        if let error = lastError {
            throw error
        }
    }
    
    /// 安全地移动文件，带协调器
    static func safeMoveItem(at src: URL, to dst: URL) throws {
        let coordinator = NSFileCoordinator()
        var coordinatorError: NSError?
        var moveError: Error?
        
        coordinator.coordinate(writingItemAt: src, options: .forMoving, writingItemAt: dst, options: .forReplacing, error: &coordinatorError) { newSrc, newDst in
            do {
                if FileManager.default.fileExists(atPath: newDst.path) {
                    try FileManager.default.removeItem(at: newDst)
                }
                try FileManager.default.moveItem(at: newSrc, to: newDst)
            } catch {
                moveError = error
            }
        }
        
        if let error = moveError ?? coordinatorError {
            throw error
        }
    }
}
