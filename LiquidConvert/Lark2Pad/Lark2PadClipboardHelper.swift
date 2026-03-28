//
//  Lark2PadClipboardHelper.swift
//  LiquidConvert
//
//  Cross-platform clipboard reading for Lark2Pad.
//

import Foundation

#if canImport(AppKit)
import AppKit
#endif

#if canImport(UIKit)
import UIKit
#endif

/// Reads HTML content from the system clipboard.
enum Lark2PadClipboardHelper {

    struct ClipboardContent {
        let html: String?
        let plainText: String?
    }

    /// Read clipboard and return HTML + plainText if available.
    static func read() -> ClipboardContent {
        #if os(macOS)
        return readMacOS()
        #else
        return readIOS()
        #endif
    }

    #if os(macOS)
    private static func readMacOS() -> ClipboardContent {
        let pb = NSPasteboard.general
        let html = pb.string(forType: .html)
        let text = pb.string(forType: .string)
        return ClipboardContent(html: html, plainText: text)
    }
    #endif

    #if os(iOS)
    private static func readIOS() -> ClipboardContent {
        let pb = UIPasteboard.general

        // Try to get HTML
        var html: String?
        if let htmlData = pb.data(forPasteboardType: "public.html") {
            html = String(data: htmlData, encoding: .utf8)
        }
        let text = pb.string
        return ClipboardContent(html: html, plainText: text)
    }
    #endif
}
