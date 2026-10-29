import AppKit
import Foundation
import Testing
import WallpaperCore
import WallpaperEngineKit
import WebKit
@testable import LiveWallpaper

/// A scene drawn in a web view that is not on screen, read back as pixels.
@MainActor
final class SceneProbe {
    let web: WebContent
    let webView: WKWebView
    let window: NSWindow
    let size: CGSize

    init(folder: URL, size: CGSize = CGSize(width: 200, height: 120), frameRate: Int = 30, quality: RenderQuality = .maximum) throws {
        let item = try EngineSupport.open(folder)
        let assets = try EngineSupport.sceneAssets(item)
        web = WebContent(target: .scene(assets), frameRate: frameRate, quality: quality, label: "test")
        self.size = size
        window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = web.view
        web.view.frame = CGRect(origin: .zero, size: size)
        webView = web.view.subviews.compactMap { $0 as? WKWebView }.first!
    }

    /// Loads the scene and waits until it has drawn once.
    func load(playing: Bool = true) async throws {
        var ready = false
        var failure: Error?
        web.start(ready: { ready = true }, failed: { failure = $0 })
        for _ in 0..<400 where !ready && failure == nil { try await Task.sleep(for: .milliseconds(50)) }
        if let failure { throw failure }
        #expect(ready, "сцена не нарисована")
        web.setPlaying(playing)
        try await Task.sleep(for: .milliseconds(150))
    }

    func status() async throws -> [String: Any] {
        let text = try await webView.evaluateJavaScript("window.__lwScene.status()") as? String ?? "{}"
        return (try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:]
    }

    func snapshot() async throws -> Pixels {
        let image = try await webView.takeSnapshot(configuration: nil)
        return try #require(Pixels(image, width: Int(size.width), height: Int(size.height)))
    }

    /// Runs the page's loop by hand: an unseen window gets no animation frames.
    func step(_ seconds: Double = 0.5) async throws {
        _ = try await webView.evaluateJavaScript("window.__lwScene.step(\(seconds))")
    }

    func close() {
        web.stop()
    }
}

/// RGBA pixels of a picture drawn at a fixed size, top row first.
struct Pixels {
    let width: Int
    let height: Int
    let data: [UInt8]

    init?(_ image: NSImage, width: Int, height: Int) {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.interpolationQuality = .high
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let pointer = context.data else { return nil }
        self.width = width
        self.height = height
        data = Array(UnsafeBufferPointer(start: pointer.assumingMemoryBound(to: UInt8.self), count: width * height * 4))
    }

    /// The colour at a place given as 0...1 from the top left.
    func at(_ x: Double, _ y: Double) -> [Int] {
        let px = min(max(Int(x * Double(width)), 0), width - 1)
        let py = min(max(Int(y * Double(height)), 0), height - 1)
        let o = (py * width + px) * 4
        return [Int(data[o]), Int(data[o + 1]), Int(data[o + 2])]
    }
}

func near(_ a: [Int], _ b: [Int], tolerance: Int = 6) -> Bool {
    zip(a, b).allSatisfy { abs($0 - $1) <= tolerance }
}

