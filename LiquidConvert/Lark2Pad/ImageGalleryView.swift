import AppKit
import SwiftUI
import WebKit

struct ImageGalleryView: View {
    @StateObject private var localStore = ImageGalleryStore.shared
    @StateObject private var remoteStore = WordPressMediaLibraryStore.shared
    @StateObject private var cookieManager = WordPressCookieManager.shared
    @StateObject private var transferStore = WordPressMediaTransferStore.shared
    @State private var showLoginSheet = false
    @State private var browserReloadID = UUID()
    @State private var selection: Set<Int> = []

    private let mediaLibraryURL = URL(string: SecureRuntimeConfig.wordPressMediaURL)!

    var body: some View {
        VStack(spacing: 18) {
            headerSection
            browserSection
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
        .sheet(isPresented: $showLoginSheet, onDismiss: {
            browserReloadID = UUID()
        }) {
            WordPressMediaLoginView()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var headerSection: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Label("图库", systemImage: "photo.stack.fill")
                    .font(.title2.weight(.bold))

                Text("直接内嵌 WordPress 媒体库页面。首次使用时先完成 ifanr 后台认证，之后会像 Etherpad 一样复用已同步的 Cookie。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 10) {
                statusBadge(
                    title: cookieManager.hasValidSession ? "已登录媒体库" : "未登录媒体库",
                    tint: cookieManager.hasValidSession ? .green : .orange
                )
                statusBadge(
                    title: "远程图库 \(remoteStore.items.count) 张",
                    tint: .blue
                )
                statusBadge(
                    title: "本机已归档 \(localStore.items.count) 张上传图",
                    tint: .blue
                )
            }
        }
    }

    private func statusBadge(title: String, tint: Color) -> some View {
        Label(title, systemImage: "circle.fill")
            .font(.caption.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(tint.opacity(0.1))
            )
    }

    @ViewBuilder
    private var browserSection: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button(cookieManager.hasValidSession ? "重新认证" : "登录媒体库") {
                    showLoginSheet = true
                }
                .buttonStyle(.borderedProminent)

                Button("刷新页面") {
                    browserReloadID = UUID()
                }
                .buttonStyle(.bordered)

                Button("浏览器打开") {
                    NSWorkspace.shared.open(mediaLibraryURL)
                }
                .buttonStyle(.bordered)

                Button("清除登录态") {
                    WordPressCookieManager.shared.logout()
                    browserReloadID = UUID()
                }
                .buttonStyle(.bordered)

                Spacer()

                Text(remoteStore.lastLoadedURL.isEmpty ? (cookieManager.hasValidSession ? "认证已同步" : "等待登录") : remoteStore.lastLoadedURL)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(16)
            .background(.ultraThinMaterial.opacity(0.7))

            Divider()

            if cookieManager.hasValidSession {
                ZStack {
                    WordPressMediaBridgeView(url: mediaLibraryURL) { webView in
                        Task {
                            await remoteStore.refresh(using: webView)
                        }
                    }
                    .id(browserReloadID)
                    .frame(width: 1, height: 1)
                    .opacity(0.01)

                    if remoteStore.items.isEmpty && remoteStore.errorMessage == nil {
                        VStack(spacing: 14) {
                            ProgressView()
                                .controlSize(.large)
                            Text("正在加载图库…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let errorMessage = remoteStore.errorMessage, remoteStore.items.isEmpty {
                        VStack(spacing: 14) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 36))
                                .foregroundStyle(.orange)
                            Text(errorMessage)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                            Button("重新加载") {
                                browserReloadID = UUID()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        WordPressGalleryCollectionView(
                            items: remoteStore.items,
                            selection: $selection,
                            transferStore: transferStore,
                            onReachBottom: {
                                Task {
                                    await remoteStore.loadNextPage()
                                }
                            },
                            onOpenItem: { item in
                                if let originalURL = item.originalURL {
                                    NSWorkspace.shared.open(originalURL)
                                }
                            }
                        )
                        .overlay(alignment: .bottom) {
                            if remoteStore.isLoadingNextPage {
                                HStack(spacing: 10) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("正在加载更多图片…")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(.ultraThinMaterial, in: Capsule())
                                .padding(.bottom, 18)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.18))
            } else {
                VStack(spacing: 18) {
                    Image(systemName: "photo.stack.fill")
                        .font(.system(size: 42, weight: .light))
                        .foregroundStyle(.secondary)

                    Text("登录后原生展示图库")
                        .font(.headline)

                    Text("这里会直接显示原生缩略图网格，不再展示 WordPress 后台页面。先点上方“登录媒体库”完成认证。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 540)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.18))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.primary.opacity(0.08), lineWidth: 0.8)
        }
    }
}

private struct WordPressMediaBridgeView: NSViewRepresentable {
    let url: URL
    let onPageReady: (WKWebView) -> Void

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPageReady: onPageReady)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let onPageReady: (WKWebView) -> Void

        init(onPageReady: @escaping (WKWebView) -> Void) {
            self.onPageReady = onPageReady
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task {
                await WordPressCookieManager.shared.syncFrom(webView: webView)
                await MainActor.run {
                    onPageReady(webView)
                }
            }
        }

        func webView(
            _ webView: WKWebView,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            let method = challenge.protectionSpace.authenticationMethod
            let supportedMethods = [
                NSURLAuthenticationMethodHTTPBasic,
                NSURLAuthenticationMethodHTTPDigest,
                NSURLAuthenticationMethodDefault
            ]

            guard supportedMethods.contains(method) else {
                completionHandler(.performDefaultHandling, nil)
                return
            }

            if let credential = WordPressHTTPAuthStore.defaultCredential(for: challenge.protectionSpace)
                ?? challenge.proposedCredential {
                completionHandler(.useCredential, credential)
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        }
    }
}
