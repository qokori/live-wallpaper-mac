import Foundation
import Testing
@testable import WallpaperCore

@Suite struct EngineSourceTests {
    private func folder(withProject json: String?, named name: String = "project.json") throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "lw-eng-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let json { try Data(json.utf8).write(to: dir.appending(path: name)) }
        return dir
    }

    @Test func packagesAndProjectFilesAreProjects() {
        #expect(WallpaperSource.Kind.detect(path: "/w/scene.pkg", isDirectory: false) == .wallpaperEngine)
        #expect(WallpaperSource.Kind.detect(path: "/w/GIFSCENE.PKG", isDirectory: false) == .wallpaperEngine)
        #expect(WallpaperSource.Kind.detect(path: "/w/Project.JSON", isDirectory: false) == .wallpaperEngine)
        #expect(WallpaperSource.Kind.detect(path: "/w/other.json", isDirectory: false) == .video)
        #expect(WallpaperSource.Kind.detect(path: "/w/folder", isDirectory: true) == .web)
    }

    @Test func aFolderIsAProjectOnlyWithAProjectFileThatHasAType() throws {
        let project = try folder(withProject: #"{"type":"Scene","file":"scene.json"}"#)
        let spelled = try folder(withProject: "\u{FEFF}" + #"{"Type":"video"}"#, named: "PROJECT.JSON")
        let page = try folder(withProject: nil)
        let nodeProject = try folder(withProject: #"{"name":"npm package","version":"1.0.0"}"#)
        let broken = try folder(withProject: "{ nope")
        defer { for dir in [project, spelled, page, nodeProject, broken] { try? FileManager.default.removeItem(at: dir) } }
        #expect(WallpaperSource.Kind.detect(url: project) == .wallpaperEngine)
        #expect(WallpaperSource.Kind.detect(url: spelled) == .wallpaperEngine)
        #expect(WallpaperSource.Kind.detect(url: page) == .web)
        #expect(WallpaperSource.Kind.detect(url: nodeProject) == .web)
        #expect(WallpaperSource.Kind.detect(url: broken) == .web)
        #expect(WallpaperSource.Kind.detect(url: project.appending(path: "project.json")) == .wallpaperEngine)
    }

    @Test func scalingAppliesToVideoAndSceneProjectsButNotToWebOnes() {
        var assignments = WallpaperAssignments()
        for (engine, applies) in [(EngineType.video, true), (.scene, true), (.web, false)] {
            assignments.apply(WallpaperSource(kind: .wallpaperEngine, location: "/w/1", engine: engine), to: .all)
            #expect(assignments.scalingApplies(forDisplay: nil) == applies, "\(engine)")
        }
    }

    @Test func isPageCoversWebAndWebProjects() {
        #expect(WallpaperSource(kind: .web, location: "/p").isPage)
        #expect(WallpaperSource(kind: .wallpaperEngine, location: "/w", engine: .web).isPage)
        #expect(!WallpaperSource(kind: .wallpaperEngine, location: "/w", engine: .scene).isPage)
        #expect(!WallpaperSource(kind: .gif, location: "/g.gif").isPage)
    }

    @Test func theProjectKindSurvivesTheLibraryFile() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "lw-eng-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LibraryStore(fileURL: dir.appending(path: "library.json"))
        var library = WallpaperLibrary()
        library.add(WallpaperSource(kind: .wallpaperEngine, location: "/w/1", bookmark: Data([1]), engine: .scene), now: Date(timeIntervalSince1970: 5))
        try store.save(library)
        let loaded = store.load()
        #expect(loaded == library)
        #expect(loaded.items.first?.source.engine == .scene)
        #expect(loaded.unreadable.isEmpty)
    }

    @Test func aSourceWrittenBeforeProjectsExistedStillLoads() throws {
        let json = #"{"kind":"video","location":"/v/a.mov"}"#
        let source = try JSONDecoder().decode(WallpaperSource.self, from: Data(json.utf8))
        #expect(source.engine == nil)
        #expect(source.kind == .video)
    }
}
