import AppKit
import CryptoKit

/// What can be worked out again about a Wallpaper Engine scene: a snapshot of the drawn frame, for the card and the
/// desktop picture. Lives in `~/Library/Caches/LiveWallpaper/WallpaperEngine/<key>/`; the system may clear it.
enum EngineCache {
    /// Tests point this at a temporary folder.
    nonisolated(unsafe) static var root: URL = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appending(path: "LiveWallpaper/WallpaperEngine", directoryHint: .isDirectory)

    static let sizeLimit = 1_000_000_000

    /// From the package's and `project.json`'s path, size and modification time: an edited project gets a new key.
    static func key(for item: EngineItem) -> String {
        var text = ""
        for url in [item.package, item.folder.appending(path: "project.json")].compactMap({ $0 }) {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            text += "\(url.path)|\(values?.fileSize ?? 0)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)\n"
        }
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined().prefix(32).description
    }

    static func directory(for item: EngineItem) -> URL {
        root.appending(path: key(for: item), directoryHint: .isDirectory)
    }

    /// The snapshot, if there is one.
    static func snapshot(for item: EngineItem) -> URL? {
        let url = directory(for: item).appending(path: "snapshot.png")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    @discardableResult
    static func storeSnapshot(_ image: NSImage, for item: EngineItem) -> URL? {
        guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
        let folder = directory(for: item)
        let url = folder.appending(path: "snapshot.png")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try png.write(to: url, options: .atomic)
        } catch {
            return nil
        }
        trim()
        return url
    }

    /// Removes the project's cache (when it leaves the library).
    static func remove(for item: EngineItem) {
        try? FileManager.default.removeItem(at: directory(for: item))
    }

    /// Over the limit, the least recently written folders go first.
    static func trim(limit: Int = sizeLimit) {
        let manager = FileManager.default
        guard let folders = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles) else { return }
        var entries: [(URL, Date, Int)] = folders.map { folder in
            let date = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let files = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            let size = files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
            return (folder, date, size)
        }
        var total = entries.reduce(0) { $0 + $1.2 }
        entries.sort { $0.1 < $1.1 }
        for entry in entries where total > limit {
            try? manager.removeItem(at: entry.0)
            total -= entry.2
        }
    }
}
