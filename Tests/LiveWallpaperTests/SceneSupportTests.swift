import AppKit
import Foundation
import Testing
import WallpaperCore
import WallpaperEngineKit
@testable import LiveWallpaper

@MainActor
@Suite(.serialized) struct SceneSupportTests {
    private func folder() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "lw-support-\(UUID().uuidString)")
    }

    private func source(_ url: URL) -> WallpaperSource {
        WallpaperSource(kind: .wallpaperEngine, location: url.path, bookmark: nil, engine: .scene)
    }

    private func drawable(_ dir: URL) throws -> URL {
        try EngineFixtures.scene(in: dir, layers: [.init(name: "a", texture: EngineFixtures.solid(1, 0, 0))])
    }

    @Test func aDrawableSceneGetsTheRendererAndNoPreviewBadge() throws {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try drawable(dir)
        let web = try #require(EngineSupport.content(for: source(dir), frameRate: 30, label: "t") as? WebContent)
        #expect(web.isScene)
        #expect(EngineSupport.sceneIsDrawn(source(dir)))
        web.stop()
    }

    @Test func aSceneThatCannotBeDrawnFallsBackToItsPreview() throws {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"type":"scene","file":"scene.json","preview":"preview.png"}"#.utf8).write(to: dir.appending(path: "project.json"))
        try EngineFixtures.pkg(entries: [("scene.json", Data(#"{"objects":[{"id":1,"particle":"x"}]}"#.utf8))]).write(to: dir.appending(path: "scene.pkg"))
        try EngineFixtures.png(width: 4, height: 4).write(to: dir.appending(path: "preview.png"))
        #expect(!EngineSupport.sceneIsDrawn(source(dir)))
        let content = try EngineSupport.content(for: source(dir), frameRate: 30, label: "t")
        #expect(content is StillContent)
    }

    @Test func aSceneNotYetDecodedIsBuiltLaterAndAnotherScreenFindsItReady() async throws {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try drawable(dir)
        guard case .later(let work) = try EngineSupport.build(for: source(dir), settings: { .init(frameRate: 30, quality: .screen) }, label: "t") else {
            Issue.record("an uncached scene must be built in the background")
            return
        }
        let first = try #require(try await work() as? WebContent)
        #expect(first.isScene)
        // The first screen holds the textures: the second one needs no waiting.
        guard case .ready(let second) = try EngineSupport.build(for: source(dir), settings: { .init(frameRate: 30, quality: .screen) }, label: "t") else {
            Issue.record("a scene that is already decoded is ready at once")
            return
        }
        #expect(second is WebContent)
        first.stop()
        second.stop()
    }

    /// Settings changed while the scene was being decoded reach the web view made afterwards.
    @Test func aSceneBuiltWhileTheSettingsChangeGetsTheNewOnes() async throws {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try drawable(dir)
        var settings = EngineSupport.SceneSettings(frameRate: 30, quality: .screen)
        guard case .later(let work) = try EngineSupport.build(for: source(dir), settings: { settings }, label: "t") else {
            Issue.record("expected a background build")
            return
        }
        settings = .init(frameRate: 15, quality: .economy)
        let web = try #require(try await work() as? WebContent)
        #expect(web.currentQuality == .economy)
        #expect(web.currentFrameRate == 15)
        web.stop()
    }

    /// Cancelling the only screen that waits stops the background build; with two waiting, the first to leave changes nothing.
    @Test func theBuildStopsWhenTheLastWaitingScreenLeaves() async throws {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try drawable(dir)
        let item = try EngineSupport.open(dir)
        let gate = DispatchSemaphore(value: 0)
        EngineSupport.buildGate = { gate.wait() }
        defer { EngineSupport.buildGate = nil }
        let a = Task { try await EngineSupport.loadSceneAssets(item) }
        let b = Task { try await EngineSupport.loadSceneAssets(item) }
        for _ in 0..<200 where EngineSupport.buildsInFlight.waiters < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(EngineSupport.buildsInFlight == (1, 2))
        a.cancel()
        for _ in 0..<200 where EngineSupport.buildsInFlight.waiters > 1 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(EngineSupport.buildsInFlight == (1, 1), "один ждущий остался: сборка идёт")
        b.cancel()
        for _ in 0..<200 where EngineSupport.buildsInFlight.builds > 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(EngineSupport.buildsInFlight == (0, 0))
        gate.signal()
        EngineSupport.buildGate = nil
        await #expect(throws: CancellationError.self) { try await b.value }
        // The cancelled build left nothing behind: a new request builds again.
        #expect(try await EngineSupport.loadSceneAssets(item).document.layers.count == 1)
    }

    @Test func aBuildCancelledBeforeItsTexturesStopsBetweenThem() async throws {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try drawable(dir)
        let item = try EngineSupport.open(dir)
        let task = Task.detached { () -> SceneAssets in
            while !Task.isCancelled { await Task.yield() }
            return try EngineSupport.sceneAssets(item)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func editingProjectJsonChangesTheCacheKey() throws {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try drawable(dir)
        let before = EngineSupport.key(try EngineSupport.open(dir))
        let file = dir.appending(path: "project.json")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 3600)], ofItemAtPath: file.path)
        #expect(EngineSupport.key(try EngineSupport.open(dir)) != before)
    }

    @Test func screensAskingForOneSceneAtOnceWaitForOneBuild() async throws {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try drawable(dir)
        let item = try EngineSupport.open(dir)
        async let a = EngineSupport.loadSceneAssets(item)
        async let b = EngineSupport.loadSceneAssets(item)
        let (x, y) = try await (a, b)
        #expect(x === y)
    }

    @Test func aSceneThatCannotBeDecodedFallsBackToItsPreviewAfterTheWait() async throws {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"type":"scene","file":"scene.json","preview":"preview.png"}"#.utf8).write(to: dir.appending(path: "project.json"))
        try EngineFixtures.pkg(entries: [("scene.json", Data(#"{"objects":[{"id":1,"particle":"x"}]}"#.utf8))]).write(to: dir.appending(path: "scene.pkg"))
        try EngineFixtures.png(width: 4, height: 4).write(to: dir.appending(path: "preview.png"))
        guard case .later(let work) = try EngineSupport.build(for: source(dir), settings: { .init(frameRate: 30, quality: .screen) }, label: "t") else {
            Issue.record("expected a background build")
            return
        }
        #expect(try await work() is StillContent)
    }

    /// The decoding runs off the main thread: the main actor keeps answering while a big scene is built.
    @Test func theMainThreadKeepsRunningWhileASceneIsBuilt() async throws {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        // 48 uncompressed textures of 4 MiB each: enough for the build to take a measurable time.
        let big = EngineFixtures.tex(width: 1024, height: 1024, bytes: [UInt8](repeating: 7, count: 1024 * 1024 * 4))
        _ = try EngineFixtures.scene(in: dir, layers: (0..<48).map { .init(name: "l\($0)", texture: big) })
        let item = try EngineSupport.open(dir)
        var finished = false
        let build = Task { _ = try await EngineSupport.loadSceneAssets(item); finished = true }
        var ticks = 0
        while !finished && ticks < 5000 {
            try await Task.sleep(for: .milliseconds(1))
            ticks += 1
        }
        try await build.value
        #expect(ticks >= 2)
    }

    @Test func theSnapshotIsStoredFoundAndRemoved() throws {
        let dir = folder()
        let cache = folder()
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: cache) }
        _ = try drawable(dir)
        let saved = EngineCache.root
        EngineCache.root = cache
        defer { EngineCache.root = saved }
        let item = try EngineSupport.open(dir)
        #expect(EngineCache.snapshot(for: item) == nil)
        // No preview in the project and no snapshot yet: nothing to take the desktop picture from.
        #expect(EngineSupport.frameURL(of: source(dir)) == nil)
        let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
            NSColor.red.setFill(); rect.fill(); return true
        }
        let url = try #require(EngineCache.storeSnapshot(image, for: item))
        #expect(EngineCache.snapshot(for: item) == url)
        #expect(EngineSupport.frameURL(of: source(dir)) == url)
        EngineCache.remove(for: item)
        #expect(EngineCache.snapshot(for: item) == nil)
    }

    @Test func theKeyChangesWhenTheProjectChanges() throws {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try drawable(dir)
        let before = EngineCache.key(for: try EngineSupport.open(dir))
        try Data(#"{"type":"scene","file":"scene.json","title":"Другой"}"#.utf8).write(to: dir.appending(path: "project.json"))
        #expect(EngineCache.key(for: try EngineSupport.open(dir)) != before)
    }

    @Test func theCacheKeepsToItsSizeLimitDroppingTheOldestFirst() throws {
        let cache = folder()
        defer { try? FileManager.default.removeItem(at: cache) }
        let saved = EngineCache.root
        EngineCache.root = cache
        defer { EngineCache.root = saved }
        for (index, name) in ["old", "middle", "new"].enumerated() {
            let sub = cache.appending(path: name)
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            try Data(repeating: 1, count: 100).write(to: sub.appending(path: "snapshot.png"))
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(1000 + index))], ofItemAtPath: sub.path)
        }
        EngineCache.trim(limit: 250)
        let left = try FileManager.default.contentsOfDirectory(atPath: cache.path).sorted()
        #expect(left == ["middle", "new"])
    }
}
