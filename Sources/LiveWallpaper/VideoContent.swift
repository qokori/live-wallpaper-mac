import AppKit
import AVFoundation
import WallpaperCore

/// A looping video in an AVPlayerLayer; fill, fit or stretch as the scaling choice says.
@MainActor
final class VideoContent: WallpaperContent {
    private let url: URL
    private let label: String
    private let loop = LoopingPlayer()
    private let playerView = PlayerView()
    private var observations: [NSKeyValueObservation] = []
    private var stopped = false
    private var playing = false

    // LW_DIAG=1 only.
    private var seamMeter: LoopSeamMeter?
    private var timeObserver: Any?

    init(url: URL, label: String) {
        self.url = url
        self.label = label
    }

    var view: NSView { playerView }

    func start(ready: @escaping @MainActor () -> Void, failed: @escaping @MainActor (Error) -> Void) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await loop.load(url)
            } catch {
                if !stopped { failed(error) }
                return
            }
            guard !stopped else { return }
            playerView.playerLayer.player = loop.player
            // Ready on the first decoded frame, so the desktop never flashes black; the timer is a fallback.
            observations.append(playerView.playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { layer, _ in
                guard layer.isReadyForDisplay else { return }
                Task { @MainActor in ready() }
            })
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { ready() }
            if let looper = loop.looper {
                observations.append(looper.observe(\.status, options: [.new]) { looper, _ in
                    guard looper.status == .failed, let error = looper.error else { return }
                    Task { @MainActor in failed(error) }
                })
            }
            Log.event("\(label): \(url.lastPathComponent), \(String(format: "%.2f", loop.duration)) s loop")
            if Log.diagnostics { startSeamMeter() }
        }
    }

    func setScaling(_ scaling: WallpaperScaling) {
        playerView.playerLayer.videoGravity = AVLayerVideoGravity(rawValue: scaling.videoGravity)
    }

    func setPlaying(_ playing: Bool) {
        self.playing = playing
        loop.setPlaying(playing)
        seamMeter?.reset()
    }

    func stop() {
        stopped = true
        if let timeObserver { loop.player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        observations.removeAll()
        loop.stop()
        playerView.playerLayer.player = nil
    }

    private func startSeamMeter() {
        seamMeter = LoopSeamMeter(duration: loop.duration)
        timeObserver = loop.player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 120), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.playing, self.loop.player.rate > 0 else { return }
                guard let error = self.seamMeter?.observe(media: time.seconds, wall: ProcessInfo.processInfo.systemUptime) else { return }
                Log.event(String(
                    format: "%@: seam error %+.1f ms (worst %.1f ms over %d loops)",
                    self.label, error * 1000, (self.seamMeter?.worstError ?? 0) * 1000, self.seamMeter?.loops ?? 0
                ))
            }
        }
    }
}

final class PlayerView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.backgroundColor = NSColor.black.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func makeBackingLayer() -> CALayer { AVPlayerLayer() }

    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}
