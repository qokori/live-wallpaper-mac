import CoreGraphics
import Foundation

public enum WebAddress {
    /// Accepts what a person types: "example.com/x" becomes https://example.com/x. Only http and https.
    public static func normalize(_ input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        let candidate = text.contains("://") ? text : "https://" + text
        guard let url = URL(string: candidate), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = url.host, !host.isEmpty
        else { return nil }
        return url
    }

    public static func isRemote(_ location: String) -> Bool {
        let lower = location.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://")
    }
}

/// A local page for WKWebView: the file to load and the folder it may read (scripts, shaders, images next to it).
public struct LocalPage: Equatable, Sendable {
    public let entry: String
    public let readAccess: String

    public init(entry: String, readAccess: String) {
        self.entry = entry
        self.readAccess = readAccess
    }

    /// A folder loads its index.html; an .html file loads itself with its folder readable.
    public static func resolve(path: String, isDirectory: Bool) -> LocalPage {
        let trimmed = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        if isDirectory {
            return LocalPage(entry: (trimmed as NSString).appendingPathComponent("index.html"), readAccess: trimmed)
        }
        return LocalPage(entry: trimmed, readAccess: (trimmed as NSString).deletingLastPathComponent)
    }

    /// Navigation stays inside the page's folder.
    public func allows(path: String) -> Bool {
        path == readAccess || path.hasPrefix(readAccess.hasSuffix("/") ? readAccess : readAccess + "/")
    }
}

/// Interactive web wallpapers: decides whether the pointer is on the bare desktop and where that is on the page.
/// All rectangles and points use CoreGraphics global coordinates (origin at the top left of the main display).
public enum DesktopPointer {
    public struct Window: Equatable, Sendable {
        public let layer: Int
        public let bounds: CGRect

        public init(layer: Int, bounds: CGRect) {
            self.layer = layer
            self.bounds = bounds
        }
    }

    /// True when no app window, panel, Dock or menu bar (layer 0 and up) covers the point. Desktop-level windows
    /// (Finder icons, widgets, the wallpaper itself) sit at negative layers and do not count, so icons keep working
    /// and the page still sees the pointer between them.
    public static func isOnDesktop(_ point: CGPoint, windows: [Window]) -> Bool {
        !windows.contains { $0.layer >= 0 && $0.bounds.contains(point) }
    }

    /// The point inside a wallpaper window, in page (CSS) pixels, or nil when the point is on another screen.
    public static func pagePoint(_ point: CGPoint, windowBounds: CGRect) -> CGPoint? {
        guard windowBounds.contains(point) else { return nil }
        return CGPoint(x: point.x - windowBounds.minX, y: point.y - windowBounds.minY)
    }

    /// AppKit rectangles (origin at the bottom left of the main display) to CoreGraphics global coordinates.
    public static func cgRect(fromAppKit rect: CGRect, mainScreenHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: mainScreenHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    public static func cgPoint(fromAppKit point: CGPoint, mainScreenHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: mainScreenHeight - point.y)
    }
}
