import AppKit
import AVFoundation

/// Borderless window just above the desktop picture and below the Finder icons, on every Space, transparent to the mouse.
final class WallpaperWindow: NSWindow {
    /// One above the desktop picture level: at the same level the system wallpaper window can be ordered over us
    /// after a Space switch. Finder icons sit at kCGDesktopIconWindowLevel (desktop + 20).
    static let wallpaperLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)

    let playerView = PlayerView()

    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        level = Self.wallpaperLevel
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
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
        contentView = playerView
        setFrame(frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Cover the whole screen, menu bar area included (AppKit would otherwise push the window below the menu bar).
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class PlayerView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.backgroundColor = NSColor.black.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func makeBackingLayer() -> CALayer { AVPlayerLayer() }

    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}
