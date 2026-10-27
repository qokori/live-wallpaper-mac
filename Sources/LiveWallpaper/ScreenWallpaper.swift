import AppKit
import AVFoundation
import WallpaperCore

/// The video wallpaper of one display: its window, its player and whether it is visible.
@MainActor
final class ScreenWallpaper {
    let displayUUID: String
    let video: URL
    private let window: WallpaperWindow
    private let loop = LoopingPlayer()
    private var observations: [NSKeyValueObservation] = []
    private var occlusionObserver: NSObjectProtocol?
    private var shown = false
    private var isClosed = false
    private var logged = false
    private(set) var isPlaying = false
    private(set) var pauseReasons: [PauseReason] = []

    var onVisibilityChange: (() -> Void)?
    var onReady: (() -> Void)?
    var onFailure: ((Error) -> Void)?

    // LW_DIAG=1 only.
    private var seamMeter: LoopSeamMeter?
    private var timeObserver: Any?

    init(displayUUID: String, video: URL, frame: NSRect) {
        self.displayUUID = displayUUID
        self.video = video
        window = WallpaperWindow(frame: frame)
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

    /// False when the window is fully covered: a fullscreen app, Mission Control, the lock screen, a sleeping display.
    var isVisible: Bool { shown && window.occlusionState.contains(.visible) }

    var shortID: String { String(displayUUID.prefix(8)) }

    func start() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await loop.load(video)
            } catch {
                guard !isClosed else { return }
                Log.event("screen \(shortID): cannot load \(video.lastPathComponent): \(error.localizedDescription)")
                onFailure?(error)
                return
            }
            guard !isClosed else { return }
            window.playerView.playerLayer.player = loop.player
            // The window appears on the first decoded frame (see `observe`), so the desktop never flashes black;
            // the timer is a fallback in case readiness is never reported.
            observe()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.show() }
        }
    }

    private func observe() {
        observations.append(window.playerView.playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
            guard layer.isReadyForDisplay else { return }
            Task { @MainActor in self?.show() }
        })
        if let looper = loop.looper {
            observations.append(looper.observe(\.status, options: [.new]) { [weak self] looper, _ in
                guard looper.status == .failed else { return }
                let error = looper.error
                Task { @MainActor in
                    guard let self, let error else { return }
                    Log.event("screen \(self.shortID): looper failed: \(error.localizedDescription)")
                    self.onFailure?(error)
                }
            })
            if Log.diagnostics {
                observations.append(looper.observe(\.loopCount, options: [.new]) { [weak self] looper, _ in
                    let count = looper.loopCount
                    Task { @MainActor in
                        guard let self else { return }
                        Log.event("screen \(self.shortID): loopCount=\(count)")
                    }
                })
            }
        }
        if Log.diagnostics { startSeamMeter() }
    }

    private func show() {
        guard !shown, !isClosed else { return }
        shown = true
        window.orderFront(nil)
        Log.event("screen \(shortID): showing \(video.lastPathComponent), \(String(format: "%.2f", loop.duration)) s loop")
        onReady?()
        onVisibilityChange?()
    }

    func fit(to frame: NSRect) {
        guard window.frame != frame else { return }
        Log.event("screen \(shortID): frame \(NSStringFromRect(window.frame)) -> \(NSStringFromRect(frame))")
        window.setFrame(frame, display: true)
    }

    func apply(_ reasons: [PauseReason]) {
        let play = reasons.isEmpty
        guard play != isPlaying || reasons != pauseReasons || !logged else { return }
        logged = true
        pauseReasons = reasons
        if play != isPlaying {
            isPlaying = play
            loop.setPlaying(play)
            seamMeter?.reset()
        }
        Log.event("screen \(shortID): " + (play ? "play" : "pause [\(reasons.map(\.rawValue).joined(separator: ","))]"))
    }

    func close() {
        isClosed = true
        if let timeObserver { loop.player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        observations.removeAll()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
        loop.stop()
        window.playerView.playerLayer.player = nil
        window.orderOut(nil)
        window.close()
        Log.event("screen \(shortID): closed \(video.lastPathComponent)")
    }

    private func startSeamMeter() {
        seamMeter = LoopSeamMeter(duration: loop.duration)
        timeObserver = loop.player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 120), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.isPlaying, self.loop.player.rate > 0 else { return }
                let wall = ProcessInfo.processInfo.systemUptime
                if let error = self.seamMeter?.observe(media: time.seconds, wall: wall) {
                    Log.event(String(
                        format: "screen %@: seam error %+.1f ms (worst %.1f ms over %d loops)",
                        self.shortID, error * 1000, (self.seamMeter?.worstError ?? 0) * 1000, self.seamMeter?.loops ?? 0
                    ))
                }
            }
        }
    }
}
