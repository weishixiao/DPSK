import SwiftUI
import WebKit

/// The `dsh web` interface in a WKWebView, without browser chrome: the harness has
/// its own navigation, so only a reload is offered from the shell.
struct WebContainer: UIViewRepresentable {
    let url: URL
    /// A change asks for the same page again.
    let reloadToken: Int
    /// Called with the reason a load the shell should report went wrong.
    let onFailure: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFailure: onFailure, loadedToken: reloadToken)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        // The chat plays audio it did not get a gesture for, as Safari's own page does.
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.isOpaque = false
        view.backgroundColor = .black
        view.scrollView.backgroundColor = .black
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.allowsBackForwardNavigationGestures = true
        view.load(URLRequest(url: url))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        guard context.coordinator.loadedToken != reloadToken else { return }
        context.coordinator.loadedToken = reloadToken
        view.load(URLRequest(url: url))
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let onFailure: (String) -> Void
        var loadedToken: Int

        init(onFailure: @escaping (String) -> Void, loadedToken: Int) {
            self.onFailure = onFailure
            self.loadedToken = loadedToken
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation: WKNavigation!, withError error: Error) {
            report(error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            report(error)
        }

        /// A cancelled load is the app's own redirect, not a failure the user sees.
        private func report(_ error: Error) {
            let failure = error as NSError
            if failure.domain == NSURLErrorDomain && failure.code == NSURLErrorCancelled { return }
            onFailure(failure.localizedDescription)
        }
    }
}