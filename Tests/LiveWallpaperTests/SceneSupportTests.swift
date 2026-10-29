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
        guard case .later(let work) = try EngineSupport.build(for: source(dir), frameRate: 30, label: "t") else {
            Issue.record("an uncached scene must be built in the background")
            return
        }
        let first = try #require(try await work() as? WebContent)
        #expect(first.isScene)
        // The first screen holds the textures: the second one needs no waiting.
        guard case .ready(let second) = try EngineSupport.build(for: source(dir), frameRate: 30, label: "t") else {
            Issue.record("a scene that is already decoded is ready at once")
            return
        }
        #expect(second is WebContent)
        first.stop()
        second.stop()
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
        guard case .later(let work) = try EngineSupport.build(for: source(dir), frameRate: 30, label: "t") else {
            Issue.record("expected a background build")
            return
        }
        #expect(try await work() is StillContent)
    }

    /// The decoding runs off the main thread: the main actor keeps answering while a big scene is built.
    @Test func theMainThreadKeepsRunningWhileASceneIsBuilt() async throws {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        // 12 uncompressed textures of 4 MiB each: enough for the build to take a measurable time.
        let big = EngineFixtures.tex(width: 1024, height: 1024, bytes: [UInt8](repeating: 7, count: 1024 * 1024 * 4))
        _ = try EngineFixtures.scene(in: dir, layers: (0..<12).map { .init(name: "l\($0)", texture: big) })
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
