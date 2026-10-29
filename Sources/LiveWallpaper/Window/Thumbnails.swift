import AppKit
import AVFoundation
import ImageIO
import Observation
import WallpaperCore

/// Preview pictures for library cards: the first frame of a video, or a picture the page's folder ships
/// (`preview.png`, `thumbnail.jpg`…). Everything else shows a placeholder. Kept in memory, by library item.
@MainActor
@Observable
final class Thumbnails {
    private(set) var images: [String: NSImage] = [:]
    @ObservationIgnored private var attempted: Set<String> = []

    private static let pageNames = ["preview", "thumbnail", "screenshot", "cover"]
    private static let pageExtensions = ["png", "jpg", "jpeg", "webp", "gif"]

    func set(_ image: NSImage, for id: String) {
        images[id] = image
        attempted.insert(id)
    }

    func load(_ item: SavedWallpaper) async {
        guard !attempted.contains(item.id) else { return }
        attempted.insert(item.id)
        let image: NSImage?
        switch item.source.kind {
        case .gif: image = Self.gifFrame(of: item.source.resolvedURL)
        case .video: image = await Self.frame(of: item.source.resolvedURL)
        case .web: image = item.source.isRemote ? nil : Self.pageImage(in: item.source.resolvedURL)
        }
        if let image { images[item.id] = image }
    }

    func forget(_ id: String) {
        images[id] = nil
        attempted.remove(id)
    }

    private static func frame(of url: URL) async -> NSImage? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 400)
        do {
            let start = try await asset.loadTracks(withMediaType: .video).first?.load(.timeRange).start ?? .zero
            let cgImage = try await generator.image(at: start).image
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        } catch {
            return nil
        }
    }

    /// First frame of a GIF, decoded at card size (a big GIF is never decoded in full for a card).
    private static func gifFrame(of url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 640,
              ] as CFDictionary)
        else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private static func pageImage(in url: URL) -> NSImage? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
        let folder = isDirectory.boolValue ? url : url.deletingLastPathComponent()
        for name in pageNames {
            for ext in pageExtensions {
                let candidate = folder.appending(path: "\(name).\(ext)")
                if let image = NSImage(contentsOf: candidate) { return image }
            }
        }
        return nil
    }
}
