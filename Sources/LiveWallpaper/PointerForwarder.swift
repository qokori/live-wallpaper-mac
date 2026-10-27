import AppKit
import WallpaperCore

/// Interactive web wallpapers. The wallpaper window stays click-through (the Finder icons sit above it and must
/// keep working), so pointer events are watched globally and passed to the page when the pointer is on the bare
/// desktop. A click on the desktop therefore reaches both Finder and the page.
@MainActor
final class PointerForwarder {
    var targets: () -> [(bounds: CGRect, content: WebContent)] = { [] }

    private var monitor: Any?
    private var windows: [DesktopPointer.Window] = []
    private var windowsTime: TimeInterval = 0
    private var lastMove: TimeInterval = 0
    private var pressed: WebContent?

    func setEnabled(_ enabled: Bool) {
        if enabled, monitor == nil {
            // Mouse events need no Accessibility permission (only key events do).
            monitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .leftMouseDown, .leftMouseUp]) { [weak self] event in
                let type = event.type
                MainActor.assumeIsolated { self?.handle(type) }
            }
        } else if !enabled, let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
            pressed = nil
        }
    }

    private func handle(_ type: NSEvent.EventType) {
        let now = ProcessInfo.processInfo.systemUptime
        let kind: WebPageScript.PointerKind = switch type {
        case .leftMouseDown: .down
        case .leftMouseUp: .up
        default: .move
        }
        if kind == .move {
            // Pages draw at most 60 frames a second; more pointer updates would only cost CPU.
            guard now - lastMove >= 1.0 / 60 else { return }
            lastMove = now
        }
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let point = DesktopPointer.cgPoint(fromAppKit: NSEvent.mouseLocation, mainScreenHeight: mainHeight)
        guard let target = targets().first(where: { $0.bounds.contains(point) }),
              let pagePoint = DesktopPointer.pagePoint(point, windowBounds: target.bounds) else { return }
        if kind == .up {
            // A press that started on the desktop ends there, even when released over a window.
            guard pressed === target.content else { return }
            pressed = nil
        } else {
            guard DesktopPointer.isOnDesktop(point, windows: windowsAbove(now)) else { return }
            if kind == .down { pressed = target.content }
        }
        target.content.forward(kind, at: pagePoint)
    }

    /// App windows, panels, Dock and menu bar on screen; cached briefly because the list is not free to build.
    private func windowsAbove(_ now: TimeInterval) -> [DesktopPointer.Window] {
        guard now - windowsTime > 0.25 else { return windows }
        windowsTime = now
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        windows = list.compactMap { info in
            guard (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  let dictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary)
            else { return nil }
            return DesktopPointer.Window(layer: layer, bounds: bounds)
        }
        return windows
    }
}
