import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

@MainActor
final class WordPressMediaTransferStore: ObservableObject {
    static let shared = WordPressMediaTransferStore()

    @Published private(set) var downloadProgressByItemID: [Int: Double] = [:]
    @Published private(set) var activeDownloadItemIDs: Set<Int> = []

    private let fileManager = FileManager.default
    private let cacheDirectory: URL

    private init() {
        let baseDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        cacheDirectory = baseDirectory
            .appendingPathComponent("LiquidConvert", isDirectory: true)
            .appendingPathComponent("WordPressGallery", isDirectory: true)
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    func progress(for itemID: Int) -> Double? {
        activeDownloadItemIDs.contains(itemID) ? downloadProgressByItemID[itemID] : nil
    }

    func cachedFileURL(for item: WordPressMediaItem) -> URL? {
        let url = cacheFileURL(for: item)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    func ensureLocalFile(for item: WordPressMediaItem) async throws -> URL {
        if let cachedURL = cachedFileURL(for: item) {
            return cachedURL
        }

        return try await withCheckedThrowingContinuation { continuation in
            downloadFile(for: item, to: cacheFileURL(for: item)) { result in
                continuation.resume(with: result)
            }
        }
    }

    func preparePreviewFiles(for items: [WordPressMediaItem]) async throws -> [URL] {
        var urls: [URL] = []
        for item in items {
            urls.append(try await ensureLocalFile(for: item))
        }
        return urls
    }

    func makeFilePromiseProvider(for item: WordPressMediaItem) -> NSFilePromiseProvider {
        let fileType = UTType(mimeType: item.mimeType)?.identifier ?? UTType.image.identifier
        let delegate = WordPressMediaFilePromiseDelegate(item: item, store: self)
        let provider = NSFilePromiseProvider(fileType: fileType, delegate: delegate)
        provider.userInfo = delegate
        return provider
    }

    fileprivate func fulfillFilePromise(
        for item: WordPressMediaItem,
        in destinationDirectory: URL,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let targetURL = destinationDirectory.appendingPathComponent(exportFilename(for: item))

        Task {
            do {
                let localURL = try await ensureLocalFile(for: item)
                if fileManager.fileExists(atPath: targetURL.path) {
                    try fileManager.removeItem(at: targetURL)
                }
                try fileManager.copyItem(at: localURL, to: targetURL)
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }
    }

    private func downloadFile(
        for item: WordPressMediaItem,
        to destinationURL: URL,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        guard let sourceURL = item.originalURL else {
            completion(.failure(WordPressMediaLibraryError.invalidRequest))
            return
        }

        var request = URLRequest(url: sourceURL)
        request.setValue(SecureRuntimeConfig.wordPressMediaURL, forHTTPHeaderField: "Referer")

        let cookieHeader = WordPressCookieManager.shared.cookieHeaderValue
        if !cookieHeader.isEmpty {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }

        activeDownloadItemIDs.insert(item.id)
        downloadProgressByItemID[item.id] = 0

        let delegate = WordPressMediaDownloadDelegate(
            itemID: item.id,
            destinationURL: destinationURL,
            progressHandler: { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.downloadProgressByItemID[item.id] = progress
                }
            },
            completionHandler: { [weak self] result in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.activeDownloadItemIDs.remove(item.id)
                    self.downloadProgressByItemID[item.id] = nil
                    completion(result)
                }
            }
        )

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        delegate.session = session

        let task = session.downloadTask(with: request)
        task.resume()
    }

    private func cacheFileURL(for item: WordPressMediaItem) -> URL {
        cacheDirectory.appendingPathComponent(exportFilename(for: item))
    }

    private func exportFilename(for item: WordPressMediaItem) -> String {
        let preferredName = item.filename.isEmpty ? item.title : item.filename
        let sanitizedBase = preferredName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let ext = URL(fileURLWithPath: sanitizedBase).pathExtension
        if !ext.isEmpty {
            return sanitizedBase
        }

        let fallbackExtension = UTType(mimeType: item.mimeType)?.preferredFilenameExtension ?? "jpg"
        return "\(sanitizedBase).\(fallbackExtension)"
    }
}

private final class WordPressMediaDownloadDelegate: NSObject, URLSessionDownloadDelegate, URLSessionTaskDelegate {
    let itemID: Int
    let destinationURL: URL
    let progressHandler: @Sendable (Double) -> Void
    let completionHandler: @Sendable (Result<URL, Error>) -> Void
    weak var session: URLSession?

    init(
        itemID: Int,
        destinationURL: URL,
        progressHandler: @escaping @Sendable (Double) -> Void,
        completionHandler: @escaping @Sendable (Result<URL, Error>) -> Void
    ) {
        self.itemID = itemID
        self.destinationURL = destinationURL
        self.progressHandler = progressHandler
        self.completionHandler = completionHandler
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let method = challenge.protectionSpace.authenticationMethod
        let supportedMethods = [
            NSURLAuthenticationMethodHTTPBasic,
            NSURLAuthenticationMethodHTTPDigest,
            NSURLAuthenticationMethodDefault
        ]

        guard supportedMethods.contains(method) else {
            Task { @MainActor in
                completionHandler(.performDefaultHandling, nil)
            }
            return
        }

        if let credential = WordPressHTTPAuthStore.defaultCredential(for: challenge.protectionSpace)
            ?? challenge.proposedCredential {
            Task { @MainActor in
                completionHandler(.useCredential, credential)
            }
        } else {
            Task { @MainActor in
                completionHandler(.performDefaultHandling, nil)
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progressHandler(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            let fileManager = FileManager.default
            let destinationDirectory = destinationURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }

            try fileManager.moveItem(at: location, to: destinationURL)
            completionHandler(.success(destinationURL))
        } catch {
            completionHandler(.failure(error))
        }

        session.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            completionHandler(.failure(error))
            session.finishTasksAndInvalidate()
        }
    }
}

private final class WordPressMediaFilePromiseDelegate: NSObject, NSFilePromiseProviderDelegate {
    let item: WordPressMediaItem
    unowned let store: WordPressMediaTransferStore

    init(item: WordPressMediaItem, store: WordPressMediaTransferStore) {
        self.item = item
        self.store = store
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        item.filename
    }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        store.fulfillFilePromise(for: item, in: url) { result in
            switch result {
            case .success:
                completionHandler(nil)
            case .failure(let error):
                completionHandler(error)
            }
        }
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        .main
    }
}
