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

    /// Where the video for `source` goes: the name carries the file's path, size and date, so a changed picture gets a
    /// new video and an unchanged one is reused.
    static func videoURL(for source: URL, in directory: URL) -> URL {
        // Not `resourceValues`: a URL object caches those and would hide a change made to the file behind it.
        let attributes = try? FileManager.default.attributesOfItem(atPath: source.path)
        let size = (attributes?[.size] as? Int) ?? 0
        let date = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let stamp = "\(source.standardizedFileURL.path)|\(size)|\(date)"
        var hash: UInt64 = 14695981039346656037 // FNV-1a: only a stable name is needed
        for byte in stamp.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        // The file keeps the picture's name (the library shows it), inside a folder that carries the hash.
        let name = source.deletingPathExtension().lastPathComponent
        return directory.appending(path: String(hash, radix: 16), directoryHint: .isDirectory).appending(path: "\(name).mp4")
    }

    /// Size of the video: the picture's, cut down to `maxSide` on its longer side, both sides even (H.264 needs it).
    static func outputSize(of info: AnimatedImageInfo, maxSide: Int) -> (width: Int, height: Int) {
        let longer = max(info.pixelWidth, info.pixelHeight)
        let scale = min(1, Double(maxSide) / Double(longer))
        func even(_ value: Double) -> Int { max(2, Int((value * scale).rounded()) / 2 * 2) }
        return (even(Double(info.pixelWidth)), even(Double(info.pixelHeight)))
    }

    /// Writes the video next to `output` first and moves it into place, so a stopped conversion leaves no half file.
    static func convert(_ source: URL, to output: URL, maxSide: Int) async throws {
        let info = try AnimatedImageInfo.read(source)
        let size = outputSize(of: info, maxSide: maxSide)
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = output.deletingLastPathComponent().appending(path: ".partial-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: partial) }
        try await write(source, info: info, size: size, to: partial)
        try? FileManager.default.removeItem(at: output)
        try FileManager.default.moveItem(at: partial, to: output)
    }

    private static func write(_ source: URL, info: AnimatedImageInfo, size: (width: Int, height: Int), to url: URL) async throws {
        guard let images = CGImageSourceCreateWithURL(source as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw Failure.writer("файл не читается")
        }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let pixels = size.width * size.height
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: size.width,
            AVVideoHeightKey: size.height,
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
        ])
        guard writer.canAdd(input) else { throw Failure.writer("кодировщик не принял параметры") }
        writer.add(input)
        guard writer.startWriting() else { throw Failure.writer(writer.error?.localizedDescription ?? "кодировщик не запустился") }
        writer.startSession(atSourceTime: .zero)

        let timeline = info.timeline
        let queue = DispatchQueue(label: "wallpaper.gif.transcoder", qos: .userInitiated)
        let next = Counter()
        let outcome: Failure? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    let index = next.value
                    if next.isCancelled || index >= timeline.frameCount {
                        input.markAsFinished()
                        continuation.resume(returning: next.isCancelled ? .cancelled : nil)
                        return
                    }
                    guard let buffer = pixelBuffer(images, index: index, size: size, pool: adaptor.pixelBufferPool) else {
                        input.markAsFinished()
                        continuation.resume(returning: .writer("кадр \(index) не прочитан"))
                        return
                    }
                    let time = CMTime(seconds: timeline.start(of: index), preferredTimescale: 1000)
                    guard adaptor.append(buffer, withPresentationTime: time) else {
                        input.markAsFinished()
                        continuation.resume(returning: .writer(writer.error?.localizedDescription ?? "кадр \(index) не записан"))
                        return
                    }
                    next.value = index + 1
                }
            }
            }
        } onCancel: { next.cancel() }
        if let outcome {
            writer.cancelWriting()
            throw outcome
        }
        writer.endSession(atSourceTime: CMTime(seconds: timeline.duration, preferredTimescale: 1000))
        await writer.finishWriting()
        guard writer.status == .completed else { throw Failure.writer(writer.error?.localizedDescription ?? "запись не завершилась") }
    }

    /// The next frame to write, touched only by the writer's queue, and the cancel flag, set from any thread.
    private final class Counter: @unchecked Sendable {
        var value = 0
        private let lock = NSLock()
        private var stopped = false
        var isCancelled: Bool { lock.withLock { stopped } }
        func cancel() { lock.withLock { stopped = true } }
    }

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
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        // Transparent parts go over black, as the player's layer does.
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height))
        context.draw(frame, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        return buffer
    }
}
