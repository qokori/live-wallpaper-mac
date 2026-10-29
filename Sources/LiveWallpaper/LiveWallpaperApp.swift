import AppKit
import SwiftUI
import WallpaperCore
import WallpaperEngineKit

@main
struct LiveWallpaperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: delegate.model, openWindow: { delegate.showWindow() })
        } label: {
            Image(systemName: delegate.model.isPlaying ? "play.rectangle.fill" : "play.rectangle")
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private lazy var window = MainWindowController(model: model)

    func showWindow() {
        window.show()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Menu bar only, also when started outside the bundle (LSUIElement covers the bundled case).
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `--restore-wallpaper`: put back the desktop pictures from before the first frame was applied, then quit.
        if CommandLine.arguments.contains("--restore-wallpaper") {
            model.restoreSystemWallpaper()
            NSApp.terminate(nil)
            return
        }
        // `--we-inspect <folder, project.json or .pkg>`: print what the project holds, then quit.
        if let target = Self.value(after: "--we-inspect") {
            Self.inspectEngineProject(target)
            NSApp.terminate(nil)
            return
        }
        model.start()
        applyCommandLine()
        // Opened from Applications or the Dock: show the window. At login or from the command line: stay in the menu bar.
        if !Self.launchedInBackground { window.show() }
        model.onNotice = { [weak self] in
            guard let self, !self.window.isOpen else { return }
            self.window.show()
        }
    }

    /// Clicking the app in Applications or the Dock while it runs.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window.show()
        return true
    }

    private static var launchedInBackground: Bool {
        let flags = ["--video", "--web", "--video-for", "--web-for", "--we", "--we-for", "--fps"]
        if CommandLine.arguments.contains(where: flags.contains) { return true }
        let event = NSAppleEventManager.shared().currentAppleEvent
        return event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == AEEventClass(keyAELaunchedAsLogInItem)
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
    }

    private static func value(after flag: String, offset: Int = 1) -> String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: flag), index + offset < arguments.count else { return nil }
        return arguments[index + offset]
    }

    private static func inspectEngineProject(_ path: String) {
        let url = URL(filePath: (path as NSString).expandingTildeInPath)
        do {
            print(try EngineInspector.report(for: url))
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
        }
    }

    /// `--video <file>` (a video, or a .gif / .apng) and `--web <address, folder or .html>` set all screens; `--video-for` / `--web-for <display UUID> …`
    /// set one screen; `--we <folder, project.json or .pkg>` and `--we-for <display UUID> …` do the same for a Wallpaper Engine project;
    /// `--fps 15|30|60` sets the frame rate of scenes and web pages, `--quality economy|screen|maximum` how large scenes are drawn.
    private func applyCommandLine() {
        func value(after flag: String, offset: Int = 1) -> String? { Self.value(after: flag, offset: offset) }
        if let fps = value(after: "--fps").flatMap(Int.init), RenderQuality.frameRates.contains(fps) { model.webFrameRate = fps }
        if let quality = value(after: "--quality").flatMap(RenderQuality.init(rawValue:)) { model.renderQuality = quality }
        if let path = value(after: "--video") { model.setSource(Self.video(path), forDisplay: nil) }
        if let target = value(after: "--web") { model.setSource(Self.web(target), forDisplay: nil) }
        if let path = value(after: "--we") { model.setSource(Self.engine(path), forDisplay: nil) }
        if let display = value(after: "--we-for"), let path = value(after: "--we-for", offset: 2) {
            model.setSource(Self.engine(path), forDisplay: display)
        }
        if let display = value(after: "--video-for"), let path = value(after: "--video-for", offset: 2) {
            model.setSource(Self.video(path), forDisplay: display)
        }
        if let display = value(after: "--web-for"), let target = value(after: "--web-for", offset: 2) {
            model.setSource(Self.web(target), forDisplay: display)
        }
    }

    private static func video(_ path: String) -> WallpaperSource {
        let url = URL(filePath: path)
        let kind = WallpaperSource.Kind.detect(path: url.path, isDirectory: false)
        return WallpaperSource(kind: kind == .gif ? .gif : .video, location: url.path, bookmark: try? url.bookmarkData())
    }

    private static func engine(_ path: String) -> WallpaperSource {
        let url = URL(filePath: (path as NSString).expandingTildeInPath)
        return WallpaperSource(kind: .wallpaperEngine, location: url.path, bookmark: try? url.bookmarkData())
    }

    /// An existing path is a local page; anything else is treated as a web address.
    private static func web(_ target: String) -> WallpaperSource {
        let url = URL(filePath: (target as NSString).expandingTildeInPath)
        if FileManager.default.fileExists(atPath: url.path) {
            return WallpaperSource(kind: .web, location: url.path, bookmark: try? url.bookmarkData())
        }
        return WallpaperSource(kind: .web, location: WebAddress.normalize(target)?.absoluteString ?? target)
    }
}
