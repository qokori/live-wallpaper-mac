import Foundation

/// A chosen video file. The bookmark follows the file if it is moved or renamed; the path is the fallback.
public struct VideoRef: Codable, Equatable, Sendable {
    public var path: String
    public var bookmark: Data?

    public init(path: String, bookmark: Data? = nil) {
        self.path = path
        self.bookmark = bookmark
    }

    public var fileName: String { (path as NSString).lastPathComponent }
}

public enum AssignmentMode: String, Codable, Sendable {
    case sameForAll
    case perScreen
}

/// Which video plays on which display. Displays are keyed by their CoreGraphics UUID, which survives
/// reconnects and reboots (the numeric display ID does not).
public struct WallpaperAssignments: Codable, Equatable, Sendable {
    public var mode: AssignmentMode
    /// Video for all screens; in per-screen mode, the fallback for screens without their own.
    public var shared: VideoRef?
    public var perScreen: [String: VideoRef]

    public init(mode: AssignmentMode = .sameForAll, shared: VideoRef? = nil, perScreen: [String: VideoRef] = [:]) {
        self.mode = mode
        self.shared = shared
        self.perScreen = perScreen
    }

    public func video(forDisplay uuid: String) -> VideoRef? {
        switch mode {
        case .sameForAll: shared
        case .perScreen: perScreen[uuid] ?? shared
        }
    }

    public var isEmpty: Bool { shared == nil && perScreen.isEmpty }
}
