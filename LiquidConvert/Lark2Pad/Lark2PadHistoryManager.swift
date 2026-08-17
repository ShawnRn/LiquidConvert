//
//  Lark2PadHistoryManager.swift
//  LiquidConvert
//
//  Manages 30-day conversion history and iCloud / custom folder synchronization.
//

import AppKit
import Combine
import Foundation
import SwiftUI

struct Lark2PadHistoryItem: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    let date: Date
    let title: String
    let markdown: String
    let wechatHTML: String
    let wordpressHTML: String

    init(
        id: UUID = UUID(),
        date: Date = Date(),
        title: String,
        markdown: String,
        wechatHTML: String = "",
        wordpressHTML: String = ""
    ) {
        self.id = id
        self.date = date
        self.title = title
        self.markdown = markdown
        self.wechatHTML = wechatHTML
        self.wordpressHTML = wordpressHTML
    }
}

@MainActor
final class Lark2PadHistoryManager: ObservableObject {
    static let shared = Lark2PadHistoryManager()

    @Published var historyItems: [Lark2PadHistoryItem] = []
    @AppStorage("lark2pad_custom_history_folder") var customFolderPath: String = ""

    private init() {
        Task {
            await loadAndPruneHistoryAsync()
        }
    }

    /// Default iCloud or local storage folder path resolved safely.
    private nonisolated static func resolveFolderURL(customFolderPath: String) -> URL {
        if !customFolderPath.isEmpty {
            let url = URL(fileURLWithPath: customFolderPath)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }

        // Try default iCloud Drive folder
        if let icloudURL = FileManager.default.url(forUbiquityContainerIdentifier: nil)?.appendingPathComponent("Documents/LiquidConvertHistory") {
            try? FileManager.default.createDirectory(at: icloudURL, withIntermediateDirectories: true)
            return icloudURL
        }

        // Fallback to local Documents folder
        let localURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("LiquidConvertHistory")
        try? FileManager.default.createDirectory(at: localURL, withIntermediateDirectories: true)
        return localURL
    }

    var currentFolderURL: URL {
        Self.resolveFolderURL(customFolderPath: customFolderPath)
    }

    /// Save a new conversion item and prune entries older than 30 days.
    func saveItem(title: String, markdown: String, wechatHTML: String, wordpressHTML: String) {
        let cleanTitle = extractTitle(from: markdown, fallback: title)
        let item = Lark2PadHistoryItem(
            title: cleanTitle,
            markdown: markdown,
            wechatHTML: wechatHTML,
            wordpressHTML: wordpressHTML
        )

        historyItems.insert(item, at: 0)
        pruneOldItems()
        persistItemsAsync()
    }

    /// Manually select a custom history folder (e.g. in iCloud).
    func selectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "选择历史保存文件夹"
        panel.message = "请选择用于同步与保存 LiquidConvert 转换历史记录的 iCloud 或本地文件夹"

        if panel.runModal() == .OK, let url = panel.url {
            customFolderPath = url.path
            Task {
                await loadAndPruneHistoryAsync()
            }
        }
    }

    /// Reset to default folder.
    func resetToDefaultFolder() {
        customFolderPath = ""
        Task {
            await loadAndPruneHistoryAsync()
        }
    }

    /// Delete a specific history item.
    func deleteItem(_ item: Lark2PadHistoryItem) {
        historyItems.removeAll { $0.id == item.id }
        persistItemsAsync()
    }

    /// Clear all history.
    func clearAll() {
        historyItems.removeAll()
        persistItemsAsync()
    }

    // MARK: - Private Logic

    private func loadAndPruneHistoryAsync() async {
        let customPath = self.customFolderPath
        let items = await Task.detached(priority: .userInitiated) { () -> [Lark2PadHistoryItem] in
            let folder = Self.resolveFolderURL(customFolderPath: customPath)
            let fileURL = folder.appendingPathComponent("history_index.json")

            guard FileManager.default.fileExists(atPath: fileURL.path),
                  let data = try? Data(contentsOf: fileURL),
                  let loadedItems = try? JSONDecoder().decode([Lark2PadHistoryItem].self, from: data) else {
                return []
            }

            let calendar = Calendar.current
            let thirtyDaysAgo = calendar.date(byAdding: .day, value: -30, to: Date()) ?? Date().addingTimeInterval(-30 * 86400)
            let validItems = loadedItems.filter { $0.date >= thirtyDaysAgo }
            let pruned = validItems.count != loadedItems.count
            
            if pruned {
                if let data = try? JSONEncoder().encode(validItems) {
                    try? data.write(to: fileURL, options: .atomic)
                }
            }
            return validItems
        }.value

        self.historyItems = items
    }

    private func pruneOldItems() {
        let calendar = Calendar.current
        let thirtyDaysAgo = calendar.date(byAdding: .day, value: -30, to: Date()) ?? Date().addingTimeInterval(-30 * 86400)
        let beforeCount = historyItems.count
        historyItems.removeAll { $0.date < thirtyDaysAgo }
        if historyItems.count != beforeCount {
            persistItemsAsync()
        }
    }

    private func persistItemsAsync() {
        let itemsToSave = historyItems
        let customPath = customFolderPath
        Task.detached(priority: .utility) {
            let folder = Self.resolveFolderURL(customFolderPath: customPath)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let fileURL = folder.appendingPathComponent("history_index.json")

            if let data = try? JSONEncoder().encode(itemsToSave) {
                try? data.write(to: fileURL, options: .atomic)
            }
        }
    }

    private func extractTitle(from markdown: String, fallback: String) -> String {
        let lines = markdown.components(separatedBy: "\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# ") {
                return String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
            if !trimmed.isEmpty && !trimmed.hasPrefix("!") && !trimmed.hasPrefix("<") {
                return String(trimmed.prefix(30))
            }
        }
        return fallback.isEmpty ? "未命名转换" : fallback
    }
}
