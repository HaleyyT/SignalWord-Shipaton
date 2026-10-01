import SwiftUI
import WebKit

/// An isolated foreground challenge. No session credentials or recipient links
/// enter this WebView; its only output is a short-lived CAPTCHA token.
struct SignupVerificationView: UIViewRepresentable {
    let url: URL
    let completed: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(url: url, completed: completed) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(context.coordinator, name: "signalwordVerification")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: url))
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.stopLoading()
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "signalwordVerification")
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let url: URL
        let completed: (String) -> Void
        private var consumed = false

        init(url: URL, completed: @escaping (String) -> Void) {
            self.url = url
            self.completed = completed
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            // The challenge iframe cannot impersonate the trusted top-level page.
            guard !consumed, message.frameInfo.isMainFrame,
                  message.frameInfo.securityOrigin.protocol == "https",
                  message.frameInfo.securityOrigin.host == url.host,
                  message.frameInfo.request.url?.path == url.path,
                  let token = message.body as? String,
                  SignupVerification.validToken(token) else { return }
            consumed = true
            completed(token)
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let destination = action.request.url else { return .cancel }
            if action.targetFrame?.isMainFrame == true {
                return destination.scheme == "https" && destination.host == url.host && destination.path == url.path ? .allow : .cancel
            } else {
                // Turnstile initializes sandboxed frames before navigating them.
                // These never qualify as trusted native-message senders above.
                if ["about:blank", "about:srcdoc"].contains(destination.absoluteString) { return .allow }
                return destination.scheme == "https" && destination.host == "challenges.cloudflare.com" ? .allow : .cancel
            }
        }
    }
}
