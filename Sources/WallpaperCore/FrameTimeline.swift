import Foundation
import ImageIO

/// Frame delays of an animated picture (GIF, APNG) and the frame to show at a given moment of an endless loop.
public struct FrameTimeline: Equatable, Sendable {
    /// Browsers treat a delay of 0.01 s or less as 0.1 s (most GIF encoders write 0 for "as fast as possible").
    public static let minimumDelay = 0.011
    public static let fallbackDelay = 0.1

    public let delays: [Double]
    /// Start of each frame, in seconds from the beginning of the loop.
    private let starts: [Double]
    public let duration: Double

    public init(delays: [Double]) {
        self.delays = delays
        var starts: [Double] = []
        var total = 0.0
        for delay in delays {
            starts.append(total)
            total += delay
        }
        self.starts = starts
        duration = total
    }

    public var frameCount: Int { delays.count }

    /// The delay of one frame from the picture's properties: the unclamped value if there is one, else the clamped one.
    public static func delay(gif: [String: Any]?, png: [String: Any]?) -> Double {
        let raw = (gif?[kCGImagePropertyGIFUnclampedDelayTime as String] as? Double)
            ?? (gif?[kCGImagePropertyGIFDelayTime as String] as? Double)
            ?? (png?[kCGImagePropertyAPNGUnclampedDelayTime as String] as? Double)
            ?? (png?[kCGImagePropertyAPNGDelayTime as String] as? Double)
        guard let raw, raw >= minimumDelay else { return fallbackDelay }
        return raw
    }

    /// Seconds from the start of the loop to the start of frame `index`.
    public func start(of index: Int) -> Double { starts[index] }

    /// Index of the frame on screen `elapsed` seconds after the start; the loop repeats without end.
    public func frame(at elapsed: Double) -> Int {
        guard frameCount > 1, duration > 0 else { return 0 }
        let t = elapsed.truncatingRemainder(dividingBy: duration)
        // Sums of delays are inexact (0.1 + 0.2 > 0.3); a moment on a boundary belongs to the frame that starts there.
        let moment = (t < 0 ? t + duration : t) + 1e-9
        var low = 0
        var high = frameCount - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= moment { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// Seconds from `elapsed` until the next frame starts.
    public func untilNextFrame(after elapsed: Double) -> Double {
        guard frameCount > 1, duration > 0 else { return .infinity }
        let index = frame(at: elapsed)
        let t = elapsed.truncatingRemainder(dividingBy: duration)
        let moment = t < 0 ? t + duration : t
        return max(starts[index] + delays[index] - moment, 0.001)
    }
}

/// An animated picture file read through ImageIO. Frames are decoded one at a time, on demand.
public struct AnimatedImageInfo: Equatable, Sendable {
    public let timeline: FrameTimeline
    public let pixelWidth: Int
    public let pixelHeight: Int

    public var frameCount: Int { timeline.frameCount }

    /// Bytes one decoded frame takes (RGBA, 8 bits).
    public var frameBytes: Int { pixelWidth * pixelHeight * 4 }

    public enum Failure: Error, Equatable {
        case unreadable
        case notAnimated
    }

    public static func read(_ url: URL) throws -> AnimatedImageInfo {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetStatus(source) == .statusComplete
        else { throw Failure.unreadable }
        let count = CGImageSourceGetCount(source)
        guard count > 1 else { throw count == 1 ? Failure.notAnimated : Failure.unreadable }
        var delays: [Double] = []
        for index in 0..<count {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any]
            delays.append(FrameTimeline.delay(
                gif: properties?[kCGImagePropertyGIFDictionary as String] as? [String: Any],
                png: properties?[kCGImagePropertyPNGDictionary as String] as? [String: Any]
            ))
        }
        let first = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        let width = first?[kCGImagePropertyPixelWidth as String] as? Int ?? 0
        let height = first?[kCGImagePropertyPixelHeight as String] as? Int ?? 0
        guard width > 0, height > 0 else { throw Failure.unreadable }
        return AnimatedImageInfo(timeline: FrameTimeline(delays: delays), pixelWidth: width, pixelHeight: height)
    }
}

/// Decides how many decoded frames may stay in memory.
public enum FrameCachePolicy {
    /// All frames stay decoded (no decoding while playing) when they fit in this many bytes.
    public static let budget = 64 * 1024 * 1024

    public static func keepsAllFrames(frameCount: Int, frameBytes: Int) -> Bool {
        frameCount * frameBytes <= budget
    }

    /// Largest side to decode at: a picture bigger than the screen is shrunk to it.
    public static func decodeSize(pixelWidth: Int, pixelHeight: Int, maxSide: Int) -> Int {
        max(1, min(max(pixelWidth, pixelHeight), maxSide))
    }

    /// Bytes one frame takes once decoded at `decodeSize` for a screen of `maxSide` pixels.
    public static func decodedFrameBytes(_ info: AnimatedImageInfo, maxSide: Int) -> Int {
        let decode = decodeSize(pixelWidth: info.pixelWidth, pixelHeight: info.pixelHeight, maxSide: maxSide)
        let scale = Double(decode) / Double(max(info.pixelWidth, info.pixelHeight))
        return Int(Double(info.frameBytes) * scale * scale)
    }
}

/// Which animated pictures are turned into a video when they are added. The player draws a picture whose frames all stay
/// decoded for almost nothing (measured: 480x270 x60, 2.8 % of a core). One that does not fit `FrameCachePolicy.budget`
/// is decoded again on every frame (1280x720 x60: 24 %; 1920x1080 x120: 39 %) and a video does the same job in the
/// system's decoder. So the line is the cache budget itself: the same test the player uses to decide.
public enum GifConversionPolicy {
    public static func shouldConvert(_ info: AnimatedImageInfo, maxSide: Int) -> Bool {
        !FrameCachePolicy.keepsAllFrames(frameCount: info.frameCount, frameBytes: FrameCachePolicy.decodedFrameBytes(info, maxSide: maxSide))
    }
}
