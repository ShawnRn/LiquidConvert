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
        exec "\(currentExecutablePath)" --extract-markdown "$@"
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
              LiquidConvert --install-cli

            Converts URL, PDF, Word, Excel, PPT, HTML, text, and image files to Markdown.
            """
        )
    }
}
