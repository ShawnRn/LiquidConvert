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
                statusMessage = "正在检测并上传图片 (\(images.count) 张)..."
                replacements = await ImageUploader.uploadAll(images: images)
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
