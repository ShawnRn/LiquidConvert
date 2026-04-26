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
    nonisolated let markdown: String
    nonisolated let source: AIDocumentSource
    nonisolated let suggestedTitle: String?

    nonisolated init(markdown: String, source: AIDocumentSource, suggestedTitle: String? = nil) {
        self.markdown = markdown
        self.source = source
        self.suggestedTitle = suggestedTitle
    }
}

actor ManagedMarkItDownRuntime {
    static let shared = ManagedMarkItDownRuntime()

    private let managedVersion = "markitdown-0.1.5-python-3.10"
    private let packageSpec = "markitdown[pdf,docx,pptx,xlsx,xls]==0.1.5"
    private let minimumPythonVersion = PythonVersion(major: 3, minor: 10)
    private let standalonePythonRelease = "20260414"
    private let standalonePythonVersion = "3.10.20"

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
           (try? pythonVersion(for: pythonExecutable))?.isAtLeast(minimumPythonVersion) == true,
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

        let systemPython = try await locateCompatiblePython(
            rootDirectory: rootDirectory,
            progress: progress
        )
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
                return try await WeChatArticleExtractor.extract(from: url, progress: progress)
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

    private func locateCompatiblePython(
        rootDirectory: URL,
        progress: (@Sendable (String) -> Void)?
    ) async throws -> URL {
        let fm = FileManager.default
        let candidates = [
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3",
        ]

        for path in candidates where fm.fileExists(atPath: path) {
            let url = URL(fileURLWithPath: path)
            if (try? pythonVersion(for: url))?.isAtLeast(minimumPythonVersion) == true {
                return url
            }
        }

        let whichResult = ((try? Self.runCommand(
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            args: ["which", "python3"],
            currentDirectoryURL: nil
        )) ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)

        if !whichResult.isEmpty {
            let url = URL(fileURLWithPath: whichResult)
            if (try? pythonVersion(for: url))?.isAtLeast(minimumPythonVersion) == true {
                return url
            }
        }

        progress?("未检测到 Python 3.10+，正在准备内置兼容运行时…")
        return try await prepareStandalonePython(rootDirectory: rootDirectory, progress: progress)
    }

    private func prepareStandalonePython(
        rootDirectory: URL,
        progress: (@Sendable (String) -> Void)?
    ) async throws -> URL {
        let fm = FileManager.default
        let runtimeDirectory = rootDirectory.appendingPathComponent("python-runtime", isDirectory: true)
        let marker = runtimeDirectory.appendingPathComponent("python-runtime-version.txt")

        if let python = findStandalonePython(in: runtimeDirectory),
           (try? pythonVersion(for: python))?.isAtLeast(minimumPythonVersion) == true,
           let installedVersion = try? String(contentsOf: marker, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
           installedVersion == standalonePythonMarker
        {
            return python
        }

        if fm.fileExists(atPath: runtimeDirectory.path) {
            try fm.removeItem(at: runtimeDirectory)
        }
        try fm.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true)

        let archiveURL = runtimeDirectory.appendingPathComponent("python-standalone.tar.gz")
        progress?("正在下载内置 Python 运行时…")
        _ = try Self.runCommand(
            executable: URL(fileURLWithPath: "/usr/bin/curl"),
            args: [
                "-L",
                "--fail",
                "--retry", "5",
                "--retry-delay", "2",
                "--retry-all-errors",
                "-o", archiveURL.path,
                standalonePythonDownloadURL.absoluteString,
            ],
            currentDirectoryURL: runtimeDirectory
        )

        progress?("正在解压内置 Python 运行时…")
        _ = try Self.runCommand(
            executable: URL(fileURLWithPath: "/usr/bin/tar"),
            args: ["-xzf", archiveURL.path, "-C", runtimeDirectory.path],
            currentDirectoryURL: runtimeDirectory
        )
        try? fm.removeItem(at: archiveURL)

        guard let python = findStandalonePython(in: runtimeDirectory),
              (try? pythonVersion(for: python))?.isAtLeast(minimumPythonVersion) == true
        else {
            throw NSError(
                domain: "ManagedMarkItDownRuntime",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "内置 Python 运行时准备失败，请检查网络后重试。"]
            )
        }

        try standalonePythonMarker.write(to: marker, atomically: true, encoding: .utf8)
        return python
    }

    private var standalonePythonMarker: String {
        "\(standalonePythonVersion)+\(standalonePythonRelease)-\(standaloneArchitecture)"
    }

    private var standalonePythonDownloadURL: URL {
        URL(string: "https://github.com/astral-sh/python-build-standalone/releases/download/\(standalonePythonRelease)/cpython-\(standalonePythonVersion)%2B\(standalonePythonRelease)-\(standaloneArchitecture)-apple-darwin-install_only.tar.gz")!
    }

    private var standaloneArchitecture: String {
        #if arch(arm64)
        return "aarch64"
        #else
        return "x86_64"
        #endif
    }

    private func findStandalonePython(in directory: URL) -> URL? {
        let candidates = [
            directory.appendingPathComponent("python/install/bin/python3"),
            directory.appendingPathComponent("install/bin/python3"),
            directory.appendingPathComponent("python/bin/python3"),
            directory.appendingPathComponent("bin/python3"),
        ]

        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private func pythonVersion(for executable: URL) throws -> PythonVersion {
        let output = try Self.runCommand(
            executable: executable,
            args: ["-c", "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')"],
            currentDirectoryURL: nil
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)

        let parts = output.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 2 else {
            throw NSError(
                domain: "ManagedMarkItDownRuntime",
                code: -4,
                userInfo: [NSLocalizedDescriptionKey: "无法识别 Python 版本：\(output)"]
            )
        }

        return PythonVersion(major: parts[0], minor: parts[1])
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

private struct PythonVersion: Equatable, Sendable {
    let major: Int
    let minor: Int

    nonisolated func isAtLeast(_ minimum: PythonVersion) -> Bool {
        if major != minimum.major {
            return major > minimum.major
        }
        return minor >= minimum.minor
    }
}
