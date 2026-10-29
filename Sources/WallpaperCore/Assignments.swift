import Foundation

/// What a screen shows: a video file, an animated GIF or a web page (an http(s) address, a local folder with index.html, or an .html file).
public struct WallpaperSource: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case video
        case web
        /// An animated picture: GIF or APNG.
        case gif
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

/// Where a library item goes when it is applied.
public enum ApplyTarget: Equatable, Sendable {
    /// Every screen shows it.
    case all
    /// One display, by UUID; the others keep what they show.
    case display(String)
}

extension WallpaperAssignments {
    /// «Всех экранов» replaces every choice with one shared source. One display gets its own source and the mode
    /// becomes per-screen; a screen without its own source keeps following the shared one.
    public mutating func apply(_ source: WallpaperSource, to target: ApplyTarget) {
        switch target {
        case .all:
            mode = .sameForAll
            shared = source
            perScreen = [:]
        case .display(let uuid):
            mode = .perScreen
            perScreen[uuid] = source
        }
    }

    /// Displays (of the connected ones) that show this source now.
    public func displays(showing source: WallpaperSource, among connected: [String]) -> [String] {
        connected.filter { id in
            guard let shown = self.source(forDisplay: id) else { return false }
            return shown.kind == source.kind && shown.location == source.location
        }
    }
}

extension WallpaperSource.Kind {
    /// What a dropped or chosen file or folder is: a folder or an .html file is a page, .gif and .apng are animated
    /// pictures, anything else a video.
    public static func detect(path: String, isDirectory: Bool) -> WallpaperSource.Kind {
        if isDirectory { return .web }
        switch (path as NSString).pathExtension.lowercased() {
        case "html", "htm": return .web
        case "gif", "apng": return .gif
        default: return .video
        }
    }
}
