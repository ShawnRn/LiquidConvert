import SwiftUI
import WebKit

/// 嵌入式登录视图，用于获取公司 Etherpad 的 Session
struct Lark2PadLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var coordinator: ConversionCoordinator
    @State private var errorMessage: String?
    private let url = URL(string: SecureRuntimeConfig.etherpadRootURL)!
    
    var body: some View {
        VStack(spacing: 0) {
            // 顶部栏
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("登录公司 Etherpad")
                        .font(.headline)
                    Text("完成 Google 登录后，应用将自动同步图片上传所需的凭证。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 12) {
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
    }
}

struct LoginWebView: NSViewRepresentable {
    let url: URL
    @Binding var errorMessage: String?
    @ObservedObject var coordinator: ConversionCoordinator
    
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
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
        
        init(_ parent: LoginWebView) {
            self.parent = parent
        }
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // 确保 WebView 获得焦点
            webView.window?.makeFirstResponder(webView)
            
            // 每次页面加载完成，尝试从存储中提取 Cookie 并同步
            Task {
                await CookieManager.shared.syncFrom(webView: webView)
                // 立即刷新 UI 状态
                await MainActor.run {
                    parent.coordinator.checkLoginStatus()
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
