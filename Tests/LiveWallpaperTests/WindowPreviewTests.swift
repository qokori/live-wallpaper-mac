import AppKit
import SwiftUI
import Testing
import WallpaperCore
@testable import LiveWallpaper

/// Draws the main window into an offscreen bitmap (no window is shown) and checks it is not blank.
/// With LW_PREVIEW_DIR set, the pictures are also written there as PNG.
@MainActor
@Suite struct WindowPreviewTests {
    private static func picture(hue: CGFloat, shapes: Int) -> NSImage {
        NSImage(size: NSSize(width: 640, height: 400), flipped: false) { rect in
            NSGradient(colors: [NSColor(hue: hue, saturation: 0.7, brightness: 0.95, alpha: 1), NSColor(hue: hue + 0.12, saturation: 0.8, brightness: 0.35, alpha: 1)])?
                .draw(in: rect, angle: 35)
            NSColor.white.withAlphaComponent(0.18).setFill()
            for i in 0..<shapes {
                let r = CGFloat(40 + i * 28)
                NSBezierPath(ovalIn: NSRect(x: 80 + CGFloat(i) * 90, y: 60 + CGFloat(i % 3) * 70, width: r, height: r)).fill()
            }
            return true
        }
    }

    private func fixture() throws -> (AppModel, Thumbnails, Sandbox) {
        let box = Sandbox()
        let model = box.model()
        let thumbnails = Thumbnails()
        let items: [(String, String, WallpaperSource.Kind, CGFloat)] = [
            ("Дождь над городом.mp4", "rain.mp4", .video, 0.58),
            ("Северное сияние.mov", "aurora.mov", .video, 0.42),
            ("Закат.mp4", "sunset.mp4", .video, 0.04),
            ("Волны (WebGL)", "waves", .web, 0.52),
            ("Частицы", "particles", .web, 0.75),
            ("Лес.mp4", "forest.mp4", .video, 0.30),
        ]
        var sources: [WallpaperSource] = []
        for (_, file, kind, _) in items {
            if kind == .video {
                sources.append(WallpaperSource(kind: .video, location: try box.file(file).path))
            } else {
                let folder = box.directory.appending(path: file)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try Data().write(to: folder.appending(path: "index.html"))
                sources.append(WallpaperSource(kind: .web, location: folder.path))
            }
        }
        for (index, source) in sources.enumerated() {
            let item = model.library.add(source)
            model.library.rename(id: item.id, to: String(items[index].0.split(separator: ".").first ?? ""))
            thumbnails.set(Self.picture(hue: items[index].3, shapes: 3 + index), for: item.id)
        }
        let remote = model.library.add(WallpaperSource(kind: .web, location: "https://shader.example.com/clouds"))
        model.library.rename(id: remote.id, to: "Облака (по адресу)")
        model.apply(sources[0], to: .all)
        model.apply(sources[3], to: .display("DELL"))
        model.screens = [
            ScreenStatus(id: "BUILTIN", name: "Встроенный дисплей Liquid Retina", source: sources[0], playing: true, reasons: []),
            ScreenStatus(id: "DELL", name: "DELL U2723QE", source: sources[3], playing: false, reasons: [.occluded]),
        ]
        return (model, thumbnails, box)
    }

    private func render(_ tab: MainTab, model: AppModel, thumbnails: Thumbnails) throws -> NSBitmapImageRep {
        let size = NSSize(width: 940, height: 640)
        let view = NSHostingView(rootView: MainView(model: model, thumbnails: thumbnails, tab: tab, pick: { _ in }))
        view.frame = NSRect(origin: .zero, size: size)
        view.appearance = NSAppearance(named: .aqua)
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    /// Distinct colours in a coarse sample: a blank or one-colour picture has one or two.
    private func colourCount(_ bitmap: NSBitmapImageRep) -> Int {
        var seen = Set<UInt32>()
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 7) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 7) {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                seen.insert(UInt32(c.redComponent * 31) << 10 | UInt32(c.greenComponent * 31) << 5 | UInt32(c.blueComponent * 31))
            }
        }
        return seen.count
    }

    @Test(arguments: MainTab.allCases)
    func everyTabDrawsSomething(_ tab: MainTab) throws {
        let (model, thumbnails, box) = try fixture()
        defer { box.cleanup() }
        let bitmap = try render(tab, model: model, thumbnails: thumbnails)
        #expect(bitmap.pixelsWide >= 940)
        #expect(colourCount(bitmap) > 12)
        if let dir = ProcessInfo.processInfo.environment["LW_PREVIEW_DIR"] {
            let name = ["Библиотека": "library", "Экраны": "screens", "Настройки": "settings"][tab.rawValue] ?? tab.rawValue
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(filePath: dir).appending(path: "window-\(name).png"))
        }
    }

    @Test func emptyLibraryDrawsItsHint() throws {
        let box = Sandbox()
        defer { box.cleanup() }
        let bitmap = try render(.library, model: box.model(), thumbnails: Thumbnails())
        #expect(colourCount(bitmap) > 6)
    }
}
