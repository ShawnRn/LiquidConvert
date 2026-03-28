//
//  Lark2PadExportDocument.swift
//  LiquidConvert
//
//  FileDocument wrapper for exporting Etherpad HTML via .fileExporter.
//

import SwiftUI
import UniformTypeIdentifiers

/// A simple document that wraps an HTML string for export.
struct Lark2PadExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.html] }

    var htmlContent: String

    init(html: String) {
        self.htmlContent = html
    }

    init(configuration: ReadConfiguration) throws {
        if let data = configuration.file.regularFileContents {
            htmlContent = String(data: data, encoding: .utf8) ?? ""
        } else {
            htmlContent = ""
        }
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let data = htmlContent.data(using: .utf8) ?? Data()
        return FileWrapper(regularFileWithContents: data)
    }
}
