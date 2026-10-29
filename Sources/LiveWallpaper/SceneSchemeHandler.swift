import Foundation
import WallpaperEngineKit
import WebKit

/// Serves the scene page and its files (`lwscene://s/...`) from memory. Answers at once, so a request is never
/// left half done when WebKit stops it.
final class SceneSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "lwscene"
    static let entry = URL(string: "lwscene://s/index.html")!

    private let assets: SceneAssets

    init(assets: SceneAssets) {
        self.assets = assets
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let request = urlSchemeTask.request
        guard let url = request.url, let resource = assets.resource(path: url.path, range: request.value(forHTTPHeaderField: "Range")),
              let response = HTTPURLResponse(url: url, statusCode: resource.status, httpVersion: "HTTP/1.1", headerFields: resource.headers)
        else {
            let url = request.url ?? Self.entry
            urlSchemeTask.didReceive(HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: [:])!)
            urlSchemeTask.didFinish()
            return
        }
        urlSchemeTask.didReceive(response)
        if !resource.body.isEmpty { urlSchemeTask.didReceive(resource.body) }
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}

/// The page's messages (`ready`, `error`) without keeping the web view's owner alive.
final class SceneMessageProxy: NSObject, WKScriptMessageHandler {
    private let handle: @MainActor ([String: Any]) -> Void

    init(_ handle: @escaping @MainActor ([String: Any]) -> Void) {
        self.handle = handle
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        MainActor.assumeIsolated { handle(body) }
    }
}
