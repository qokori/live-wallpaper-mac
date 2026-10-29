import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Animated pictures made on the spot with ImageIO; nothing is downloaded.
enum TestImages {
    static func solid(_ width: Int, _ height: Int, red: CGFloat) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(red: red, green: 1 - red, blue: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// `delays` per frame; `apng` writes a PNG with frame delays instead of a GIF.
    static func write(_ url: URL, size: (Int, Int) = (32, 24), delays: [Double], apng: Bool = false) throws {
        let type = apng ? UTType.png : UTType.gif
        let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, delays.count, nil)!
        let container: [CFString: Any] = apng
            ? [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: 0]]
            : [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]]
        CGImageDestinationSetProperties(destination, container as CFDictionary)
        for (index, delay) in delays.enumerated() {
            let frame: [CFString: Any] = apng
                ? [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: delay, kCGImagePropertyAPNGUnclampedDelayTime: delay]]
                : [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay]]
            CGImageDestinationAddImage(destination, solid(size.0, size.1, red: CGFloat(index % 5) / 5), frame as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    static func tempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "lw-gif-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
