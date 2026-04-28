import Foundation
import OSLog

struct AIDocumentHistoryRecord: Identifiable, Codable, Equatable {
    let id: UUID
    let title: String
    let sourceDisplayName: String
    let sourceDetailText: String
    let markdown: String
    let date: Date
}

actor AIDocumentExtractHistoryManager {
    static let shared = AIDocumentExtractHistoryManager()
    
    private let logger = Logger(subsystem: "com.shawnrain.LiquidConvert", category: "AIDocumentHistory")
    private let fileManager = FileManager.default
    private let maxAgeSeconds: TimeInterval = 24 * 60 * 60 // 1 day
    
    private var historyFileURL: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDirectory = appSupport.appendingPathComponent("LiquidConvert", isDirectory: true)
        if !fileManager.fileExists(atPath: appDirectory.path) {
            try? fileManager.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        }
        return appDirectory.appendingPathComponent("AIDocumentExtractHistory.json")
    }
    
    func loadHistory() -> [AIDocumentHistoryRecord] {
        guard fileManager.fileExists(atPath: historyFileURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: historyFileURL)
            let records = try JSONDecoder().decode([AIDocumentHistoryRecord].self, from: data)
            return cleanupExpiredRecords(records)
        } catch {
            logger.error("Failed to load AI Document history: \(error.localizedDescription)")
            return []
        }
    }
    
    func saveRecord(_ record: AIDocumentHistoryRecord) {
        var records = loadHistory()
        records.removeAll(where: { $0.id == record.id }) // Prevent duplicates
        records.insert(record, at: 0) // Newest first
        save(records: records)
    }
    
    func clearHistory() {
        save(records: [])
    }
    
    private func cleanupExpiredRecords(_ records: [AIDocumentHistoryRecord]) -> [AIDocumentHistoryRecord] {
        let now = Date()
        let validRecords = records.filter { now.timeIntervalSince($0.date) <= maxAgeSeconds }
        if validRecords.count != records.count {
            save(records: validRecords)
        }
        return validRecords
    }
    
    private func save(records: [AIDocumentHistoryRecord]) {
        do {
            let data = try JSONEncoder().encode(records)
            try data.write(to: historyFileURL, options: .atomic)
        } catch {
            logger.error("Failed to save AI Document history: \(error.localizedDescription)")
        }
    }
}
