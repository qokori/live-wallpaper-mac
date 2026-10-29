import Foundation

/// Decisions behind «Кадр из видео — обои системы»: how the frame file is named, which previous picture to
/// remember, what to put back. The app does the file and NSWorkspace work.
public enum DesktopPictureMemory {
    public struct Picture: Codable, Equatable, Sendable {
        public var path: String
        public var scaling: Int
        public var clipping: Bool

        public init(path: String, scaling: Int, clipping: Bool) {
            self.path = path
            self.scaling = scaling
            self.clipping = clipping
        }
    }

    /// The name changes whenever the video changes (path, date or size): macOS caches desktop pictures by URL,
    /// so reusing a name would keep showing the old frame.
    public static func frameFileName(path: String, modified: Double, size: Int) -> String {
        StableHash.hex("\(path)|\(modified)|\(size)") + ".jpg"
    }

    /// Remembers what a display showed before the first frame went on it. Our own frames are never remembered and
    /// an existing entry is never overwritten, so applying frames again keeps the user's original picture.
    public static func remember(
        _ current: Picture?, display: String, in saved: [String: Picture], framesDirectory: String
    ) -> [String: Picture] {
        guard saved[display] == nil, let current, !current.path.hasPrefix(framesDirectory) else { return saved }
        var result = saved
        result[display] = current
        return result
    }

    /// Pictures to put back on the connected displays. Entries of disconnected displays stay for later.
    /// macOS applies each one to the current Space of that display only.
    public static func restorePlan(saved: [String: Picture], connected: [String]) -> [(display: String, picture: Picture)] {
        connected.compactMap { id in saved[id].map { (id, $0) } }
    }
}
