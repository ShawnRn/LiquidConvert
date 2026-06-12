import SwiftUI
import WebKit

/// 嵌入式登录视图，用于获取公司 Etherpad 的 Session (内置 WebView，支持 Google 登录自动同步，已完美处理系统通行密钥 Passkey 卡死问题)
struct Lark2PadLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var coordinator: ConversionCoordinator
    @State private var errorMessage: String?
    @State private var isShowingCookieImportSheet = false
    @State private var rawCookieInput = ""
    @State private var importErrorMessage: String? = nil
    private let url = URL(string: SecureRuntimeConfig.etherpadRootURL)!
    
    var body: some View {
        VStack(spacing: 0) {
            // 顶部栏
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("登录公司 Etherpad")
                        .font(.headline)
                    Text("请在下方登录您的 Google 账号。应用会自动在登录成功后同步凭证，无需手动拷贝。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 12) {
                    Button("手动粘贴 Cookie") {
                        rawCookieInput = ""
                        importErrorMessage = nil
                        isShowingCookieImportSheet = true
                    }
                    .buttonStyle(.bordered)
                    
                    Button("清除缓存并重试") {
                        CookieManager.shared.logout()
                        coordinator.checkLoginStatus()
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
            
            // WebView + Error Overlay
            ZStack {
                LoginWebView(url: url, errorMessage: $errorMessage, coordinator: coordinator)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .focusable()
                    .allowsHitTesting(true)
                    .onAppear {
                        // 强制应用和窗口处于激活状态以接收点击
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
                        
                        Button("重新加载") {
                            errorMessage = nil
                        }
                        .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .windowBackgroundColor))
                }
            }
        }
        .frame(minWidth: 800, minHeight: 700)
        .sheet(isPresented: $isShowingCookieImportSheet) {
            CookieImportSheet(
                coordinator: coordinator,
                rawCookieInput: $rawCookieInput,
                importErrorMessage: $importErrorMessage
            ) {
                dismiss()
            }
        }
    }
}

struct LoginWebView: NSViewRepresentable {
    let url: URL
    @Binding var errorMessage: String?
    @ObservedObject var coordinator: ConversionCoordinator
    
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        
        // 关键技术突破：在 documentStart 时将 navigator.credentials 重写为 undefined。
        // 这将强制 Google 登录检测并判定当前浏览器不支持 Passkey/WebAuthn（系统通行密钥），
        // 从而自动且流畅地降级回密码/验证码登录，彻底避免 WebView 指纹无法调起导致的卡死。
        let source = """
        try {
            Object.defineProperty(navigator, 'credentials', {
                get: function() { return undefined; },
                enumerable: true,
                configurable: true
            });
        } catch (e) {
            console.log("Failed to override credentials:", e);
        }
        """
        let userScript = WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        let contentController = WKUserContentController()
        contentController.addUserScript(userScript)
        config.userContentController = contentController
        
        // 使用标准的 Chrome UA 以确保 Google 登录不被拦截
        let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
        
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = userAgent
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        
        // 尝试激活焦点，解决 Sheet 中无法交互的问题
        DispatchQueue.main.async {
            webView.window?.makeFirstResponder(webView)
        }
        
        webView.load(URLRequest(url: url))
        return webView
    }
    
    func updateNSView(_ nsView: WKWebView, context: Context) {
        // 避免在 SwiftUI 重新渲染时重复触发加载，防止卡顿
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: LoginWebView
        private var isInitialLoad = true
        
        init(_ parent: LoginWebView) {
            self.parent = parent
        }
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // 确保 WebView 获得焦点
            webView.window?.makeFirstResponder(webView)
            
            // 每次页面加载完成，尝试从存储中提取 Cookie 并同步
            Task {
                await CookieManager.shared.syncFrom(webView: webView)
                
                // 仅以真正登录成功后获取的 token Cookie 作为自动关闭的凭证
                let cookies = await webView.configuration.websiteDataStore.httpCookieStore.fetchAllCookies()
                let hasToken = cookies.contains { $0.name == SecureRuntimeConfig.etherpadTokenCookieName && !$0.value.isEmpty }
                let currentURL = await webView.url?.absoluteString ?? ""
                let isGoogleLogin = currentURL.contains("accounts.google.com")
                
                await MainActor.run {
                    parent.coordinator.checkLoginStatus()
                    
                    // 核心逻辑：只有在非初始加载，且成功获取 token 并没有卡在 Google 登录页时，才执行自动关闭。
                    // 这能彻底避免用户本来就有旧 Cookie 时，登录窗一打开就发生闪退的问题。
                    if hasToken && !isGoogleLogin && !isInitialLoad {
                        print("[LoginWebView] 检测到新会话同步完成，自动关闭登录界面. URL: \(currentURL)")
                        // 触发全局登录 dismissal
                        NotificationCenter.default.post(name: NSNotification.Name("Lark2PadLoginSuccess"), object: nil)
                    }
                    
                    // 标记初始加载已完成
                    isInitialLoad = false
                }
            }
        }
        
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            print("[LoginWebView] 加载出错 (Provisional): \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.parent.errorMessage = error.localizedDescription
            }
        }
        
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            print("[LoginWebView] 加载出错: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.parent.errorMessage = error.localizedDescription
            }
        }
        
        // 处理某些 SSO 登录尝试打开新窗口的情况
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
            }
            return nil
        }
        
        // 处理可能的重定向或登录成功后的特殊逻辑
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(.allow)
        }
    }
}

struct CookieImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var coordinator: ConversionCoordinator
    @Binding var rawCookieInput: String
    @Binding var importErrorMessage: String?
    var onImportSuccess: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("手动导入 Cookie 凭证 (备用)")
                    .font(.headline)
                Spacer()
                Button("使用默认浏览器（Chrome/Safari）登录") {
                    if let url = URL(string: SecureRuntimeConfig.etherpadRootURL) {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)
            }
            
            Text("这是一个应急的手动同步功能。你可以在默认浏览器中登录后，将 Cookie 粘贴到下方：")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            
            VStack(alignment: .leading, spacing: 6) {
                Text("获取 Cookie 的简易指南：")
                    .font(.caption)
                    .fontWeight(.bold)
                Text("1. 在外部浏览器中登录：https://pad.corp.ifanr.com\n2. 登录成功后，按 F12（或右键 -> 检查）打开开发者工具。\n3. 切换到 Console（控制台）面板，输入并执行：copy(document.cookie)\n4. 回到此处，直接粘贴即可。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)
            
            TextEditor(text: $rawCookieInput)
                .font(.system(.body, design: .monospaced))
                .frame(height: 120)
                .cornerRadius(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )
            
            if let error = importErrorMessage {
                HStack(spacing: 4) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.red)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
            
            HStack {
                Spacer()
                Button("取消") {
                    dismiss()
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                
                Button("验证并导入") {
                    if rawCookieInput.isEmpty {
                        importErrorMessage = "请粘贴 Cookie"
                        return
                    }
                    
                    let success = CookieManager.shared.importRawCookieString(rawCookieInput)
                    if success {
                        coordinator.checkLoginStatus()
                        importErrorMessage = nil
                        dismiss()
                        onImportSuccess()
                    } else {
                        importErrorMessage = "格式解析失败，请确保包含 token 或 express_sid 字段。"
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding()
        .frame(width: 550, height: 480)
    }
}
