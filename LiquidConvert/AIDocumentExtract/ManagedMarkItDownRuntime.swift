import Foundation

enum AIDocumentSource: Hashable, Sendable {
    case file(URL)
    case link(URL)

    nonisolated var displayName: String {
        switch self {
        case .file(let url):
            return url.lastPathComponent
        case .link(let url):
            return url.host ?? url.absoluteString
        }
    }

    nonisolated var detailText: String {
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

struct AIDocumentExtractionOptions: Sendable, Equatable {
    nonisolated let performOCR: Bool

    nonisolated init(performOCR: Bool) {
        self.performOCR = performOCR
    }

    nonisolated static let standard = AIDocumentExtractionOptions(performOCR: true)
    nonisolated static let withoutOCR = AIDocumentExtractionOptions(performOCR: false)
}

actor ManagedMarkItDownRuntime {
    static let shared = ManagedMarkItDownRuntime()

    private let managedVersion = "markitdown-0.1.7-python-3.10"
    private let packageSpec = "markitdown[pdf,docx,pptx,xlsx,xls]==0.1.7"
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
        let venvDirectory = rootDirectory.appendingPathComponent("venv-\(managedVersion)", isDirectory: true)
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
        try prepareVersionedEnvironment(rootDirectory: rootDirectory, venvDirectory: venvDirectory)

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
        options: AIDocumentExtractionOptions = .standard,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> AIDocumentExtractionResult {
        if case .file(let url) = source, ImageOCRService.canHandleFile(url) {
            guard options.performOCR else {
                throw NSError(
                    domain: "ManagedMarkItDownRuntime",
                    code: -5,
                    userInfo: [NSLocalizedDescriptionKey: "当前已关闭 OCR，无法提取纯图片文件。请开启 OCR 后重试。"]
                )
            }
            progress?("正在 OCR 图片文本…")
            let text = try await ImageOCRService.recognizeText(inFile: url)
            let markdown = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !markdown.isEmpty else {
                throw NSError(
                    domain: "ManagedMarkItDownRuntime",
                    code: -4,
                    userInfo: [NSLocalizedDescriptionKey: "图片 OCR 结果为空，请更换更清晰的图片后重试。"]
                )
            }

            return AIDocumentExtractionResult(
                markdown: markdown,
                source: source,
                suggestedTitle: url.deletingPathExtension().lastPathComponent
            )
        }

        if case .link(let url) = source, WeChatArticleExtractor.canHandle(url) {
            if AIDocumentRuntimeMode.isCLI {
                if url.host?.lowercased().contains("weibo") == true {
                    progress?("正在提取微博正文（CLI 专用路径）…")
                } else {
                    progress?("正在提取公众号正文（CLI 专用路径）…")
                }
                return try await WeChatArticleExtractor.extractWithoutRendering(
                    from: url,
                    options: options,
                    progress: progress
                )
            } else {
                if url.host?.lowercased().contains("weibo") == true {
                    progress?("正在提取微博正文…")
                } else {
                    progress?("正在提取公众号正文…")
                }
                return try await WeChatArticleExtractor.extract(
                    from: url,
                    options: options,
                    progress: progress
                )
            }
        }

        if case .link(let url) = source, !AIDocumentRuntimeMode.isCLI {
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
        if AIDocumentRuntimeMode.isCLI {
            progress?("正在调用 MarkItDown 提取内容（CLI 模式跳过 WebKit 渲染）…")
        } else {
            progress?("正在调用 MarkItDown 提取内容…")
        }

        let argument: String
        switch source {
        case .file(let url):
            argument = url.path
        case .link(let url):
            argument = url.absoluteString
        }

        var markdown = try Self.runCommand(
            executable: runtime.cliExecutable,
            args: [argument],
            currentDirectoryURL: runtime.rootDirectory
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)

        // MarkItDown (markdownify) escapes special chars with backslashes
        // (e.g. B\&O, Type\-C, \+). Strip them for clean readable output.
        markdown = Self.stripMarkdownEscapes(markdown)

        guard !markdown.isEmpty else {
            throw NSError(
                domain: "ManagedMarkItDownRuntime",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "提取结果为空，请更换文件或链接后重试。"]
            )
        }

        if options.performOCR {
            markdown = await MarkdownImageOCRIntegrator.insertOCRIfNeeded(
                into: markdown,
                source: source,
                progress: progress
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

    private func prepareVersionedEnvironment(rootDirectory: URL, venvDirectory: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: rootDirectory, withIntermediateDirectories: true, attributes: nil)
        if fm.fileExists(atPath: venvDirectory.path) {
            try fm.removeItem(at: venvDirectory)
        }
    }

    private func locateCompatiblePython(
        rootDirectory: URL,
        progress: (@Sendable (String) -> Void)?
    ) async throws -> URL {
        let fm = FileManager.default
        let existingRuntimeDirectory = rootDirectory.appendingPathComponent("python-runtime", isDirectory: true)
        if let bundledPython = findStandalonePython(in: existingRuntimeDirectory),
           (try? pythonVersion(for: bundledPython))?.isAtLeast(minimumPythonVersion) == true {
            return bundledPython
        }

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

    /// Remove unnecessary backslash escapes inserted by MarkItDown / markdownify.
    /// Handles common punctuation that gets escaped but should remain literal in
    /// user-facing Markdown output. Preserves intentional escapes (e.g. `\n`).
    static func stripMarkdownEscapes(_ text: String) -> String {
        // Match backslash followed by a non-alphanumeric, non-whitespace character
        // that markdownify typically escapes: & - + . ! # | ( ) [ ] { } _ * ~ > = `
        // Avoid stripping \n, \t, \r (backslash + letter) which are different.
        guard let regex = try? NSRegularExpression(
            pattern: #"\\([^a-zA-Z0-9\s])"#
        ) else { return text }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(
            in: text,
            range: range,
            withTemplate: "$1"
        )
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
