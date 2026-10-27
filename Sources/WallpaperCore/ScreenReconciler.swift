import CoreGraphics

/// Decides what happens to the wallpaper windows when screens or choices change: monitor plugged in or out,
/// resolution changed, a new source picked. The app applies the actions; this part has no AppKit and is tested.
public enum ScreenReconciler {
    public struct Screen: Equatable, Sendable {
        public let id: String
        public let frame: CGRect
        public let desired: WallpaperSource?

        public init(id: String, frame: CGRect, desired: WallpaperSource?) {
            self.id = id
            self.frame = frame
            self.desired = desired
        }
    }

    /// What a display has now: the window on screen, a replacement still loading, a source that failed to load.
    public struct State: Equatable, Sendable {
        public var active: WallpaperSource?
        public var pending: WallpaperSource?
        public var failed: WallpaperSource?

        public init(active: WallpaperSource? = nil, pending: WallpaperSource? = nil, failed: WallpaperSource? = nil) {
            self.active = active
            self.pending = pending
            self.failed = failed
        }
    }

    public enum Action: Equatable, Sendable {
        /// Existing windows follow the screen's frame (resolution or arrangement changed).
        case fit(String, CGRect)
        /// Start a new window; it replaces the active one on its first frame, so the desktop never flashes.
        case load(String, WallpaperSource, CGRect)
        case cancelPending(String)
        case closeActive(String)
        /// The screen is gone: close everything it had.
        case disconnect(String)
    }

    public static func plan(screens: [Screen], state: [String: State]) -> [Action] {
        var actions: [Action] = []
        for screen in screens {
            let current = state[screen.id] ?? State()
            if current.active != nil || current.pending != nil { actions.append(.fit(screen.id, screen.frame)) }
            if let pending = current.pending {
                if pending == screen.desired { continue }
                actions.append(.cancelPending(screen.id))
            }
            guard let desired = screen.desired else {
                if current.active != nil { actions.append(.closeActive(screen.id)) }
                continue
            }
            // A source that failed to load is retried only after the choice changes.
            if current.active == desired || current.failed == desired { continue }
            actions.append(.load(screen.id, desired, screen.frame))
        }
        let connected = Set(screens.map(\.id))
        for (id, current) in state.sorted(by: { $0.key < $1.key })
        where !connected.contains(id) && (current.active != nil || current.pending != nil) {
            actions.append(.disconnect(id))
        }
        return actions
    }
}
