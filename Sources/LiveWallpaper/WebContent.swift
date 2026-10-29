import AppKit
import WallpaperCore
import WallpaperEngineKit
import WebKit

/// A web page (remote address or local folder) in a WKWebView.
///
/// Pause has two layers: the injected script stops requestAnimationFrame callbacks, CSS animations and media at
/// once, and the web view is then hidden, which makes WebKit treat the page as invisible (no frames, timers
/// throttled). A snapshot taken just before stays on screen, so a paused wallpaper keeps its last picture.
@MainActor
final class WebContent: NSObject, WallpaperContent, WKNavigationDelegate {
    enum Target: Equatable {
        case remote(URL)
        case local(LocalPage)
        /// A Wallpaper Engine scene drawn by the renderer page (see `SceneRendererPage`).
        case scene(SceneAssets)

        static func == (lhs: Target, rhs: Target) -> Bool {
            switch (lhs, rhs) {
            case (.remote(let a), .remote(let b)): a == b
            case (.local(let a), .local(let b)): a == b
            case (.scene(let a), .scene(let b)): a === b
            default: false
            }
        }
    }

    private let target: Target
    private let label: String
    private let container = NSView()
    let snapshotView = NSImageView()
    private let webView: WKWebView
    private var ready: (@MainActor () -> Void)?
    private var failed: (@MainActor (Error) -> Void)?
    private var started = false
    private var loaded = false
    private var stopped = false
    /// While a scene reloads at a new quality: the quality to go back to if the page fails. Nil otherwise.
    private var reloadingFrom: RenderQuality?
    private var reloadGeneration = 0
    /// The old page's picture covers the web view until the new page has drawn.
    private var coveredByReload = false
    private var playing = false
    private var frameRate: Int
    private var quality: RenderQuality
    private var pauseGeneration = 0
    private var sceneScaling: WallpaperScaling = .fill
    private var scenePointer: CGPoint?
    /// A scene's first drawn frame, once, for the card and the desktop picture.
    var sceneSnapshot: (@MainActor (NSImage) -> Void)?
    private var snapshotScheduled = false
    /// A Wallpaper Engine web project: the page gets the host it expects (see `EngineWebShim`).
    private let hasEngineShim: Bool

    init(
        target: Target, frameRate: Int, quality: RenderQuality = .standard, label: String, engineProperties: [EngineProject.Property]? = nil
    ) {
        self.target = target
        self.quality = quality
        self.label = label
        self.frameRate = frameRate
        hasEngineShim = engineProperties != nil
        let configuration = WKWebViewConfiguration()
        // No sound from a wallpaper: media with audio never autoplays (there is no user gesture), muted video does.
        configuration.mediaTypesRequiringUserActionForPlayback = .audio
        configuration.userContentController.addUserScript(WKUserScript(
            source: WebPageScript.source(frameRate: frameRate, paused: true),
            // Main frame only: evaluateJavaScript reaches only the main frame, so a gate in an iframe could never
            // be resumed. Iframes still stop when the web view is hidden.
            injectionTime: .atDocumentStart, forMainFrameOnly: true
        ))
        if let engineProperties {
            configuration.userContentController.addUserScript(WKUserScript(
                source: EngineWebShim.source(properties: engineProperties, frameRate: frameRate, paused: true),
                injectionTime: .atDocumentStart, forMainFrameOnly: true
            ))
        }
        if case .scene(let assets) = target {
            configuration.setURLSchemeHandler(SceneSchemeHandler(assets: assets), forURLScheme: SceneSchemeHandler.scheme)
        }
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        if case .scene = target {
            webView.configuration.userContentController.add(SceneMessageProxy { [weak self] message in self?.sceneMessage(message) }, name: "scene")
        }
        webView.navigationDelegate = self
        webView.allowsMagnification = false
        webView.allowsBackForwardNavigationGestures = false
        webView.isInspectable = Log.diagnostics
        webView.isHidden = true

        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        for view in [snapshotView, webView] as [NSView] {
            view.frame = container.bounds
            view.autoresizingMask = [.width, .height]
            container.addSubview(view)
        }
        snapshotView.imageScaling = .scaleAxesIndependently
    }

    var view: NSView { container }

