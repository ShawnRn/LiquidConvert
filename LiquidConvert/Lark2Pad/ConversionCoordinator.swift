//
//  ConversionCoordinator.swift
//  LiquidConvert
//
//  Orchestrates the full pipeline: clipboard HTML → image fetch → Turndown → result.
//

import Foundation
import Combine

/// Observable coordinator that drives the conversion pipeline and exposes state for SwiftUI.
@MainActor
final class ConversionCoordinator: ObservableObject {

    // MARK: - Published State

    enum Phase: Equatable {
        case idle
        case processing
        case rendering // Waiting for WebView to finish painting
        case done
        case error(message: String)
    }

    @Published var phase: Phase = .idle
    @Published var statusMessage: String = ""
    @Published var markdownResult: String = ""
    @Published var etherpadHTML: String = "" // Raw version for export
    @Published var previewHTML: String = ""   // Rendered version for preview
    @Published var isLoggedIntoEtherpad: Bool = false
    
    // 进度跟踪
    @Published var uploadProgress: Double = 0 // 0.0 - 1.0 整体进度
    @Published var speedMessage: String = ""  // 实时网速文本

    // MARK: - Engine
    
    private let engine = TurndownEngine()
    private var engineReady = false

    init() {
        checkLoginStatus()
    }

    func checkLoginStatus() {
        isLoggedIntoEtherpad = CookieManager.shared.hasValidSession
    }

    // MARK: - Public API

    /// Warm up the Turndown engine (call once at app launch).
    func prepareEngine() async {
        await engine.prepare()
        engineReady = true
    }

    /// Run the full conversion pipeline on pasted HTML.
    func convert(html: String, autoUpload: Bool) async {
        if !engineReady {
            statusMessage = "引擎正在准备中，请稍候…"
            phase = .processing
            // Wait for engine to be ready if not already (max 4 seconds)
            for _ in 0..<40 {
                if engineReady { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        
        guard engineReady else {
            phase = .error(message: "引擎准备超时，请重载应用。")
            return
        }

        statusMessage = "正在解析 HTML 结构…"
        phase = .processing

        do {
            // Step 1: Parse HTML and extract image URLs
            let images = try await engine.loadHTMLAndGetImageURLs(html)

            // Step 2: 自动搬家图片至私有图床 (如果开启了自动上传)
            var replacements: [(id: Int, base64: String)] = []
            if autoUpload && !images.isEmpty {
                statusMessage = "正在准备上传 \(images.count) 张图片..."
                uploadProgress = 0
                speedMessage = ""
                
                // 使用 try-catch 捕获上传过程中的任何严重错误
                do {
                    replacements = try await ImageUploader.uploadAll(images: images) { [weak self] index, fileProgress, speed in
                        guard let self = self else { return }
                        let currentStep = Double(index - 1) + fileProgress
                        self.uploadProgress = currentStep / Double(images.count)
                        self.speedMessage = speed
                        self.statusMessage = "正在上传图片 (\(index)/\(images.count))..."
                    }
                } catch {
                    print("[ConversionCoordinator] ❌ 图片上传环节报错: \(error.localizedDescription)")
                    phase = .error(message: "图片上传失败: \(error.localizedDescription)。请检查网络连接或稍后重试。")
                    return
                }
            }

            // Step 3: 执行 Markdown 转换 (如果存在替换则采用替换后的 DOM)
            statusMessage = "正在执行 Markdown 转换…"
            let markdown = try await engine.replaceImagesAndConvert(replacements)

            markdownResult = markdown
            previewHTML = EtherpadExporter.buildRenderedHTML(from: markdown)
            etherpadHTML = EtherpadExporter.buildRawHTML(from: markdown)
            
            // Transition to rendering phase (waiting for WebView)
            statusMessage = "正在渲染预览…"
            phase = .rendering
            
            NotificationManager.send(title: "飞书转换完成", subtitle: "文件已解析并准备好导出！")
        } catch {
            phase = .error(message: "转换失败: \(error.localizedDescription)")
        }
    }

    /// Complete the process once rendering is finished.
    func markDone() {
        phase = .done
    }

    /// Reset to initial state.
    func reset() {
        markdownResult = ""
        etherpadHTML = ""
        previewHTML = ""
        phase = .idle
    }
}
