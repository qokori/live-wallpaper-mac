import Foundation

/// What a screen shows: a video file or a web page (an http(s) address, a local folder with index.html, or an .html file).
public struct WallpaperSource: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case video
        case web
    }

    public var kind: Kind
    /// A file or folder path, or an http(s) address for a remote page.
    public var location: String
    /// Finds a local file or folder after it is moved or renamed; the path is the fallback.
    public var bookmark: Data?

    public init(kind: Kind, location: String, bookmark: Data? = nil) {
        self.kind = kind
        self.location = location
        self.bookmark = bookmark
    }

    public var isRemote: Bool { kind == .web && WebAddress.isRemote(location) }

    /// Short name for the menu: the file or folder name, or the host of a remote page.
    public var title: String {
        if isRemote { return URL(string: location)?.host ?? location }
        return (location as NSString).lastPathComponent
    }
}

public enum AssignmentMode: String, Codable, Sendable {
    case sameForAll
    case perScreen
}

/// Which source plays on which display. Displays are keyed by their CoreGraphics UUID, which survives
/// reconnects and reboots (the numeric display ID does not).
public struct WallpaperAssignments: Codable, Equatable, Sendable {
    public var mode: AssignmentMode
    /// Source for all screens; in per-screen mode, the fallback for screens without their own.
    public var shared: WallpaperSource?
    public var perScreen: [String: WallpaperSource]

    public init(mode: AssignmentMode = .sameForAll, shared: WallpaperSource? = nil, perScreen: [String: WallpaperSource] = [:]) {
        self.mode = mode
        self.shared = shared
        self.perScreen = perScreen
    }

    public func source(forDisplay uuid: String) -> WallpaperSource? {
        switch mode {
        case .sameForAll: shared
        case .perScreen: perScreen[uuid] ?? shared
        }
    }

    public var isEmpty: Bool { shared == nil && perScreen.isEmpty }
}
