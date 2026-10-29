import AppKit
import ImageIO
import QuartzCore
import WallpaperCore

/// Decodes the frames of one animated picture, on its own queue. Frames stay decoded when the whole picture fits in
/// `FrameCachePolicy.budget`; a bigger one keeps only the frame on screen and the next one.
final class FrameDecoder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "wallpaper.gif.decoder", qos: .userInitiated)
    private let source: CGImageSource
    private let side: Int?
    private let keepsAll: Bool
    private var cache: [Int: CGImage] = [:]
    /// Pause before each decode; tests use it to make the decoder slower than the frame delays.
    var decodeDelay: TimeInterval = 0

    /// `maxSide`: a picture bigger than this (the screen, in pixels) is decoded smaller.
    init?(url: URL, info: AnimatedImageInfo, maxSide: Int) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        self.source = source
        let decode = FrameCachePolicy.decodeSize(pixelWidth: info.pixelWidth, pixelHeight: info.pixelHeight, maxSide: maxSide)
        side = decode < max(info.pixelWidth, info.pixelHeight) ? decode : nil
        let scale = Double(decode) / Double(max(info.pixelWidth, info.pixelHeight))
        let bytes = Int(Double(info.frameBytes) * scale * scale)
        keepsAll = FrameCachePolicy.keepsAllFrames(frameCount: info.frameCount, frameBytes: bytes)
    }

    /// Decodes `index` (and, when frames are not all kept, drops the others except `prefetch`), then calls back on main.
    func frame(_ index: Int, prefetch: Int, completion: @escaping @MainActor @Sendable (CGImage?) -> Void) {
        queue.async { [self] in
            if decodeDelay > 0 { Thread.sleep(forTimeInterval: decodeDelay) }
            let image = decoded(index)
            if !keepsAll {
                cache = cache.filter { $0.key == index || $0.key == prefetch }
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(image) } }
            if !keepsAll, cache[prefetch] == nil { _ = decoded(prefetch) }
        }
    }

    func release() {
        queue.async { [self] in cache.removeAll() }
    }

    private func decoded(_ index: Int) -> CGImage? {
        if let image = cache[index] { return image }
        let image: CGImage?
        if let side {
            image = CGImageSourceCreateThumbnailAtIndex(source, index, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: side,
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary)
        } else {
            image = CGImageSourceCreateImageAtIndex(source, index, nil)
        }
        // ImageIO hands back a lazily decoded image; drawing it here moves the decoding to this queue and leaves a plain
        // bitmap, so the main thread only hands finished pixels to the layer.
        let flat = image.flatMap(Self.bitmap)
        if let flat { cache[index] = flat }
        return flat
    }

    private static func bitmap(_ image: CGImage) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }
}

/// An animated GIF or APNG on a layer: each frame is shown for its own delay, the loop never ends. Fill, fit or stretch
/// as the scaling choice says. Playback is driven by the clock, so a pause and a late frame never shift the timing.
@MainActor
final class GifContent: WallpaperContent {
    private let url: URL
    private let label: String
    private let gifView = GifView()
    private var decoder: FrameDecoder?
    private var timeline = FrameTimeline(delays: [])
    private var timer: Timer?
    private var stopped = false
    private var playing = false
    private(set) var shown = -1
    private var requested = -1
    /// Frames asked of the decoder and not yet delivered.
    private var pending = 0
    /// The uptime clock; tests replace it.
    var clock: () -> Double = { ProcessInfo.processInfo.systemUptime }
    var decodeDelay: TimeInterval = 0 { didSet { decoder?.decodeDelay = decodeDelay } }
    /// Seconds of the loop played before the last resume, and the uptime of that resume.
    private var elapsed = 0.0
    private var resumedAt = 0.0

    init(url: URL, label: String) {
        self.url = url
        self.label = label
    }

    var view: NSView { gifView }

    func start(ready: @escaping @MainActor () -> Void, failed: @escaping @MainActor (Error) -> Void) {
        let info: AnimatedImageInfo
        do {
            info = try AnimatedImageInfo.read(url)
        } catch {
            failed(GifError(error))
            return
        }
        let maxSide = NSScreen.screens.map { Int(max($0.frame.width, $0.frame.height) * $0.backingScaleFactor) }.max() ?? 3840
        guard let decoder = FrameDecoder(url: url, info: info, maxSide: maxSide) else {
            failed(GifError.unreadable)
            return
        }
        decoder.decodeDelay = decodeDelay
        self.decoder = decoder
        timeline = info.timeline
        Log.event("\(label): \(url.lastPathComponent), \(info.frameCount) frames, \(String(format: "%.2f", info.timeline.duration)) s loop")
        decoder.frame(0, prefetch: 1 % info.frameCount) { [weak self] image in
            guard let self, !self.stopped else { return }
            guard let image else { failed(GifError.unreadable); return }
            self.gifView.layer?.contents = image
            self.shown = 0
            ready()
            if self.playing { self.resume() }
        }
    }

    func setScaling(_ scaling: WallpaperScaling) {
        gifView.layer?.contentsGravity = CALayerContentsGravity(rawValue: scaling.layerGravity)
    }

    func setPlaying(_ playing: Bool) {
        guard playing != self.playing else { return }
        if playing {
            self.playing = true
            resume()
        } else {
            // `position` reads the clock only while playing, so take it before the flag changes.
            elapsed = position
            self.playing = false
            timer?.invalidate()
            timer = nil
        }
    }

    func stop() {
        stopped = true
        timer?.invalidate()
        timer = nil
        decoder?.release()
        decoder = nil
        gifView.layer?.contents = nil
    }

    /// Where the loop is now, in seconds.
    var position: Double {
        playing ? elapsed + (clock() - resumedAt) : elapsed
    }

    private func resume() {
        guard shown >= 0 else { return } // the first frame is not decoded yet; start() resumes
        resumedAt = clock()
        tick()
    }

    private func tick() {
        timer?.invalidate()
        timer = nil
        guard playing, !stopped, let decoder else { return }
        let now = position
        let index = timeline.frame(at: now)
        // At most two decodes wait in the queue: a decoder slower than the delays shows the newest frame it has
        // finished instead of falling further behind.
        if index != shown, index != requested, pending < 2 {
            requested = index
            pending += 1
            decoder.frame(index, prefetch: (index + 1) % timeline.frameCount) { [weak self] image in
                guard let self, !self.stopped else { return }
                self.pending -= 1
                // Frames come back in the order they were asked for, so a finished one is never older than the one shown.
                if let image {
                    self.gifView.layer?.contents = image
                    self.shown = index
                }
                // A later request may be in flight; only the one that finished clears the mark.
                if self.requested == index { self.requested = -1 }
            }
        }
        let wait = timeline.untilNextFrame(after: now)
        guard wait.isFinite else { return }
        let next = Timer(timeInterval: wait, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        next.tolerance = min(wait * 0.1, 0.005)
        RunLoop.main.add(next, forMode: .common)
        timer = next
    }
}

enum GifError: LocalizedError {
    case unreadable
    case notAnimated

    init(_ failure: Error) {
        self = (failure as? AnimatedImageInfo.Failure) == .notAnimated ? .notAnimated : .unreadable
    }

    var errorDescription: String? {
        switch self {
        case .unreadable: "Не удалось прочитать картинку."
        case .notAnimated: "В файле один кадр, это не анимация."
        }
    }
}

final class GifView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resizeAspectFill
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}
