import AppKit
import SwiftUI
import WallpaperCore

@main
struct LiveWallpaperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: delegate.model)
        } label: {
            Image(systemName: delegate.model.isPlaying ? "play.rectangle.fill" : "play.rectangle")
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

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
        model.start()
        applyCommandLine()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
    }

    /// `--video <file>` and `--web <address, folder or .html>` set all screens; `--video-for` / `--web-for <display UUID> …`
    /// set one screen; `--fps 30|60` sets the web frame rate.
    private func applyCommandLine() {
        let arguments = CommandLine.arguments
        func value(after flag: String, offset: Int = 1) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + offset < arguments.count else { return nil }
            return arguments[index + offset]
        }
        if let fps = value(after: "--fps").flatMap(Int.init), fps == 30 || fps == 60 { model.webFrameRate = fps }
        if let path = value(after: "--video") { model.setSource(Self.video(path), forDisplay: nil) }
        if let target = value(after: "--web") { model.setSource(Self.web(target), forDisplay: nil) }
        if let display = value(after: "--video-for"), let path = value(after: "--video-for", offset: 2) {
            model.setSource(Self.video(path), forDisplay: display)
        }
        if let display = value(after: "--web-for"), let target = value(after: "--web-for", offset: 2) {
            model.setSource(Self.web(target), forDisplay: display)
        }
    }

    private static func video(_ path: String) -> WallpaperSource {
        let url = URL(filePath: path)
        return WallpaperSource(kind: .video, location: url.path, bookmark: try? url.bookmarkData())
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