@MainActor
@Suite(.serialized) struct SceneRenderTests {
    private func folder() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "lw-scene-\(UUID().uuidString)")
    }

    @Test func layersAreDrawnInOrderOnTheClearColour() async throws {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try EngineFixtures.scene(in: dir, layers: [
            .init(name: "красный", texture: EngineFixtures.solid(1, 0, 0), origin: "25 30 0", size: "50 60"),
            .init(name: "зелёный", texture: EngineFixtures.solid(0, 1, 0), origin: "75 30 0", size: "50 60", alpha: 0.5),
        ])
        let probe = try SceneProbe(folder: dir)
        defer { probe.close() }
        try await probe.load()
        let pixels = try await probe.snapshot()
        #expect(near(pixels.at(0.25, 0.5), [255, 0, 0]), "\(pixels.at(0.25, 0.5))")
        // Half-transparent green over the grey clear colour (0.5): 0.5 * 0 + 0.5 * 0.5 and 0.5 * 255 + 0.5 * 128.
        #expect(near(pixels.at(0.75, 0.5), [64, 191, 64], tolerance: 10), "\(pixels.at(0.75, 0.5))")
    }

    @Test func multiplyAndScreenModes() async throws {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try EngineFixtures.scene(in: dir, layers: [
            .init(name: "основа", texture: EngineFixtures.solid(1, 0.5, 0), origin: "50 30 0", size: "100 60"),
            .init(name: "умножение", texture: EngineFixtures.solid(0.5, 0.5, 0.5), origin: "25 30 0", size: "50 60", blendMode: 1),
            .init(name: "экран", texture: EngineFixtures.solid(0, 0, 1), origin: "75 30 0", size: "50 60", blendMode: 31),
        ])
        let probe = try SceneProbe(folder: dir)
        defer { probe.close() }
        try await probe.load()
        let pixels = try await probe.snapshot()
        #expect(near(pixels.at(0.25, 0.5), [128, 64, 0], tolerance: 8), "умножение \(pixels.at(0.25, 0.5))")
        #expect(near(pixels.at(0.75, 0.5), [255, 128, 255], tolerance: 8), "экран \(pixels.at(0.75, 0.5))")
        #expect((try await probe.status())["unknownModes"] as? [Int] == [])
    }

    @Test func unknownBlendModesAreListedAndDrawnAsNormal() async throws {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try EngineFixtures.scene(in: dir, layers: [
            .init(name: "x", texture: EngineFixtures.solid(0, 0, 1), blendMode: 7),
        ])
        let probe = try SceneProbe(folder: dir)
        defer { probe.close() }
        try await probe.load()
        let pixels = try await probe.snapshot()
        #expect(near(pixels.at(0.5, 0.5), [0, 0, 255]))
        #expect((try await probe.status())["unknownModes"] as? [Int] == [7])
    }

    @Test func parallaxShiftsLayersWithThePointer() async throws {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        // A 20 wide white bar in the middle of a 100 wide scene. Amount 0.1, influence 1, so the bar moves by
        // 2 * 0.1 * 1 * 100 * 0.5 = 10 scene units (a tenth of the width) when the pointer is at the right edge.
        _ = try EngineFixtures.scene(
            in: dir, layers: [.init(name: "полоса", texture: EngineFixtures.solid(1, 1, 1), origin: "50 30 0", size: "20 60")],
            clear: "0 0 0", parallax: "true", amount: 0.1, delay: 0, influence: 1
        )
        let probe = try SceneProbe(folder: dir)
        defer { probe.close() }
        try await probe.load()
        probe.web.setScenePointer(CGPoint(x: 0.5, y: 0.5))
        try await probe.step()
        var pixels = try await probe.snapshot()
        #expect(near(pixels.at(0.5, 0.5), [255, 255, 255]), "в покое \(pixels.at(0.5, 0.5))")
        #expect(near(pixels.at(0.35, 0.5), [0, 0, 0]))
        probe.web.setScenePointer(CGPoint(x: 1, y: 0.5))
        try await probe.step()
        pixels = try await probe.snapshot()
        #expect(near(pixels.at(0.4, 0.5), [255, 255, 255]), "сдвиг влево \(pixels.at(0.4, 0.5))")
        #expect(near(pixels.at(0.55, 0.5), [0, 0, 0]), "справа пусто \(pixels.at(0.55, 0.5))")
    }

    @Test func depthZeroKeepsALayerStill() async throws {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try EngineFixtures.scene(
            in: dir, layers: [.init(name: "полоса", texture: EngineFixtures.solid(1, 1, 1), origin: "50 30 0", size: "20 60", depth: "0 0")],
            clear: "0 0 0", parallax: "true", amount: 0.1, delay: 0, influence: 1
        )
        let probe = try SceneProbe(folder: dir)
        defer { probe.close() }
        try await probe.load()
        probe.web.setScenePointer(CGPoint(x: 1, y: 0))
        try await probe.step()
        let pixels = try await probe.snapshot()
        #expect(near(pixels.at(0.5, 0.5), [255, 255, 255]))
        #expect(near(pixels.at(0.4, 0.5), [255, 255, 255]) == false)
    }

    @Test func fitLeavesBlackBarsAndFillCrops() async throws {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try EngineFixtures.scene(in: dir, layers: [.init(name: "белый", texture: EngineFixtures.solid(1, 1, 1))], clear: "1 1 1")
        // A window twice as wide as the 100x60 scene.
        let probe = try SceneProbe(folder: dir, size: CGSize(width: 240, height: 72))
        defer { probe.close() }
        try await probe.load()
        probe.web.setSceneScaling(.fit)
        try await Task.sleep(for: .milliseconds(300))
        var pixels = try await probe.snapshot()
        #expect(near(pixels.at(0.5, 0.5), [255, 255, 255]))
        #expect(near(pixels.at(0.05, 0.5), [0, 0, 0]), "поля при вписывании \(pixels.at(0.05, 0.5))")
        probe.web.setSceneScaling(.fill)
        try await Task.sleep(for: .milliseconds(300))
        pixels = try await probe.snapshot()
        #expect(near(pixels.at(0.05, 0.5), [255, 255, 255]), "заполнение \(pixels.at(0.05, 0.5))")
    }

    @Test func videoLayerPlaysWithoutSound() async throws {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let mp4 = dir.appending(path: "clip.mp4")
        try await TestVideo.write(mp4, fill: 255)
        let bytes = [UInt8](try Data(contentsOf: mp4))
        _ = try EngineFixtures.scene(in: dir, layers: [
            .init(name: "видео", texture: EngineFixtures.tex(width: 64, height: 48, bytes: bytes, flags: 35)),
        ])
        let item = try EngineSupport.open(dir)
        let assets = try EngineSupport.sceneAssets(item)
        #expect(assets.textures.first?.kind == "video")
        let probe = try SceneProbe(folder: dir)
        defer { probe.close() }
        try await probe.load()
        let status = try await probe.status()
        #expect(status["videos"] as? Int == 1)
        #expect((status["failed"] as? [String]) == [], "\(status)")
        #expect(status["muted"] as? Bool == true)
        // The picture is the video's (a white 64x48 clip), not the grey clear colour.
        let pixels = try await probe.snapshot()
        #expect(near(pixels.at(0.5, 0.5), [255, 255, 255], tolerance: 25), "\(pixels.at(0.5, 0.5))")
    }

    /// A paused wallpaper (covered by windows, display asleep, locked) stops its video layers, and resuming carries on
    /// in the same page: the scene is not loaded again.
    @Test func pausingStopsVideoLayersAndResumingDoesNotReloadTheScene() async throws {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let mp4 = dir.appending(path: "clip.mp4")
        try await TestVideo.write(mp4, fill: 255)
        _ = try EngineFixtures.scene(in: dir, layers: [
            .init(name: "видео", texture: EngineFixtures.tex(width: 64, height: 48, bytes: [UInt8](try Data(contentsOf: mp4)), flags: 35)),
        ])
        let probe = try SceneProbe(folder: dir)
        defer { probe.close() }
        try await probe.load(playing: false)
        // Loaded paused: the video is not playing.
        #expect(try await probe.status()["videosPlaying"] as? Int == 0)
        _ = try await probe.webView.evaluateJavaScript("window.__lwScene.marker = 'same page'")
        probe.web.setPlaying(true)
        try await Task.sleep(for: .milliseconds(300))
        // An unseen window gets no animation frames: the loop is started by hand, as the other render tests do.
        try await probe.step(0.1)
        #expect(try await probe.status()["videosPlaying"] as? Int == 1)
        probe.web.setPlaying(false)
        try await Task.sleep(for: .milliseconds(300))
        #expect(try await probe.status()["videosPlaying"] as? Int == 0, "пауза должна остановить видеослои")
        probe.web.setPlaying(true)
        try await Task.sleep(for: .milliseconds(300))
        try await probe.step(0.1)
        #expect(try await probe.status()["videosPlaying"] as? Int == 1, "после паузы видео идёт дальше")
        let marker = try await probe.webView.evaluateJavaScript("window.__lwScene.marker") as? String
        #expect(marker == "same page", "сцена не должна загружаться заново")
    }

    /// A picture of `side` pixels: red top left, green top right, blue bottom left, white bottom right.
    private func quadrantScene(_ dir: URL, side: Int = 1024) throws {
        var bytes = [UInt8](repeating: 255, count: side * side * 4)
        for y in 0..<side {
            for x in 0..<side {
                let o = (y * side + x) * 4
                let right = x >= side / 2, bottom = y >= side / 2
                (bytes[o], bytes[o + 1], bytes[o + 2]) = switch (right, bottom) {
                case (false, false): (255, 0, 0)
                case (true, false): (0, 255, 0)
                case (false, true): (0, 0, 255)
                case (true, true): (255, 255, 255)
                }
            }
        }
        _ = try EngineFixtures.scene(in: dir, layers: [.init(name: "четверти", texture: EngineFixtures.tex(width: side, height: side, bytes: bytes))])
    }

    /// The sizes of the bitmaps the page made, by what `status.reduced` says.
    private func reducedSizes(_ status: [String: Any]) -> [[Int]] {
        (status["reduced"] as? [[String: Any]] ?? []).map { [$0["w"] as? Int ?? 0, $0["h"] as? Int ?? 0] }
    }

    @Test func economyHalvesPicturesAndMaximumLeavesThem() async throws {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try quadrantScene(dir)
        let maximum = try SceneProbe(folder: dir, quality: .maximum)
        defer { maximum.close() }
        try await maximum.load()
        #expect(reducedSizes(try await maximum.status()).isEmpty)
        let full = try await maximum.snapshot()
        let economy = try SceneProbe(folder: dir, quality: .economy)
        defer { economy.close() }
        try await economy.load()
        let status = try await economy.status()
        #expect(status["quality"] as? String == "economy")
        // The bitmap that went to the graphics card is 512x512 (half of 1024, which is also the 512-pixel floor).
        #expect(reducedSizes(status) == [[512, 512]], "\(status)")
        // The reduced picture shows the same quarters in the same places (a flipped or shifted one would not).
        let small = try await economy.snapshot()
        for (x, y) in [(0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75)] {
            #expect(near(small.at(x, y), full.at(x, y), tolerance: 20), "\(x),\(y): \(small.at(x, y)) вместо \(full.at(x, y))")
        }
        #expect(near(full.at(0.25, 0.25), [255, 0, 0], tolerance: 20) && near(full.at(0.75, 0.75), [255, 255, 255], tolerance: 20))
    }

    /// The limits worked out by the page, read from the bitmaps it made (800 pixels: the 200x120 canvas is under the 512 floor).
    @Test func eachLevelReducesPicturesToItsLimit() async throws {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try quadrantScene(dir, side: 800)
        var made: [RenderQuality: [[Int]]] = [:]
        for quality in RenderQuality.allCases {
            let probe = try SceneProbe(folder: dir, quality: quality)
            defer { probe.close() }
            try await probe.load()
            made[quality] = reducedSizes(try await probe.status())
        }
        #expect(made[.economy] == [[400, 400]], "половина, она меньше предела 512")
        #expect(made[.screen] == [[512, 512]], "до предела 512: холст меньше")
        #expect(made[.maximum] == [])
        // Pictures of 64 pixels or less are never reduced.
        let tiny = folder()
        defer { try? FileManager.default.removeItem(at: tiny) }
        try quadrantScene(tiny, side: 64)
        let probe = try SceneProbe(folder: tiny, quality: .economy)
        defer { probe.close() }
        try await probe.load()
        #expect(reducedSizes(try await probe.status()).isEmpty)
    }

    @Test func screenQualityNeverTouchesVideo() async throws {
        // A video larger than the 512-pixel floor: if it went through the picture limit, it would show up in `reduced`.
        let video = folder()
        defer { try? FileManager.default.removeItem(at: video) }
        try FileManager.default.createDirectory(at: video, withIntermediateDirectories: true)
        let mp4 = video.appending(path: "clip.mp4")
        try await TestVideo.write(mp4, fill: 255, width: 640, height: 480)
        _ = try EngineFixtures.scene(in: video, layers: [
            .init(name: "видео", texture: EngineFixtures.tex(width: 640, height: 480, bytes: [UInt8](try Data(contentsOf: mp4)), flags: 35)),
        ])
        let clip = try SceneProbe(folder: video, size: CGSize(width: 16, height: 12), quality: .economy)
        defer { clip.close() }
        try await clip.load()
        let status = try await clip.status()
        #expect(reducedSizes(status).isEmpty && status["videos"] as? Int == 1, "видео не уменьшается: \(status)")
        #expect(near(try await clip.snapshot().at(0.5, 0.5), [255, 255, 255], tolerance: 30))
    }

    @Test func changingTheQualityReloadsTheScenePageAndHidesTheOldPictureWhenItIsDrawn() async throws {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try quadrantScene(dir)
        let probe = try SceneProbe(folder: dir, quality: .maximum)
        defer { probe.close() }
        try await probe.load()
        probe.web.setQuality(.economy)
        var status: [String: Any] = [:]
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(100))
            status = (try? await probe.status()) ?? [:]
            if status["quality"] as? String == "economy", !reducedSizes(status).isEmpty { break }
        }
        #expect(status["quality"] as? String == "economy" && reducedSizes(status) == [[512, 512]], "\(status)")
        try await Task.sleep(for: .milliseconds(300))
        #expect(probe.web.snapshotView.isHidden && !probe.webView.isHidden, "после перерисовки снимок старой картинки убран")
    }

    /// A quality asked for while the first page is still loading is not lost.
    @Test func aQualityAskedForWhileTheFirstPageLoadsIsUsed() async throws {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try quadrantScene(dir)
        let probe = try SceneProbe(folder: dir, quality: .maximum)
        defer { probe.close() }
        var ready = false
        probe.web.start(ready: { ready = true }, failed: { _ in })
        probe.web.setQuality(.economy)
        for _ in 0..<200 where !ready { try await Task.sleep(for: .milliseconds(50)) }
        try await Task.sleep(for: .milliseconds(500))
        let status = try await probe.status()
        #expect(status["quality"] as? String == "economy" && reducedSizes(status) == [[512, 512]], "\(status)")
    }

    /// A reloaded page that fails gives the screen the quality that worked.
    @Test func aFailedQualityReloadGoesBackToTheOldQuality() async throws {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try quadrantScene(dir)
        let probe = try SceneProbe(folder: dir, quality: .maximum)
        defer { probe.close() }
        try await probe.load()
        probe.web.setQuality(.economy)
        #expect(probe.web.reloadFailed("тест"))
        #expect(probe.web.currentQuality == .maximum)
        #expect(!probe.web.reloadFailed("ещё раз"), "откат один: вторая ошибка не по кругу")
        try await Task.sleep(for: .milliseconds(1500))
        let status = try await probe.status()
        #expect(status["quality"] as? String == "maximum" && reducedSizes(status).isEmpty, "\(status)")
        #expect(!probe.webView.isHidden)
    }
}
