import Combine
import SwiftUI
import EOFCore
import WebKit

/// Rendered Markdown or HTML. Markdown updates in place so the scroll position holds while typing.
struct PreviewView: UIViewRepresentable {
    let document: EditorDocument
    @EnvironmentObject private var settings: AppSettings

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let isMarkdown = document.language.id == "markdown"
        // Scripts in the previewed page stay off unless the user allows them for HTML.
        configuration.defaultWebpagePreferences.allowsContentJavaScript = !isMarkdown && settings.previewAllowsJavaScript
        configuration.dataDetectorTypes = []
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        webView.scrollView.backgroundColor = .systemBackground
        webView.navigationDelegate = context.coordinator
        context.coordinator.start(document: document, webView: webView, isMarkdown: isMarkdown)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private var subscription: AnyCancellable?
        private weak var webView: WKWebView?
        private weak var document: EditorDocument?
        private var isMarkdown = false
        private var shellLoaded = false

        func start(document: EditorDocument, webView: WKWebView, isMarkdown: Bool) {
            self.document = document
            self.webView = webView
            self.isMarkdown = isMarkdown
            if isMarkdown {
                webView.loadHTMLString(PreviewView.markdownShell, baseURL: nil)
            } else {
                render()
            }
            subscription = document.edits
                .debounce(for: .milliseconds(isMarkdown ? 250 : 600), scheduler: DispatchQueue.main)
                .sink { [weak self] _ in self?.render() }
        }

        func stop() {
            subscription = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if isMarkdown, !shellLoaded {
                shellLoaded = true
                render()
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Links open in the browser instead of replacing the preview.
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
                if url.scheme == "http" || url.scheme == "https" || url.scheme == "mailto" {
                    UIApplication.shared.open(url)
                }
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        private func render() {
            guard let document, let webView else { return }
            let text = document.text
            if isMarkdown {
                guard shellLoaded else { return }
                DispatchQueue.global(qos: .userInitiated).async {
                    let html = MarkdownHTML.render(text)
                    guard let data = try? JSONSerialization.data(withJSONObject: [html]), let json = String(data: data, encoding: .utf8) else { return }
                    DispatchQueue.main.async {
                        webView.evaluateJavaScript("document.getElementById('content').innerHTML = \(json)[0];", completionHandler: nil)
                    }
                }
            } else {
                webView.loadHTMLString(text, baseURL: nil)
            }
        }
    }

    static let markdownShell = """
    <!DOCTYPE html>
    <html>
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <style>
    :root { color-scheme: light dark; --text: #1f2328; --muted: #656d76; --border: #d0d7de; --code: #f3f5f8; --link: #0a66d8; }
    @media (prefers-color-scheme: dark) { :root { --text: #dcdfe4; --muted: #8b949e; --border: #30363d; --code: #1f232b; --link: #6cb6ff; } }
    body { font: -apple-system-body; font-family: -apple-system, system-ui, sans-serif; line-height: 1.6; color: var(--text); margin: 0; padding: 18px 20px 60px; word-wrap: break-word; -webkit-text-size-adjust: 100%; }
    #content { max-width: 760px; margin: 0 auto; }
    h1, h2, h3, h4, h5, h6 { line-height: 1.25; margin: 1.5em 0 0.6em; }
    h1 { font-size: 1.8em; } h2 { font-size: 1.45em; } h3 { font-size: 1.2em; }
    h1, h2 { padding-bottom: 0.3em; border-bottom: 1px solid var(--border); }
    #content > :first-child { margin-top: 0; }
    a { color: var(--link); text-decoration: none; }
    code, pre { font-family: ui-monospace, Menlo, monospace; font-size: 0.88em; }
    code { background: var(--code); padding: 0.15em 0.4em; border-radius: 5px; }
    pre { background: var(--code); padding: 12px 14px; border-radius: 10px; overflow-x: auto; line-height: 1.45; }
    pre code { background: none; padding: 0; font-size: 1em; }
    blockquote { margin: 1em 0; padding: 0 1em; color: var(--muted); border-left: 3px solid var(--border); }
    table { border-collapse: collapse; display: block; overflow-x: auto; margin: 1em 0; }
    th, td { border: 1px solid var(--border); padding: 6px 12px; }
    th { background: var(--code); }
    img { max-width: 100%; }
    hr { border: none; border-top: 1px solid var(--border); margin: 1.6em 0; }
    ul, ol { padding-left: 1.6em; }
    li { margin: 0.2em 0; }
    li > input[type=checkbox] { margin: 0 0.4em 0 -1.3em; }
    li:has(> input[type=checkbox]) { list-style: none; }
    </style>
    </head>
    <body><div id="content"></div></body>
    </html>
    """
}
