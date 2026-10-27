import AppKit
import WallpaperCore

/// The wallpaper of one display: its window, its content and whether it is visible.
@MainActor
final class ScreenWallpaper {
    let displayUUID: String
    let source: WallpaperSource
    let content: WallpaperContent
    private let window: WallpaperWindow
    private var occlusionObserver: NSObjectProtocol?
    private var shown = false
    private var isClosed = false
    private var logged = false
    private(set) var isPlaying = false
    private(set) var pauseReasons: [PauseReason] = []
    private(set) var scaling: WallpaperScaling = .fill

    var onVisibilityChange: (() -> Void)?
    var onReady: (() -> Void)?
    var onFailure: ((Error) -> Void)?

    init(displayUUID: String, source: WallpaperSource, content: WallpaperContent, frame: NSRect) {
        self.displayUUID = displayUUID
        self.source = source
        self.content = content
        window = WallpaperWindow(frame: frame, content: content.view)
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Log.event("screen \(self.shortID): visible=\(self.isVisible)")
                self.onVisibilityChange?()
            }
        }
    }

    /// False when the window is fully covered: a fullscreen app, another Space, Mission Control, the lock screen.
    var isVisible: Bool { shown && window.occlusionState.contains(.visible) }

    var shortID: String { String(displayUUID.prefix(8)) }

    /// The window's rectangle in CoreGraphics global coordinates (for pointer forwarding).
    var boundsInCG: CGRect {
        DesktopPointer.cgRect(fromAppKit: window.frame, mainScreenHeight: NSScreen.screens.first?.frame.height ?? 0)
    }

    func start() {
        content.start(
            ready: { [weak self] in self?.show() },
            failed: { [weak self] error in
                guard let self, !self.isClosed else { return }
                Log.event("screen \(self.shortID): cannot play \(self.source.title): \(error.localizedDescription)")
                self.onFailure?(error)
            }
        )
    }

    private func show() {
        guard !shown, !isClosed else { return }
        shown = true
        window.orderFront(nil)
        Log.event("screen \(shortID): showing \(source.title)")
        onReady?()
        onVisibilityChange?()
    }

    func fit(to frame: NSRect) {
        guard window.frame != frame else { return }
        Log.event("screen \(shortID): frame \(NSStringFromRect(window.frame)) -> \(NSStringFromRect(frame))")
        window.setFrame(frame, display: true)
    }

    /// Returns whether a video changed its scaling; web pages ignore it.
    @discardableResult
    func setScaling(_ scaling: WallpaperScaling) -> Bool {
        guard let video = content as? VideoContent, scaling != self.scaling else { return false }
        self.scaling = scaling
        video.setScaling(scaling)
        Log.event("screen \(shortID): scaling \(scaling.rawValue)")
        return true
    }

    func apply(_ reasons: [PauseReason]) {
        let play = reasons.isEmpty
        guard play != isPlaying || reasons != pauseReasons || !logged else { return }
        logged = true
        pauseReasons = reasons
        if play != isPlaying {
            isPlaying = play
            content.setPlaying(play)
        }
        Log.event("screen \(shortID): " + (play ? "play" : "pause [\(reasons.map(\.rawValue).joined(separator: ","))]"))
    }

    func close() {
        isClosed = true
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
        content.stop()
        window.orderOut(nil)
        window.close()
        Log.event("screen \(shortID): closed \(source.title)")
    }
}
