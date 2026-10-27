// Opens a window, switches it to native fullscreen for N seconds (default 8), then leaves fullscreen and exits.
// Run next to `LW_DIAG=1 LiveWallpaper` and look for "pause [occluded]" / "play" in its log.
import AppKit

let seconds = Double(CommandLine.arguments.dropFirst().first ?? "") ?? 8
func stamp(_ text: String) { print(String(format: "%.3f ", ProcessInfo.processInfo.systemUptime) + text) }

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let window = NSWindow(
    contentRect: NSRect(x: 200, y: 200, width: 640, height: 400),
    styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
)
window.title = "Fullscreen probe"
window.collectionBehavior = [.fullScreenPrimary]
window.backgroundColor = .systemTeal
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
for (name, text) in [
    (NSWindow.didEnterFullScreenNotification, "entered fullscreen"),
    (NSWindow.didExitFullScreenNotification, "left fullscreen"),
] {
    NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { _ in stamp("probe: \(text)") }
}

DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
    stamp("probe: enter fullscreen")
    window.toggleFullScreen(nil)
}
DispatchQueue.main.asyncAfter(deadline: .now() + 1 + seconds) {
    stamp("probe: leave fullscreen")
    window.toggleFullScreen(nil)
}
DispatchQueue.main.asyncAfter(deadline: .now() + 6 + seconds) {
    stamp("probe: exit")
    app.terminate(nil)
}
app.run()
