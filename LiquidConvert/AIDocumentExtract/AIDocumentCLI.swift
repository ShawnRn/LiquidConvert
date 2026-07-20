import AppKit
import Foundation

enum LiquidConvertCLIInstaller {
    private static let commandName = "liquidconvert"
    private static let promptKey = "hasPromptedLiquidConvertCLIInstall.v1"

    static var candidateInstallURLs: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            URL(fileURLWithPath: "/usr/local/bin").appendingPathComponent(commandName),
            home.appendingPathComponent(".local/bin", isDirectory: true).appendingPathComponent(commandName),
        ]
    }

    static func installedCLIURLForCurrentApp() -> URL? {
        candidateInstallURLs.first { url in
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { return false }
            return content.contains(currentExecutablePath)
        }
    }

    @MainActor
    static func promptForInstallIfNeeded() {
        guard installedCLIURLForCurrentApp() == nil else { return }
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: promptKey) == false else { return }
        defaults.set(true, forKey: promptKey)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            let alert = NSAlert()
            alert.messageText = "安装 LiquidConvert CLI？"
            alert.informativeText = "安装后可以在终端或 Codex 中直接调用 `liquidconvert <URL 或文件路径>`，把 URL、PDF、Office、HTML、文本和图片转换为 Markdown。"
            alert.addButton(withTitle: "安装 CLI")
            alert.addButton(withTitle: "稍后")

            guard alert.runModal() == .alertFirstButtonReturn else { return }
            do {
                let installedURL = try installCLI()
                showInfoAlert(
                    title: "CLI 已安装",
                    message: "已安装到：\(installedURL.path)\n\n如果终端找不到命令，请把所在目录加入 PATH，或直接使用完整路径调用。"
                )
            } catch {
                showInfoAlert(title: "CLI 安装失败", message: error.localizedDescription)
            }
        }
    }

    @discardableResult
    static func installCLI() throws -> URL {
        let target = try preferredInstallURL()
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try wrapperScript.write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        return target
    }

    private static func preferredInstallURL() throws -> URL {
        let fm = FileManager.default
        let usrLocalBin = URL(fileURLWithPath: "/usr/local/bin", isDirectory: true)
        if fm.fileExists(atPath: usrLocalBin.path), fm.isWritableFile(atPath: usrLocalBin.path) {
            return usrLocalBin.appendingPathComponent(commandName)
        }
        return fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin", isDirectory: true)
            .appendingPathComponent(commandName)
    }

    private static var currentExecutablePath: String {
        Bundle.main.executableURL?.path ?? CommandLine.arguments.first ?? "LiquidConvert"
    }

    private static var wrapperScript: String {
        """
        #!/bin/zsh
        case "$1" in
          --extract-markdown|--install-cli|--cli-status|--lark2pad-export|--lark2pad-sync)
            exec "\(currentExecutablePath)" "$@"
            ;;
          *)
            exec "\(currentExecutablePath)" --extract-markdown "$@"
            ;;
        esac
        """
    }

    @MainActor
    private static func showInfoAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}

enum AIDocumentRuntimeMode {
    nonisolated(unsafe) static var isCLI = false
}

enum AIDocumentCLI {
    static func runIfNeededAndExit(arguments: [String]) {
        let userArgs = Array(arguments.dropFirst())
        guard let first = userArgs.first else { return }

        switch first {
        case "--extract-markdown":
            runExtractionAndExit(Array(userArgs.dropFirst()))
        case "--lark2pad-export":
            runLark2PadExportAndExit(Array(userArgs.dropFirst()))
        case "--lark2pad-sync":
            runLark2PadSyncAndExit(Array(userArgs.dropFirst()))
        case "--install-cli":
            do {
                let url = try LiquidConvertCLIInstaller.installCLI()
                print(url.path)
                Foundation.exit(0)
            } catch {
                fputs("LiquidConvert CLI install failed: \(error.localizedDescription)\n", stderr)
                Foundation.exit(1)
            }
        case "--cli-status":
            if let url = LiquidConvertCLIInstaller.installedCLIURLForCurrentApp() {
                print(url.path)
                Foundation.exit(0)
            }
            fputs("LiquidConvert CLI is not installed for this app build.\n", stderr)
            Foundation.exit(1)
        default:
            return
        }
    }

