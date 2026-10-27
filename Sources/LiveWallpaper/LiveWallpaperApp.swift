import AppKit
import SwiftUI

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

    /// `--video <file>` sets the video for all screens; `--video-for <display UUID> <file>` for one screen.
    private func applyCommandLine() {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--video"), index + 1 < arguments.count {
            model.setVideo(URL(filePath: arguments[index + 1]), forDisplay: nil)
        }
        if let index = arguments.firstIndex(of: "--video-for"), index + 2 < arguments.count {
            model.setVideo(URL(filePath: arguments[index + 2]), forDisplay: arguments[index + 1])
        }
    }
}
