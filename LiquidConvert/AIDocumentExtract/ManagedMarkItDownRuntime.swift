import Foundation

enum AIDocumentSource: Hashable {
    case file(URL)
    case link(URL)

    var displayName: String {
        switch self {
        case .file(let url):
            return url.lastPathComponent
        case .link(let url):
            return url.host ?? url.absoluteString
        }
    }

    var detailText: String {
        switch self {
        case .file(let url):
            return url.path
        case .link(let url):
            return url.absoluteString
        }
    }
}

struct AIDocumentExtractionResult {
    let markdown: String
    let source: AIDocumentSource
}

actor ManagedMarkItDownRuntime {
    static let shared = ManagedMarkItDownRuntime()

    private let managedVersion = "0.1.5"
    private let packageSpec = "markitdown[pdf,docx,pptx,xlsx,xls]==0.1.5"

    struct RuntimeInfo {
        let rootDirectory: URL
        let pythonExecutable: URL
        let cliExecutable: URL
    }

    func prepare(progress: (@Sendable (String) -> Void)? = nil) async throws -> RuntimeInfo {
        let rootDirectory = try runtimeRootDirectory()
        let venvDirectory = rootDirectory.appendingPathComponent("venv", isDirectory: true)
        let pythonExecutable = venvDirectory.appendingPathComponent("bin/python3")
        let cliExecutable = venvDirectory.appendingPathComponent("bin/markitdown")
        let versionMarker = rootDirectory.appendingPathComponent("managed-version.txt")

        if FileManager.default.fileExists(atPath: cliExecutable.path),
           let installedVersion = try? String(contentsOf: versionMarker, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
           installedVersion == managedVersion
        {
            return RuntimeInfo(
                rootDirectory: rootDirectory,
                pythonExecutable: pythonExecutable,
                cliExecutable: cliExecutable
            )
        }

        progress?("正在准备 AI 文档提取运行环境…")
        try recreateRuntimeDirectory(at: rootDirectory)

        let systemPython = try locateSystemPython()
        progress?("正在创建独立 Python 环境…")
        _ = try Self.runCommand(
            executable: systemPython,
            args: ["-m", "venv", venvDirectory.path],
            currentDirectoryURL: rootDirectory
        )

        progress?("正在升级 pip…")
        _ = try Self.runCommand(
            executable: pythonExecutable,
            args: ["-m", "pip", "install", "--upgrade", "pip"],
            currentDirectoryURL: rootDirectory
        )

        progress?("正在安装 MarkItDown 文档能力包…")
        _ = try Self.runCommand(
            executable: pythonExecutable,
            args: ["-m", "pip", "install", packageSpec],
            currentDirectoryURL: rootDirectory
        )

        try managedVersion.write(to: versionMarker, atomically: true, encoding: .utf8)

        return RuntimeInfo(
            rootDirectory: rootDirectory,
            pythonExecutable: pythonExecutable,
            cliExecutable: cliExecutable
        )
    }

    func extract(
        source: AIDocumentSource,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> AIDocumentExtractionResult {
        if case .link(let url) = source {
            if WeChatArticleExtractor.canHandle(url) {
                progress?("正在提取公众号正文…")
                return try await WeChatArticleExtractor.extract(from: url)
            }

            if GenericWebArticleExtractor.canHandle(url), GenericWebArticleExtractor.shouldPreferOverMarkItDown(url) {
                progress?("正在提取网页正文…")
                do {
                    return try await GenericWebArticleExtractor.extract(from: url)
                } catch {
                    progress?("通用网页提取失败，正在回退到 MarkItDown…")
                }
            }
        }

        let runtime = try await prepare(progress: progress)
        progress?("正在调用 MarkItDown 提取内容…")

        let argument: String
        switch source {
        case .file(let url):
            argument = url.path
        case .link(let url):
            argument = url.absoluteString
        }

        let markdown = try Self.runCommand(
            executable: runtime.cliExecutable,
            args: [argument],
            currentDirectoryURL: runtime.rootDirectory
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !markdown.isEmpty else {
            throw NSError(
                domain: "ManagedMarkItDownRuntime",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "提取结果为空，请更换文件或链接后重试。"]
            )
        }

        return AIDocumentExtractionResult(markdown: markdown, source: source)
    }

    private func runtimeRootDirectory() throws -> URL {
        let fm = FileManager.default
        let appSupport = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let bundleName = Bundle.main.bundleIdentifier ?? "com.shawnrain.LiquidConvert"
        return appSupport
            .appendingPathComponent("LiquidConvert", isDirectory: true)
            .appendingPathComponent("AIExtraction", isDirectory: true)
            .appendingPathComponent(bundleName, isDirectory: true)
    }

    private func recreateRuntimeDirectory(at url: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
        try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
    }

    private func locateSystemPython() throws -> URL {
        let fm = FileManager.default
        let candidates = [
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3",
        ]

        if let path = candidates.first(where: { fm.fileExists(atPath: $0) }) {
            return URL(fileURLWithPath: path)
        }

        let whichResult = try Self.runCommand(
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            args: ["which", "python3"],
            currentDirectoryURL: nil
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !whichResult.isEmpty else {
            throw NSError(
                domain: "ManagedMarkItDownRuntime",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "未检测到 python3，无法安装 MarkItDown。"]
            )
        }

        return URL(fileURLWithPath: whichResult)
    }

    private static func runCommand(
        executable: URL,
        args: [String],
        currentDirectoryURL: URL?
    ) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = args
        process.currentDirectoryURL = currentDirectoryURL

        var environment = ProcessInfo.processInfo.environment
        environment["PIP_DISABLE_PIP_VERSION_CHECK"] = "1"
        environment["PYTHONUTF8"] = "1"
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(data: data, encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            let message = output.isEmpty ? "命令执行失败。" : output
            throw NSError(
                domain: "ManagedMarkItDownRuntime",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }

        return output
    }
}
