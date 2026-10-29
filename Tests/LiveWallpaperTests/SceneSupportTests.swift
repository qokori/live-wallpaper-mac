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