    func start(ready: @escaping @MainActor () -> Void, failed: @escaping @MainActor (Error) -> Void) {
        self.ready = ready
        self.failed = failed
        started = true
        switch target {
        case .remote(let url):
            webView.load(URLRequest(url: url))
        case .local(let page):
            webView.loadFileURL(URL(filePath: page.entry), allowingReadAccessTo: URL(filePath: page.readAccess, directoryHint: .isDirectory))
        case .scene:
            webView.load(URLRequest(url: SceneSchemeHandler.entry(quality: quality)))
        }
        // A slow remote page still shows up; its own loading screen is better than nothing. A scene says when it is drawn.
        let wait: Double = if case .scene = target { 30 } else { 6 }
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in self?.markReady() }
    }

    func setPlaying(_ playing: Bool) {
        self.playing = playing
        pauseGeneration += 1
        webView.evaluateJavaScript(WebPageScript.setPaused(!playing))
        if hasEngineShim { webView.evaluateJavaScript(EngineWebShim.setPaused(!playing)) }
        webView.setAllMediaPlaybackSuspended(!playing)
        if playing {
            // A reload in progress keeps its picture on screen until the new page draws.
            if !coveredByReload {
                webView.isHidden = false
                snapshotView.isHidden = true
            }
            captureSnapshot()
            return
        }
        let generation = pauseGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            let image = webView.isHidden ? nil : try? await webView.takeSnapshot(configuration: nil)
            guard generation == pauseGeneration, !self.playing, !stopped else { return }
            if let image {
                snapshotView.image = image
                snapshotView.isHidden = false
            }
            webView.isHidden = true
        }
    }

    /// A scene is drawn again at the new quality (the page reads it when it loads); other pages have no use for it.
    /// A page that was asked for already (still loading) is asked again. While the new page loads, the picture of
    /// the old one stays on screen; if the new page fails, the old quality comes back.
    func setQuality(_ quality: RenderQuality) {
        guard quality != self.quality else { return }
        let previous = self.quality
        self.quality = quality
        guard isScene, started, !stopped else { return }
        Log.event("\(label): quality \(quality.rawValue), scene reloads")
        // If the page is already being replaced, the first rollback target stays.
        reloadingFrom = reloadingFrom ?? previous
        reloadGeneration += 1
        let generation = reloadGeneration
        let showing = loaded && !webView.isHidden
        Task { @MainActor [weak self] in
            guard let self else { return }
            let image = showing ? try? await webView.takeSnapshot(configuration: nil) : nil
            guard generation == reloadGeneration, !stopped else { return }
            if let image {
                snapshotView.image = image
                snapshotView.isHidden = false
                webView.isHidden = true
                coveredByReload = true
            }
            webView.load(URLRequest(url: SceneSchemeHandler.entry(quality: self.quality)))
        }
    }

    /// The reloaded page has drawn: it takes the screen back from the picture of the old one.
    private func reloadFinished() {
        guard reloadingFrom != nil || coveredByReload else { return }
        reloadingFrom = nil
        guard coveredByReload else { return }
        coveredByReload = false
        if playing {
            webView.isHidden = false
            snapshotView.isHidden = true
        }
    }

    /// The reloaded page failed: back to the quality that worked. A failure of that page too is only logged.
    /// Returns whether the failure was handled here.
    func reloadFailed(_ text: String) -> Bool {
        guard let back = reloadingFrom, loaded, !stopped else { return false }
        reloadingFrom = nil
        Log.event("\(label): scene failed at quality \(quality.rawValue) (\(text)), back to \(back.rawValue)")
        quality = back
        webView.load(URLRequest(url: SceneSchemeHandler.entry(quality: back)))
        reloadGeneration += 1
        return true
    }

    func setFrameRate(_ frameRate: Int) {
        self.frameRate = frameRate
        webView.evaluateJavaScript(WebPageScript.setFrameRate(frameRate))
        if hasEngineShim { webView.evaluateJavaScript(EngineWebShim.setFrameRate(frameRate)) }
    }

    /// Interactive mode: a pointer event at a point in page (CSS) pixels.
    func forward(_ kind: WebPageScript.PointerKind, at point: CGPoint) {
        guard playing else { return }
        webView.evaluateJavaScript(WebPageScript.pointer(kind, x: point.x, y: point.y))
    }

    var isPlaying: Bool { playing }
    var currentQuality: RenderQuality { quality }
    var currentFrameRate: Int { frameRate }

    // MARK: Scenes

    var isScene: Bool {
        if case .scene = target { return true }
        return false
    }

    /// A scene that follows the pointer (`cameraparallax`).
    var wantsPointer: Bool {
        if case .scene(let assets) = target { return assets.document.parallax.enabled && assets.document.parallax.mouseInfluence > 0 }
        return false
    }

    func setSceneScaling(_ scaling: WallpaperScaling) {
        sceneScaling = scaling
        webView.evaluateJavaScript("window.__lwScene && window.__lwScene.setScaling('\(scaling.rawValue)')")
    }

    /// The pointer on this screen, 0...1 from the top left.
    func setScenePointer(_ point: CGPoint) {
        scenePointer = point
        webView.evaluateJavaScript("window.__lwScene && window.__lwScene.setMouse(\(point.x), \(point.y))")
    }

    /// A picture of the scene a moment after it first draws on screen, when videos have shown their first frames.
    private func captureSnapshot() {
        guard sceneSnapshot != nil, loaded, playing, !snapshotScheduled else { return }
        snapshotScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self else { return }
            snapshotScheduled = false
            guard !stopped, playing, let handler = sceneSnapshot, let image = try? await webView.takeSnapshot(configuration: nil) else { return }
            sceneSnapshot = nil
            handler(image)
        }
    }

    /// What the renderer reports once it has drawn, for the log.
    private func sceneMessage(_ message: [String: Any]) {
        switch message["type"] as? String {
        case "ready":
            Log.event("\(label): scene drawn")
            webView.evaluateJavaScript("window.__lwScene.status()") { [label] result, _ in
                if let text = result as? String { Log.event("\(label): scene \(text)") }
            }
            markReady()
            reloadFinished()
            captureSnapshot()
        case "error":
            let text = message["message"] as? String ?? "?"
            Log.event("\(label): scene failed: \(text)")
            if reloadFailed(text) { return }
            if !loaded, !stopped { failed?(SceneError.renderer(text)) }
        default:
            break
        }
    }

    func stop() {
        stopped = true
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeAllUserScripts()
        webView.loadHTMLString("", baseURL: nil)
    }

    private func markReady() {
        guard !loaded, !stopped else { return }
        loaded = true
        ready?()
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Log.event("\(label): page loaded \(webView.url?.absoluteString ?? "")")
        // Every new document (reload, link inside the folder) starts with the values baked into the user script.
        webView.evaluateJavaScript(WebPageScript.setFrameRate(frameRate))
        webView.evaluateJavaScript(WebPageScript.setPaused(!playing))
        if hasEngineShim {
            webView.evaluateJavaScript(EngineWebShim.setFrameRate(frameRate))
            webView.evaluateJavaScript(EngineWebShim.setPaused(!playing))
        }
        if isScene {
            // A reloaded scene page (after its process ended) starts over: scaling and pointer again.
            setSceneScaling(sceneScaling)
            if let scenePointer { setScenePointer(scenePointer) }
            return
        }
        markReady()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        report(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        report(error)
    }

    /// The page's process crashed or was killed for using too much memory: load it again.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Log.event("\(label): web content process ended, reloading")
        webView.reload()
    }

    /// The wallpaper stays on its page: links to other sites or outside the local folder are ignored.
    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard navigationAction.targetFrame?.isMainFrame == true, let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        let allowed: Bool = switch target {
        case .remote(let home): url.host == home.host || url.scheme == "about"
        case .local(let page): url.isFileURL ? page.allows(path: url.path) : url.scheme == "about"
        case .scene: url.scheme == SceneSchemeHandler.scheme || url.scheme == "about"
        }
        if !allowed { Log.event("\(label): blocked navigation to \(url.absoluteString)") }
        decisionHandler(allowed ? .allow : .cancel)
    }

    private func report(_ error: Error) {
        let code = (error as NSError).code
        guard code != NSURLErrorCancelled else { return }
        Log.event("\(label): page failed: \(error.localizedDescription)")
        if reloadFailed(error.localizedDescription) { return }
        if !loaded, !stopped { failed?(error) }
    }
}


enum SceneError: LocalizedError {
    case renderer(String)

    var errorDescription: String? {
        switch self {
        case .renderer(let text): "Сцену не удалось нарисовать: \(text)"
        }
    }
}
