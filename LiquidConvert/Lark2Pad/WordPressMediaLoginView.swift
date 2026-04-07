import SwiftUI
import WebKit

struct WordPressMediaLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?

    private let url = URL(string: SecureRuntimeConfig.wordPressMediaURL)!

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("登录 WordPress 媒体库")
                        .font(.headline)
                    Text("完成认证后，应用会自动同步 ifanr 的登录 Cookie，并在“图库”页直接展示媒体库。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 12) {
                    Button("清除缓存并重试") {
                        WordPressCookieManager.shared.logout()
                        errorMessage = nil
                    }
                    .buttonStyle(.bordered)

                    Button("已完成登录") {
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .controlSize(.large)
            }
            .padding()
            .background(.ultraThinMaterial)
            .overlay(alignment: .bottom) {
                Divider()
            }

            ZStack {
                WordPressMediaWebView(url: url)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .focusable()
                    .allowsHitTesting(true)
                    .onAppear {
                        NSApp.activate(ignoringOtherApps: true)
                    }

                if let msg = errorMessage {
                    VStack(spacing: 16) {
                        Image(systemName: "network.slash")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                        Text("加载失败")
                            .font(.headline)
                        Text(msg)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .windowBackgroundColor))
                }
            }
        }
        .frame(minWidth: 1100, minHeight: 760)
    }
}

struct WordPressMediaWebView: View {
    let url: URL
    var onPageLoaded: (() -> Void)? = nil

    @AppStorage("wordpress_http_auth_last_username") private var lastUsername = ""
    @State private var authPrompt: WordPressHTTPAuthenticationPrompt?
    @State private var authUsername = ""
    @State private var authPassword = ""

    var body: some View {
        WordPressMediaWebViewRepresentable(
            url: url,
            onPageLoaded: onPageLoaded
        ) { prompt in
            let savedCredential = WordPressHTTPAuthStore.load()
            let preferredUsername = savedCredential?.username.isEmpty == false
                ? savedCredential?.username
                : lastUsername
            authUsername = prompt.suggestedUsername.isEmpty ? (preferredUsername ?? "") : prompt.suggestedUsername
            authPassword = savedCredential?.password ?? ""
            authPrompt = prompt
        }
        .sheet(item: $authPrompt) { prompt in
            WordPressHTTPAuthenticationSheet(
                host: prompt.host,
                realm: prompt.realm,
                username: $authUsername,
                password: $authPassword,
                onCancel: {
                    authPrompt = nil
                    authPassword = ""
                    prompt.completion(nil)
                },
                onSubmit: {
                    let credential = URLCredential(
                        user: authUsername,
                        password: authPassword,
                        persistence: .forSession
                    )
                    WordPressHTTPAuthStore.save(username: authUsername, password: authPassword)
                    lastUsername = authUsername
                    authPrompt = nil
                    authPassword = ""
                    prompt.completion(credential)
                }
            )
        }
    }
}

private struct WordPressHTTPAuthenticationPrompt: Identifiable {
    let id = UUID()
    let host: String
    let realm: String?
    let suggestedUsername: String
    let completion: (URLCredential?) -> Void
}

private struct WordPressHTTPAuthenticationSheet: View {
    private enum Field {
        case username
        case password
    }

    let host: String
    let realm: String?
    @Binding var username: String
    @Binding var password: String
    let onCancel: () -> Void
    let onSubmit: () -> Void
    @FocusState private var focusedField: Field?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("需要先完成站点认证")
                    .font(.title3.weight(.semibold))
                Text(host)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let realm, !realm.isEmpty {
                    Text("认证区域：\(realm)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 12) {
                TextField("用户名", text: $username)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .username)
                    .submitLabel(.next)
                    .onSubmit {
                        focusedField = .password
                    }

                SecureField("密码", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .password)
                    .submitLabel(.go)
                    .onSubmit {
                        submitIfPossible()
                    }
            }

            HStack {
                Spacer()

                Button("取消") {
                    onCancel()
                }
                .buttonStyle(.bordered)

                Button("登录") {
                    submitIfPossible()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(username.isEmpty || password.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 420)
        .onAppear {
            focusedField = password.isEmpty ? .username : .password
        }
    }

    private func submitIfPossible() {
        guard !username.isEmpty, !password.isEmpty else { return }
        onSubmit()
    }
}

private struct WordPressMediaWebViewRepresentable: NSViewRepresentable {
    let url: URL
    var onPageLoaded: (() -> Void)? = nil
    var onAuthenticationChallenge: (WordPressHTTPAuthenticationPrompt) -> Void

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsMagnification = true
        webView.setValue(false, forKey: "drawsBackground")
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        if nsView.url == nil {
            nsView.load(URLRequest(url: url))
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let parent: WordPressMediaWebViewRepresentable

        init(parent: WordPressMediaWebViewRepresentable) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task {
                await WordPressCookieManager.shared.syncFrom(webView: webView)
                await MainActor.run {
                    parent.onPageLoaded?()
                }
            }
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
            }
            return nil
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(.allow)
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

            if challenge.previousFailureCount == 0,
               let storedCredential = WordPressHTTPAuthStore.defaultCredential(for: challenge.protectionSpace) ?? challenge.proposedCredential {
                completionHandler(.useCredential, storedCredential)
                return
            }

            DispatchQueue.main.async {
                self.parent.onAuthenticationChallenge(
                    WordPressHTTPAuthenticationPrompt(
                        host: challenge.protectionSpace.host,
                        realm: challenge.protectionSpace.realm,
                        suggestedUsername: challenge.proposedCredential?.user ?? "",
                        completion: { credential in
                            if let credential {
                                URLCredentialStorage.shared.setDefaultCredential(
                                    credential,
                                    for: challenge.protectionSpace
                                )
                                completionHandler(.useCredential, credential)
                            } else {
                                completionHandler(.cancelAuthenticationChallenge, nil)
                            }
                        }
                    )
                )
            }
        }
    }
}
