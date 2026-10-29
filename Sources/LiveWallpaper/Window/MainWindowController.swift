import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WallpaperCore

enum PickKind {
    case video
    case gif
    case webPage
    /// A Wallpaper Engine project: its folder, a scene `.pkg` or its `project.json`.
    case engine
}

/// The main window. While it is open the app has a Dock icon (activation policy regular); closed, it is a menu bar
/// app again. File choosers are sheets on this window: nothing here runs a modal loop, so no menu action can hang.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private let thumbnails = Thumbnails()
    private var window: NSWindow?

    init(model: AppModel) {
        self.model = model
    }

    var isOpen: Bool { window?.isVisible ?? false }

    func show() {
        NSApp.setActivationPolicy(.regular)
        NSApp.applicationIconImage = AppIcon.image
        let window = window ?? makeWindow()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    private func makeWindow() -> NSWindow {
        let root = MainView(model: model, thumbnails: thumbnails, pick: { [weak self] in self?.pick($0) })
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Live Wallpaper"
        window.contentMinSize = NSSize(width: 780, height: 520)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: root)
        window.setFrameAutosaveName("LiveWallpaperMain")
        if window.frame.origin == .zero { window.center() }
        return window
    }

    /// A file chooser as a sheet on the window (not `runModal`); the chosen files go to the library.
    private func pick(_ kind: PickKind) {
        let panel = NSOpenPanel()
        switch kind {
        case .video:
            panel.allowedContentTypes = [.movie]
            panel.allowsMultipleSelection = true
            panel.message = "Видео (mp4, mov, HEVC)"
        case .gif:
            panel.allowedContentTypes = [.gif, .png]
            panel.allowsMultipleSelection = true
            panel.message = "Анимация (GIF или APNG)"
        case .webPage:
            panel.canChooseDirectories = true
            panel.allowedContentTypes = [.html]
            panel.message = "Папка с index.html или файл .html"
        case .engine:
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = true
            panel.allowedContentTypes = [.json] + (UTType(filenameExtension: "pkg").map { [$0] } ?? [])
            panel.message = "Папка проекта Wallpaper Engine, пакет .pkg или project.json (сцены пока показываются превью)"
        }
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self, panel] response in
            guard response == .OK else { return }
            let urls = panel.urls
            self?.add(urls)
        }
        if let window, window.isVisible {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }

    func add(_ urls: [URL]) {
        Task {
            for url in urls {
                let kind = WallpaperSource.Kind.detect(url: url)
                await model.addToLibrary(WallpaperSource(kind: kind, location: url.path, bookmark: try? url.bookmarkData()))
            }
        }
    }
}

/// The Dock icon while the window is open: the bundled icon, or the logo drawn on the spot outside an .app.
enum AppIcon {
    @MainActor static let image: NSImage = {
        // The bundled icon (scripts/make-icon.swift) when running from the .app; the same drawing otherwise.
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"), let bundled = NSImage(contentsOf: url) {
            return bundled
        }
        return Logo.icon(size: 512)
    }()
}