    private static func runExtractionAndExit(_ args: [String]) {
        AIDocumentRuntimeMode.isCLI = true

        guard !args.isEmpty, !args.contains("--help") else {
            printUsage()
            Foundation.exit(args.contains("--help") ? 0 : 2)
        }

        var sourceValue: String?
        var outputPath: String?
        var index = 0
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--output", "-o":
                guard index + 1 < args.count else {
                    fputs("Missing value for \(arg).\n", stderr)
                    Foundation.exit(2)
                }
                outputPath = args[index + 1]
                index += 2
            default:
                if sourceValue == nil {
                    sourceValue = arg
                } else {
                    fputs("Unexpected argument: \(arg)\n", stderr)
                    Foundation.exit(2)
                }
                index += 1
            }
        }

        guard let sourceValue, let source = makeSource(from: sourceValue) else {
            fputs("Please provide a valid URL or local file path.\n", stderr)
            Foundation.exit(2)
        }
        let outputURL = outputPath.map(expandPath)

        Task.detached(priority: .userInitiated) {
            do {
                let result = try await ManagedMarkItDownRuntime.shared.extract(source: source) { message in
                    fputs("[LiquidConvert] \(message)\n", stderr)
                }
                let markdown = result.markdown.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
                if let outputURL {
                    try markdown.write(to: outputURL, atomically: true, encoding: .utf8)
                    print(outputURL.path)
                } else {
                    print(markdown, terminator: "")
                }
                Foundation.exit(0)
            } catch {
                fputs("LiquidConvert extraction failed: \(error.localizedDescription)\n", stderr)
                Foundation.exit(1)
            }
        }

        dispatchMain()
    }

    private static func runLark2PadExportAndExit(_ args: [String]) {
        AIDocumentRuntimeMode.isCLI = true
        guard let parsed = parseLark2PadArguments(args, requiresOutputDirectory: true) else {
            Foundation.exit(2)
        }
        do {
            let markdown = try String(contentsOf: parsed.source, encoding: .utf8)
            let normalized = EtherpadExporter.normalizeMarkdownSpacing(markdown)
            let outputDirectory = parsed.outputDirectory!
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            let stem = parsed.source.deletingPathExtension().lastPathComponent
            let markdownURL = outputDirectory.appendingPathComponent("\(stem).normalized.md")
            let wechatURL = outputDirectory.appendingPathComponent("\(stem).wechat.html")
            let etherpadURL = outputDirectory.appendingPathComponent("\(stem).etherpad.html")
            try (normalized + "\n").write(to: markdownURL, atomically: true, encoding: .utf8)
            try EtherpadExporter.buildRenderedHTML(from: normalized).write(to: wechatURL, atomically: true, encoding: .utf8)
            try EtherpadExporter.buildRawHTML(from: normalized).write(to: etherpadURL, atomically: true, encoding: .utf8)
            printJSON([
                "ok": true,
                "markdown_path": markdownURL.path,
                "wechat_html_path": wechatURL.path,
                "etherpad_html_path": etherpadURL.path,
                "image_count": imageCount(in: normalized),
                "login_required": false,
            ])
            Foundation.exit(0)
        } catch {
            emitLark2PadError(error)
        }
    }

    private static func runLark2PadSyncAndExit(_ args: [String]) {
        AIDocumentRuntimeMode.isCLI = true
        guard let parsed = parseLark2PadArguments(args, requiresOutputDirectory: false) else {
            Foundation.exit(2)
        }
        Task.detached(priority: .userInitiated) {
            do {
                let markdown = try String(contentsOf: parsed.source, encoding: .utf8)
                let normalized = EtherpadExporter.normalizeMarkdownSpacing(markdown)
                let html = EtherpadExporter.buildRawHTML(from: normalized)
                let result = try await EtherpadSyncService.sync(
                    markdown: normalized,
                    html: html,
                    preferredPadID: parsed.padTitle
                )
                printJSON([
                    "ok": true,
                    "pad_id": result.padID,
                    "pad_url": result.url.absoluteString,
                    "renamed": result.renamed,
                    "image_count": imageCount(in: normalized),
                    "login_required": false,
                ])
                Foundation.exit(0)
            } catch {
                emitLark2PadError(error)
            }
        }
        dispatchMain()
    }

    private struct Lark2PadArguments: Sendable {
        let source: URL
        let outputDirectory: URL?
        let padTitle: String?
    }

    private static func parseLark2PadArguments(
        _ args: [String],
        requiresOutputDirectory: Bool
    ) -> Lark2PadArguments? {
        guard let first = args.first, !first.hasPrefix("--") else {
            fputs("Please provide a Markdown file path.\n", stderr)
            return nil
        }
        let source = expandPath(first)
        guard FileManager.default.fileExists(atPath: source.path) else {
            fputs("Markdown file does not exist: \(source.path)\n", stderr)
            return nil
        }
        var outputDirectory: URL?
        var padTitle: String?
        var index = 1
        while index < args.count {
            switch args[index] {
            case "--output-dir":
                guard index + 1 < args.count else { fputs("Missing value for --output-dir.\n", stderr); return nil }
                outputDirectory = expandPath(args[index + 1])
                index += 2
            case "--pad-title":
                guard index + 1 < args.count else { fputs("Missing value for --pad-title.\n", stderr); return nil }
                padTitle = args[index + 1]
                index += 2
            case "--json":
                index += 1
            default:
                fputs("Unexpected argument: \(args[index])\n", stderr)
                return nil
            }
        }
        if requiresOutputDirectory && outputDirectory == nil {
            fputs("--output-dir is required for --lark2pad-export.\n", stderr)
            return nil
        }
        return Lark2PadArguments(source: source, outputDirectory: outputDirectory, padTitle: padTitle)
    }

    private static func imageCount(in markdown: String) -> Int {
        let pattern = #"!\[[^\]]*\]\([^)]+\)|<img\b[^>]*>"#
        let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        return regex?.numberOfMatches(
            in: markdown,
            range: NSRange(markdown.startIndex..<markdown.endIndex, in: markdown)
        ) ?? 0
    }

    private static func emitLark2PadError(_ error: Error) -> Never {
        let loginRequired: Bool
        if let syncError = error as? EtherpadSyncService.SyncError,
           case .missingSession = syncError {
            loginRequired = true
        } else {
            loginRequired = false
        }
        printJSON([
            "ok": false,
            "error": error.localizedDescription,
            "login_required": loginRequired,
        ])
        Foundation.exit(1)
    }

    private static func printJSON(_ value: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            fputs("Unable to encode JSON result.\n", stderr)
            return
        }
        print(text)
    }

    private static func makeSource(from value: String) -> AIDocumentSource? {
        if let url = URL(string: value), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) {
            return .link(url)
        }
        let url = expandPath(value)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return .file(url)
    }

    private nonisolated static func expandPath(_ value: String) -> URL {
        let expanded = (value as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded)
    }

    private static func printUsage() {
        print(
            """
            Usage:
              liquidconvert <URL-or-file> [--output output.md]
              LiquidConvert --extract-markdown <URL-or-file> [--output output.md]
              liquidconvert --lark2pad-export <markdown> --output-dir <dir> --json
              liquidconvert --lark2pad-sync <markdown> --pad-title <title> --json
              LiquidConvert --install-cli

            Converts source files to Markdown and exports or syncs Lark2Pad artifacts.
            """
        )
    }
}
