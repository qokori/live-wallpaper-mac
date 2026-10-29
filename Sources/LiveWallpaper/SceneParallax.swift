import AppKit
import WallpaperCore

/// Parallax of Wallpaper Engine scenes: the pointer's place on each screen with a scene that asks for it. Watched
/// globally (no permission needed), at most 60 times a second, and only while such a scene is playing.
@MainActor
final class SceneParallax {
    var targets: () -> [(bounds: CGRect, content: WebContent)] = { [] }

    private var monitor: Any?
    private var lastMove: TimeInterval = 0

    /// Starts or stops watching to match what is on screen.
    func refresh() {
        let needed = targets().contains { $0.content.isPlaying }
        if needed, monitor == nil {
            monitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]) { [weak self] _ in
                MainActor.assumeIsolated { self?.moved() }
            }
            moved(force: true)
        } else if !needed, let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func moved(force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastMove >= 1.0 / 60 else { return }
        lastMove = now
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let point = DesktopPointer.cgPoint(fromAppKit: NSEvent.mouseLocation, mainScreenHeight: mainHeight)
        for target in targets() where target.content.isPlaying {
            target.content.setScenePointer(DesktopPointer.normalizedPoint(point, windowBounds: target.bounds))
        }
    }
}
