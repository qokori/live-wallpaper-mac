import AppKit
import AVFoundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// Sets the system desktop picture to the video's first frame, so Mission Control, the login window and the moment
/// before the app starts show the same picture as the video. Remembers the user's previous pictures to restore them.
@MainActor
enum SystemWallpaper {
    private static let originalsKey = "originalWallpapers"

    static var framesDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "LiveWallpaper/Frames", directoryHint: .isDirectory)
    }

    static func applyFirstFrame(of video: URL, toDisplay uuid: String) async {
        do {
            let frame = try await firstFrame(of: video)
            guard let screen = NSScreen.screens.first(where: { $0.displayUUID == uuid }) else { return }
            rememberOriginal(of: screen, uuid: uuid)
            try NSWorkspace.shared.setDesktopImageURL(frame, for: screen, options: [
                .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
                .allowClipping: true,
            ])
            Log.event("screen \(uuid.prefix(8)): desktop picture = \(frame.lastPathComponent)")
        } catch {
            Log.event("screen \(uuid.prefix(8)): desktop picture not set: \(error.localizedDescription)")
        }
    }

    /// The file name depends on the video's path, size and date: macOS caches desktop pictures by URL,
    /// so a changed video must produce a new file.
    static func firstFrame(of video: URL) async throws -> URL {
        let values = try video.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let key = "\(video.path)|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(values.fileSize ?? 0)"
        let name = SHA256.hash(data: Data(key.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let target = framesDirectory.appending(path: "\(name).jpg")
        if FileManager.default.fileExists(atPath: target.path) { return target }

        let asset = AVURLAsset(url: video)
        let start = try await asset.loadTracks(withMediaType: .video).first?.load(.timeRange).start ?? .zero
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: start).image

        try FileManager.default.createDirectory(at: framesDirectory, withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(target as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return target
    }

    static var hasOriginals: Bool {
        !(UserDefaults.standard.dictionary(forKey: originalsKey) ?? [:]).isEmpty
    }

    /// Puts back the pictures that were there before the first frame was applied, on the screens that are connected.
    static func restoreOriginals() {
        var originals = UserDefaults.standard.dictionary(forKey: originalsKey) as? [String: [String: Any]] ?? [:]
        for screen in NSScreen.screens {
            guard let uuid = screen.displayUUID, let saved = originals[uuid], let path = saved["path"] as? String else { continue }
            let options: [NSWorkspace.DesktopImageOptionKey: Any] = [
                .imageScaling: saved["scaling"] as? Int ?? Int(NSImageScaling.scaleProportionallyUpOrDown.rawValue),
                .allowClipping: saved["clipping"] as? Bool ?? true,
            ]
            do {
                try NSWorkspace.shared.setDesktopImageURL(URL(filePath: path), for: screen, options: options)
                originals[uuid] = nil
                Log.event("screen \(uuid.prefix(8)): desktop picture restored to \(path)")
            } catch {
                Log.event("screen \(uuid.prefix(8)): restore failed: \(error.localizedDescription)")
            }
        }
        UserDefaults.standard.set(originals, forKey: originalsKey)
    }

    private static func rememberOriginal(of screen: NSScreen, uuid: String) {
        var originals = UserDefaults.standard.dictionary(forKey: originalsKey) ?? [:]
        guard originals[uuid] == nil, let current = NSWorkspace.shared.desktopImageURL(for: screen),
              !current.path.hasPrefix(framesDirectory.path) else { return }
        let options = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
        let scaling = (options[.imageScaling] as? NSNumber)?.intValue ?? Int(NSImageScaling.scaleProportionallyUpOrDown.rawValue)
        let clipping = (options[.allowClipping] as? NSNumber)?.boolValue ?? true
        originals[uuid] = ["path": current.path, "scaling": scaling, "clipping": clipping]
        UserDefaults.standard.set(originals, forKey: originalsKey)
    }
}
