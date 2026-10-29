import AVFoundation
import CoreVideo
@preconcurrency import ImageIO
import WallpaperCore

/// Turns an animated GIF or APNG into an H.264 video in a cache folder; the picture itself is never touched. Frames are
/// decoded one at a time (at the screen's size at most), so memory stays at a couple of frames however long the picture is.
/// Each frame keeps its own delay as its time stamp, so the loop lasts exactly as long as the picture.
enum GifTranscoder {
    enum Failure: LocalizedError {
        case writer(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .writer(let detail): "Не удалось превратить анимацию в видео: \(detail)"
            case .cancelled: "Преобразование отменено."
            }
        }
    }

    /// H.264 levels stop at 4096 pixels on the longer side and at 8 847 360 pixels (4096x2160 and the like) in all.
    static let longestSide = 4096
    static let largestArea = 8_847_360

    /// Where the video for `source` goes: the name carries the file's path, size and date and the size it is made at, so a
    /// changed picture or a bigger screen gets a new video and an unchanged one is reused.
    static func videoURL(for source: URL, maxSide: Int = 0, in directory: URL) -> URL {
        // Not `resourceValues`: a URL object caches those and would hide a change made to the file behind it. A link is
        // followed, so a change of the file it points to is seen.
        let target = source.resolvingSymlinksInPath()
        let attributes = try? FileManager.default.attributesOfItem(atPath: target.path)
        let size = (attributes?[.size] as? Int) ?? 0
        let date = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let stamp = "\(source.standardizedFileURL.path)|\(size)|\(date)|\(maxSide)"
        // The file keeps the picture's name (the library shows it), inside a folder that carries the hash.
        let name = source.deletingPathExtension().lastPathComponent
        return directory.appending(path: StableHash.hex(stamp), directoryHint: .isDirectory).appending(path: "\(name).mp4")
    }

    /// Size of the video: the picture's, scaled down to `maxSide` (and to what H.264 takes) on its longer side, both
    /// sides even (H.264 needs it).
    static func outputSize(of info: AnimatedImageInfo, maxSide: Int) -> (width: Int, height: Int) {
        outputSize(width: info.pixelWidth, height: info.pixelHeight, maxSide: maxSide)
    }

    static func outputSize(width: Int, height: Int, maxSide: Int) -> (width: Int, height: Int) {
        let longer = max(width, height)
        let area = Double(width) * Double(height)
        let scale = min(1, Double(min(maxSide, longestSide)) / Double(longer), (Double(largestArea) / area).squareRoot())
        func even(_ value: Double) -> Int { max(2, Int((value * scale).rounded()) / 2 * 2) }
        return (even(Double(width)), even(Double(height)))
    }

    static func convert(_ source: URL, to output: URL, maxSide: Int) async throws {
        try await convert(source, info: AnimatedImageInfo.read(source), to: output, maxSide: maxSide)
    }

    /// Writes the video next to `output` first and moves it into place, so a stopped conversion leaves no half file and a
    /// finished video is never written over. `stall` is how long the encoder may go without taking a frame.
    static func convert(_ source: URL, info: AnimatedImageInfo, to output: URL, maxSide: Int, stall: Duration = .seconds(120)) async throws {
        let size = outputSize(of: info, maxSide: maxSide)
        let folder = output.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let partial = folder.appending(path: ".partial-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: partial) }
        do {
            try await write(source, info: info, size: size, to: partial, stall: stall)
        } catch {
            // A folder with nothing in it is not left behind (the video may have been there before, then it is not empty).
            try? FileManager.default.removeItem(at: partial)
            if (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.isEmpty ?? false { try? FileManager.default.removeItem(at: folder) }
            throw error
        }
        // A video that another conversion of the same picture made meanwhile is as good: keep it.
        if !FileManager.default.fileExists(atPath: output.path) { try FileManager.default.moveItem(at: partial, to: output) }
    }

    private static func write(_ source: URL, info: AnimatedImageInfo, size: (width: Int, height: Int), to url: URL, stall: Duration) async throws {
        guard let images = CGImageSourceCreateWithURL(source as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw Failure.writer("файл не читается")
        }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let pixels = size.width * size.height
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: size.width,
            AVVideoHeightKey: size.height,
            // The frames are drawn in sRGB; the stream says which colours they are, so the player does not guess.
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                // About 3 bits per pixel per second at 25 frames: 6 Mbit/s for full HD, never below 1.
                AVVideoAverageBitRateKey: max(1_000_000, pixels * 3),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: 60,
            ],
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: size.width,
            kCVPixelBufferHeightKey as String: size.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        guard writer.canAdd(input) else { throw Failure.writer("кодировщик не принял параметры") }
        writer.add(input)
        guard writer.startWriting() else { throw Failure.writer(writer.error?.localizedDescription ?? "кодировщик не запустился") }
        writer.startSession(atSourceTime: .zero)

        let timeline = info.timeline
        let queue = DispatchQueue(label: "wallpaper.gif.transcoder", qos: .userInitiated)
        let progress = Progress()
        let outcome = Outcome()
        let encoder = Unchecked(writer)
        // The writer can fail on its own, or stop taking frames, without the block below being called again; this
        // watch ends the wait then.
        let watch = Task.detached {
            while !outcome.isDone {
                try? await Task.sleep(for: .seconds(1))
                if encoder.value.status == .failed {
                    outcome.finish(.writer(encoder.value.error?.localizedDescription ?? "кодировщик остановился"))
                } else if progress.idle > stall {
                    outcome.finish(.writer("кодировщик не отвечает"))
                }
            }
        }
        defer { watch.cancel() }
        let failure: Failure? = await withTaskCancellationHandler {
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData, !outcome.isDone {
                    let index = progress.next
                    if index >= timeline.frameCount {
                        input.markAsFinished()
                        outcome.finish(nil)
                        return
                    }
                    let appended: Bool = autoreleasepool {
                        guard let buffer = pixelBuffer(images, index: index, size: size, pool: adaptor.pixelBufferPool) else { return false }
                        let time = CMTime(seconds: timeline.start(of: index), preferredTimescale: 1000)
                        return adaptor.append(buffer, withPresentationTime: time)
                    }
                    guard appended else {
                        outcome.finish(.writer(writer.error?.localizedDescription ?? "кадр \(index) не записан"))
                        return
                    }
                    progress.advance()
                }
            }
            return await outcome.wait()
        } onCancel: { outcome.finish(.cancelled) }
        if let failure {
            writer.cancelWriting()
            throw failure
        }
        writer.endSession(atSourceTime: CMTime(seconds: timeline.duration, preferredTimescale: 1000))
        await writer.finishWriting()
        guard writer.status == .completed else { throw Failure.writer(writer.error?.localizedDescription ?? "запись не завершилась") }
    }

    /// How far the writing has got and when it last moved; read by the watch, written by the writer's queue.
    private final class Progress: @unchecked Sendable {
        private let lock = NSLock()
        private var index = 0
        private var moved = SuspendingClock.now
        var next: Int { lock.withLock { index } }
        var idle: Duration { lock.withLock { SuspendingClock.now - moved } }
        func advance() { lock.withLock { index += 1; moved = .now } }
    }

    /// The end of the writing, reported once by whichever comes first: the last frame, an error, the watch or a cancel.
    private final class Outcome: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Failure?, Never>?
        private var result: Failure??

        var isDone: Bool { lock.withLock { result != nil } }

        func wait() async -> Failure? {
            await withCheckedContinuation { next in
                lock.lock()
                if let result {
                    lock.unlock()
                    next.resume(returning: result)
                } else {
                    continuation = next
                    lock.unlock()
                }
            }
        }

        func finish(_ value: Failure?) {
            lock.lock()
            guard result == nil else { lock.unlock(); return }
            result = .some(value)
            let waiting = continuation
            continuation = nil
            lock.unlock()
            waiting?.resume(returning: value)
        }
    }

    private struct Unchecked<Value>: @unchecked Sendable {
        let value: Value
        init(_ value: Value) { self.value = value }
    }

    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    private static func pixelBuffer(_ images: CGImageSource, index: Int, size: (width: Int, height: Int), pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        guard let pool, let frame = CGImageSourceCreateThumbnailAtIndex(images, index, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(size.width, size.height),
        ] as CFDictionary) else { return nil }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: size.width, height: size.height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: sRGB,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        // Transparent parts go over black, as the player's layer does.
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height))
        context.draw(frame, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, sRGB, .shouldPropagate)
        return buffer
    }
}
