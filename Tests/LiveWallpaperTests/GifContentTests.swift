import AppKit
import Foundation
import Testing
import WallpaperCore
@testable import LiveWallpaper

/// The GIF layer on its own: no window is created, so nothing reaches the screen.
@MainActor
@Suite struct GifContentTests {
    private func wait(_ seconds: Double, until condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    }

    private func started(_ url: URL) async -> (GifContent, ready: Bool, error: Error?) {
        let content = GifContent(url: url, label: "test")
        var ready = false
        var error: Error?
        content.start(ready: { ready = true }, failed: { error = $0 })
        await wait(2) { ready || error != nil }
        return (content, ready, error)
    }

    @Test func showsTheFirstFrameWhenReady() async throws {
        let dir = try TestImages.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "a.gif")
        try TestImages.write(url, delays: [0.05, 0.05, 0.05])
        let (content, ready, error) = await started(url)
        defer { content.stop() }
        #expect(ready)
        #expect(error == nil)
        #expect(content.view.layer?.contents != nil)
    }

    @Test func playsFramesInTurnAndStopsOnPause() async throws {
        let dir = try TestImages.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "a.gif")
        try TestImages.write(url, delays: [0.05, 0.05, 0.05])
        let (content, _, _) = await started(url)
        defer { content.stop() }
        let layer = try #require(content.view.layer)
        var seen = Set<ObjectIdentifier>()
        func note() { if let image = layer.contents { seen.insert(ObjectIdentifier(image as AnyObject)) } }
        note()
        content.setPlaying(true)
        let end = Date().addingTimeInterval(0.6)
        while Date() < end { note(); try? await Task.sleep(for: .milliseconds(5)) }
        #expect(seen.count >= 2, "frames did not advance")

        content.setPlaying(false)
        try? await Task.sleep(for: .milliseconds(100))
        let frozen = layer.contents.map { ObjectIdentifier($0 as AnyObject) }
        try? await Task.sleep(for: .milliseconds(300))
        #expect(layer.contents.map { ObjectIdentifier($0 as AnyObject) } == frozen, "a paused GIF must not move")
    }

    @Test func scalingChoiceSetsTheLayerGravity() async throws {
        let dir = try TestImages.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "a.gif")
        try TestImages.write(url, delays: [0.1, 0.1])
        let (content, _, _) = await started(url)
        defer { content.stop() }
        content.setScaling(.fit)
        #expect(content.view.layer?.contentsGravity == .resizeAspect)
        content.setScaling(.stretch)
        #expect(content.view.layer?.contentsGravity == .resize)
        content.setScaling(.fill)
        #expect(content.view.layer?.contentsGravity == .resizeAspectFill)
    }

    @Test func aStillPictureFailsWithAReason() async throws {
        let dir = try TestImages.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "still.gif")
        try TestImages.write(url, delays: [0.1])
        let (content, ready, error) = await started(url)
        defer { content.stop() }
        #expect(!ready)
        #expect((error as? GifError) == .notAnimated)
    }

    @Test func stopDropsTheFrames() async throws {
        let dir = try TestImages.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "a.gif")
        try TestImages.write(url, delays: [0.05, 0.05])
        let (content, _, _) = await started(url)
        content.stop()
        #expect(content.view.layer?.contents == nil)
    }
}

@MainActor
@Suite struct GifModelTests {
    @Test func aGifGoesIntoTheLibraryAndSurvivesARestart() async throws {
        let box = Sandbox()
        defer { box.cleanup() }
        let url = box.directory.appending(path: "cat.gif")
        try FileManager.default.createDirectory(at: box.directory, withIntermediateDirectories: true)
        try TestImages.write(url, delays: [0.1, 0.1])
        let model = box.model()
        #expect(await model.addToLibrary(WallpaperSource(kind: .gif, location: url.path)))
        #expect(model.library.items.map(\.source.kind) == [.gif])
        #expect(box.model().library.items.map(\.source.kind) == [.gif])
    }

    @Test func aStillPictureIsRefusedWithAMessage() async throws {
        let box = Sandbox()
        defer { box.cleanup() }
        let url = box.directory.appending(path: "still.gif")
        try FileManager.default.createDirectory(at: box.directory, withIntermediateDirectories: true)
        try TestImages.write(url, delays: [0.1])
        let model = box.model()
        #expect(await !model.addToLibrary(WallpaperSource(kind: .gif, location: url.path)))
        #expect(model.library.items.isEmpty)
        #expect(model.notice != nil)
    }

    @Test func aGifOnEachScreenSurvivesARestart() async throws {
        let box = Sandbox()
        defer { box.cleanup() }
        let model = box.model()
        let one = WallpaperSource(kind: .gif, location: "/g/a.gif")
        let two = WallpaperSource(kind: .gif, location: "/g/b.gif")
        model.apply(one, to: .display("SCREEN-1"))
        model.apply(two, to: .display("SCREEN-2"))
        let again = box.model()
        #expect(again.assignments.source(forDisplay: "SCREEN-1") == one)
        #expect(again.assignments.source(forDisplay: "SCREEN-2") == two)
    }
}
