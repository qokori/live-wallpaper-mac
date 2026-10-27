import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import WallpaperCore

/// Sets the system desktop picture to the video's first frame, so Mission Control, the login window and the moment
/// before the app starts show the same picture as the video. Remembers the user's previous pictures to restore them.
@MainActor
enum SystemWallpaper {
    private static let originalsKey = "originalDesktopPictures"

    static var framesDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "LiveWallpaper/Frames", directoryHint: .isDirectory)
    }

    /// `scaling` is read once the frame is ready, so a choice changed meanwhile still wins.
    static func applyFirstFrame(of video: URL, toDisplay uuid: String, scaling: () -> WallpaperScaling) async {
        do {
            let frame = try await firstFrame(of: video)
            guard let screen = NSScreen.screens.first(where: { $0.displayUUID == uuid }) else { return }
            let scaling = scaling()
            rememberOriginal(of: screen, uuid: uuid)
            try NSWorkspace.shared.setDesktopImageURL(frame, for: screen, options: [
                .imageScaling: scaling.desktopImageScaling,
                .allowClipping: scaling.desktopImageAllowsClipping,
            ])
            Log.event("screen \(uuid.prefix(8)): desktop picture = \(frame.lastPathComponent), \(scaling.rawValue)")
        } catch {
            Log.event("screen \(uuid.prefix(8)): desktop picture not set: \(error.localizedDescription)")
        }
    }

    static func firstFrame(of video: URL) async throws -> URL {
        let values = try video.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let name = DesktopPictureMemory.frameFileName(
            path: video.path, modified: values.contentModificationDate?.timeIntervalSince1970 ?? 0, size: values.fileSize ?? 0
        )
        let target = framesDirectory.appending(path: name)
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

    static var hasOriginals: Bool { !saved.isEmpty }

    /// Puts back the pictures that were there before the first frame was applied, on the connected screens
    /// (macOS changes the current Space of each screen only).
    static func restoreOriginals() {
        var remaining = saved
        let screens = Dictionary(NSScreen.screens.compactMap { screen in screen.displayUUID.map { ($0, screen) } }, uniquingKeysWith: { a, _ in a })
        for (uuid, picture) in DesktopPictureMemory.restorePlan(saved: remaining, connected: Array(screens.keys)) {
            guard let screen = screens[uuid] else { continue }
            do {
                try NSWorkspace.shared.setDesktopImageURL(URL(filePath: picture.path), for: screen, options: [
                    .imageScaling: picture.scaling,
                    .allowClipping: picture.clipping,
                ])
                remaining[uuid] = nil
                Log.event("screen \(uuid.prefix(8)): desktop picture restored to \(picture.path)")
            } catch {
                Log.event("screen \(uuid.prefix(8)): restore failed: \(error.localizedDescription)")
            }
        }
        saved = remaining
    }

    private static var saved: [String: DesktopPictureMemory.Picture] {
        get {
            let data = UserDefaults.standard.data(forKey: originalsKey)
            return data.flatMap { try? JSONDecoder().decode([String: DesktopPictureMemory.Picture].self, from: $0) } ?? [:]
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: originalsKey)
        }
    }

    private static func rememberOriginal(of screen: NSScreen, uuid: String) {
        let options = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
        let current = NSWorkspace.shared.desktopImageURL(for: screen).map {
            DesktopPictureMemory.Picture(
                path: $0.path,
                scaling: (options[.imageScaling] as? NSNumber)?.intValue ?? Int(NSImageScaling.scaleProportionallyUpOrDown.rawValue),
                clipping: (options[.allowClipping] as? NSNumber)?.boolValue ?? true
            )
        }
        saved = DesktopPictureMemory.remember(current, display: uuid, in: saved, framesDirectory: framesDirectory.path)
    }
}
