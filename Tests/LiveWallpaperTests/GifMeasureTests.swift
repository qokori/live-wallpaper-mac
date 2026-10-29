import AppKit
import AVFoundation
import Darwin
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import WallpaperCore
@testable import LiveWallpaper

/// Memory and CPU of GIF playback, printed when LW_MEASURE=1. No window is created, so what the window server spends
/// on compositing is not included. Skipped in a normal `swift test`.
@MainActor
@Suite struct GifMeasureTests {
    nonisolated private static var enabled: Bool { ProcessInfo.processInfo.environment["LW_MEASURE"] != nil }

    private static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return Double(info.phys_footprint) / 1_048_576
    }

    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    /// Moving circles on a gradient: something for the GIF encoder to compress, unlike a flat colour.
    private static func writeMoving(_ url: URL, width: Int, height: Int, frames: Int, delay: Double) throws {
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames, nil)!
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for frame in 0..<frames {
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            let t = CGFloat(frame) / CGFloat(frames)
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                      colors: [CGColor(red: t, green: 0.2, blue: 0.6, alpha: 1), CGColor(red: 0.1, green: 1 - t, blue: 0.3, alpha: 1)] as CFArray,
                                      locations: [0, 1])!
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
            for i in 0..<12 {
                let x = (CGFloat(i) / 12 + t).truncatingRemainder(dividingBy: 1) * CGFloat(width)
                context.setFillColor(CGColor(red: 1, green: CGFloat(i) / 12, blue: 0.2, alpha: 1))
                context.fillEllipse(in: CGRect(x: x, y: CGFloat(height) * (0.1 + 0.07 * CGFloat(i)), width: CGFloat(height) / 6, height: CGFloat(height) / 6))
            }
            CGImageDestinationAddImage(destination, context.makeImage()!,
                                       [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay]] as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    /// LW_MEASURE=gen writes the files; LW_MEASURE=<0|1|2> measures one of them in a fresh process, so the memory that
    /// making the GIF used does not blur the baseline.
    nonisolated private static let cases: [(Int, Int, Int, Double)] = [(480, 270, 60, 0.05), (1280, 720, 60, 0.04), (1920, 1080, 120, 0.04)]
    nonisolated private static let directory = URL(filePath: ProcessInfo.processInfo.environment["LW_MEASURE_DIR"] ?? "/tmp/lw-measure")

    @Test(.enabled(if: GifMeasureTests.enabled)) func generate() throws {
        guard ProcessInfo.processInfo.environment["LW_MEASURE"] == "gen" else { return }
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        for (width, height, frames, delay) in Self.cases {
            try Self.writeMoving(Self.directory.appending(path: "\(width)x\(height).gif"), width: width, height: height, frames: frames, delay: delay)
        }
    }

    @Test(.enabled(if: GifMeasureTests.enabled)) func memoryAndCPU() async throws {
        guard let index = ProcessInfo.processInfo.environment["LW_MEASURE"].flatMap(Int.init) else { return }
        let (width, height, frames, delay) = Self.cases[index]
        let url = Self.directory.appending(path: "\(width)x\(height).gif")
        let fileMB = Double(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) / 1_048_576
        let info = try AnimatedImageInfo.read(url)
        let allDecodedMB = Double(info.frameBytes * frames) / 1_048_576
        let policy = FrameCachePolicy.keepsAllFrames(frameCount: frames, frameBytes: info.frameBytes) ? "all frames kept" : "on demand"

        let before = Self.footprintMB()
        let content = GifContent(url: url, label: "measure")
        var ready = false
        content.start(ready: { ready = true }, failed: { _ in })
        while !ready { try await Task.sleep(for: .milliseconds(10)) }
        content.setPlaying(true)
        try await Task.sleep(for: .seconds(1)) // warm up: one pass fills the cache when it fits
        let cpu0 = Self.cpuSeconds()
        let wall0 = Date()
        var peak = 0.0
        var changes = 0
        var last: AnyObject?
        while Date().timeIntervalSince(wall0) < 6 {
            try await Task.sleep(for: .milliseconds(20))
            peak = max(peak, Self.footprintMB())
            let now = content.view.layer?.contents as AnyObject?
            if now !== last { changes += 1; last = now }
        }
        let cpu = (Self.cpuSeconds() - cpu0) / Date().timeIntervalSince(wall0) * 100
        content.stop()
        let decoder = try #require(FrameDecoder(url: url, info: info, maxSide: 100_000))
        let decodeStart = ProcessInfo.processInfo.systemUptime
        for index in 0..<frames { _ = await withCheckedContinuation { c in decoder.frame(index, prefetch: index, completion: { c.resume(returning: $0) }) } }
        let decodeMs = (ProcessInfo.processInfo.systemUptime - decodeStart) / Double(frames) * 1000
        try await Task.sleep(for: .milliseconds(300))
        let after = Self.footprintMB()
        print(String(format: "GIFMEASURE %dx%d x%d @%.0f fps: file %.1f MB, all decoded would be %.0f MB (%@); footprint +%.0f MB while playing (peak), %+.0f MB after stop; CPU %.1f%% of one core; %.0f frames/s seen (sampled), decode %.1f ms/frame",
                     width, height, frames, 1 / delay, fileMB, allDecodedMB, policy as NSString, peak - before, after - before, cpu, Double(changes) / 6, decodeMs))
    }

    /// LW_MEASURE=video<0|1|2> (run LW_MEASURE=gen first: it writes the pictures): the same pictures turned into video. Per frame, what the app process spends to decode it
    /// (AVAssetReader, decompressed to BGRA) against what the GIF decoder spends; the hardware decoder runs in a system
    /// process and is not counted here, like in the earlier video measurements.
    @Test(.enabled(if: GifMeasureTests.enabled)) func afterConversion() async throws {
        guard let value = ProcessInfo.processInfo.environment["LW_MEASURE"], value.hasPrefix("video"), let index = Int(value.dropFirst(5)) else { return }
        let (width, height, frames, delay) = Self.cases[index]
        let gif = Self.directory.appending(path: "\(width)x\(height).gif")
        let video = Self.directory.appending(path: "\(width)x\(height).mp4")
        try? FileManager.default.removeItem(at: video)
        let converting = ProcessInfo.processInfo.systemUptime
        try await GifTranscoder.convert(gif, to: video, maxSide: 3840)
        let convertSeconds = ProcessInfo.processInfo.systemUptime - converting
        let videoMB = Double(try video.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) / 1_048_576

        let asset = AVURLAsset(url: video)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let before = Self.footprintMB()
        var wall = 0.0
        var cpu = 0.0
        var count = 0
        for _ in 0..<5 {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            reader.add(output)
            reader.startReading()
            let cpu0 = Self.cpuSeconds()
            let wall0 = ProcessInfo.processInfo.systemUptime
            while let sample = output.copyNextSampleBuffer() { _ = sample; count += 1 }
            wall += ProcessInfo.processInfo.systemUptime - wall0
            cpu += Self.cpuSeconds() - cpu0
        }
        let peak = Self.footprintMB()
        let fps = 1 / delay
        print(String(format: "VIDEOMEASURE %dx%d x%d @%.0f fps: gif %.1f MB -> mp4 %.1f MB in %.1f s; per frame: wall %.1f ms, app CPU %.1f ms, which at %.0f fps is %.1f%% of a core; footprint +%.0f MB",
                     width, height, frames, fps, Double(try gif.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) / 1_048_576, videoMB, convertSeconds,
                     wall / Double(count) * 1000, cpu / Double(count) * 1000, fps, cpu / Double(count) * fps * 100, peak - before))
    }
}
