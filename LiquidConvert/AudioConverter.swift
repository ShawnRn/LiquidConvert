//
//  AudioConverter.swift
//  LiquidConvert
//
//  Created by Shawn Rain.
//

import Foundation

struct AudioConverter {

    enum Format: String, CaseIterable {
        case aac = "AAC (M4A)"
        case alac = "ALAC (Apple无损)"
        case flac = "FLAC (无损)"
        case wav = "WAV (通用无损)"
        case mp3 = "MP3"

        var fileExtension: String {
            switch self {
            case .aac, .alac: return "m4a"
            case .flac: return "flac"
            case .wav: return "wav"
            case .mp3: return "mp3"
            }
        }

        var arguments: [String] {
            switch self {
            case .aac: return ["-f", "m4af", "-d", "aac", "-b", "320000", "-q", "127"]
            case .alac: return ["-f", "m4af", "-d", "alac"]
            case .flac: return ["-f", "flac", "-d", "flac"]
            case .wav: return ["-f", "WAVE", "-d", "LEI16"]
            case .mp3: return ["-f", "MPG3", "-d", ".mp3", "-b", "320000"]
            }
        }
    }

    static func convert(inputURL: URL, to format: Format) async throws -> URL {
        let ext = inputURL.pathExtension.lowercased()
        let fileManager = FileManager.default
        var sourceURL = inputURL
        var outputBaseName = inputURL.deletingPathExtension().lastPathComponent
        
        // 临时文件清理列表
        var cleanupURLs: [URL] = []
        defer {
            for url in cleanupURLs { try? fileManager.removeItem(at: url) }
        }

        // 1. 视频提取音频
        let videoExtensions = ["mp4", "mov", "m4v", "avi", "mkv", "ts", "webm"]
        if videoExtensions.contains(ext) {
            let tempAudio = fileManager.temporaryDirectory.appendingPathComponent("video_audio_\(UUID().uuidString).m4a")
            try runExtractAudio(videoURL: inputURL, outputURL: tempAudio)
            sourceURL = tempAudio
            cleanupURLs.append(tempAudio)
        }

        // 2. NCM 解密
        if ext == "ncm" {
            let (data, rawExt, suggestedName) = try NcmDecryptor.decrypt(ncmURL: inputURL)
            let tempNcm = fileManager.temporaryDirectory.appendingPathComponent("ncm_temp_\(UUID().uuidString).\(rawExt)")
            try data.write(to: tempNcm)
            sourceURL = tempNcm
            cleanupURLs.append(tempNcm)
            if let name = suggestedName, !name.isEmpty { outputBaseName = name }
        }

        // 3. 最终转换
        let outputURL = getUniqueFileURL(folder: inputURL.deletingLastPathComponent(), fileName: outputBaseName, extension: format.fileExtension)
        
        // 智能直通 (Smart Passthrough)
        if sourceURL.pathExtension.lowercased() == format.fileExtension.lowercased() {
            try fileManager.copyItem(at: sourceURL, to: outputURL)
        } else {
            // afconvert 转换
            try runAfconvert(input: sourceURL, output: outputURL, format: format)
        }

        return outputURL
    }

    // MARK: - 进程执行核心 (修复 Pipe 死锁)
    
    /// 安全运行命令，防止 Pipe 缓冲区填满导致死锁
    private static func runCommand(executable: URL, args: [String]) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = args
        
        // 设置 Pipe 读取错误信息
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe // 合并输出，防止 stdout 填满卡死
        
        try process.run()
        
        // 🔥 修复死锁的关键：在 waitUntilExit 之前读取数据！
        // 如果不读，进程写满 64KB 缓冲区后就会挂起等待读取，导致 waitUntilExit 永远不返回
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        
        process.waitUntilExit()
        
        if process.terminationStatus != 0 {
            let output = String(data: data, encoding: .utf8) ?? "未知错误"
            throw NSError(domain: "AudioConverter", code: Int(process.terminationStatus), 
                          userInfo: [NSLocalizedDescriptionKey: "命令执行失败: \(output)"])
        }
    }

    private static func runAfconvert(input: URL, output: URL, format: Format) throws {
        var args = format.arguments
        args.append(input.path)
        args.append(output.path)
        try runCommand(executable: URL(fileURLWithPath: "/usr/bin/afconvert"), args: args)
    }

    private static func runExtractAudio(videoURL: URL, outputURL: URL) throws {
        // 寻找 ffmpeg
        let possiblePaths = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        guard let ffmpegPath = possiblePaths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            throw NSError(domain: "AudioConverter", code: 404, userInfo: [NSLocalizedDescriptionKey: "未找到 ffmpeg，请先安装: brew install ffmpeg"])
        }
        
        // 尝试 Copy 模式
        do {
            try runCommand(executable: URL(fileURLWithPath: ffmpegPath), args: [
                "-i", videoURL.path, "-vn", "-acodec", "copy", "-y", outputURL.path
            ])
        } catch {
            // Copy 失败则尝试重编码
            try runCommand(executable: URL(fileURLWithPath: ffmpegPath), args: [
                "-i", videoURL.path, "-vn", "-acodec", "aac", "-b:a", "320k", "-y", outputURL.path
            ])
        }
    }
    
    private static func getUniqueFileURL(folder: URL, fileName: String, extension ext: String) -> URL {
        var dest = folder.appendingPathComponent("\(fileName).\(ext)")
        var counter = 1
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = folder.appendingPathComponent("\(fileName) (\(counter)).\(ext)")
            counter += 1
        }
        return dest
    }
}
