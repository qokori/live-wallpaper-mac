import AppKit

/// Borderless window just above the desktop picture and below the Finder icons, on every Space, transparent to the mouse.
final class WallpaperWindow: NSWindow {
    /// One above the desktop picture level: at the same level the system wallpaper window can be ordered over us
    /// after a Space switch. Finder icons sit at kCGDesktopIconWindowLevel (desktop + 20).
    static let wallpaperLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)

    init(frame: NSRect, content: NSView) {
        super.init(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        level = Self.wallpaperLevel
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        // Always click-through, also for interactive web pages: those get the pointer from PointerForwarder,
        // so the Finder icons above keep working.
        ignoresMouseEvents = true
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        isReleasedWhenClosed = false
        isRestorable = false
        canHide = false
        animationBehavior = .none
        isExcludedFromWindowsMenu = true
        displaysWhenScreenProfileChanges = true
        contentView = content
        setFrame(frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Cover the whole screen, menu bar area included (AppKit would otherwise push the window below the menu bar).
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// What fills a wallpaper window: a looping video or a web page.
@MainActor
protocol WallpaperContent: AnyObject {
    var view: NSView { get }
    /// `ready` when the first frame is on screen (video) or the page has loaded; `failed` when it cannot play.
    func start(ready: @escaping @MainActor () -> Void, failed: @escaping @MainActor (Error) -> Void)
    func setPlaying(_ playing: Bool)
    func stop()
}
