import Foundation
import Testing
@testable import WallpaperEngineKit

/// Real Workshop projects, read where they lie: LW_WE_SAMPLES names a folder of project folders. Without it these tests
/// do nothing. The samples belong to their authors and are never copied into the repository.
@Suite struct RealSamplesTests {
    private static var folders: [URL] {
        guard let path = ProcessInfo.processInfo.environment["LW_WE_SAMPLES"], !path.isEmpty else { return [] }
        let root = URL(filePath: (path as NSString).expandingTildeInPath)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.sorted().map { root.appending(path: $0) }.filter {
            FileManager.default.fileExists(atPath: $0.appending(path: "project.json").path)
        }
    }

    @Test(arguments: folders)
    func everyProjectResolvesAndItsFilesAreThere(folder: URL) throws {
        let location = try EngineLocation.resolve(folder)
        let project = try EngineProject(contentsOf: location.projectFile)
        if let preview = project.preview { #expect(EngineLocation.file(preview, in: folder) != nil, "preview \(preview)") }
        switch project.kind {
        case .scene:
            let package = try #require(location.package)
            let archive = try PKGArchive(contentsOf: package)
            #expect(archive.version.hasPrefix("PKGV"))
            #expect(archive.contains(project.file ?? "scene.json"))
            #expect(!archive.entries.isEmpty)
        case .video, .web:
            #expect(project.file.flatMap { EngineLocation.file($0, in: folder) } != nil)
        default:
            break
        }
        #expect(try !EngineInspector.report(for: folder).isEmpty)
    }

    @Test(arguments: folders)
    func sceneTexturesAndLayersAreRead(folder: URL) throws {
        let location = try EngineLocation.resolve(folder)
        let project = try EngineProject(contentsOf: location.projectFile)
        guard project.kind == .scene, let package = location.package else { return }
        let archive = try PKGArchive(contentsOf: package)
        // Every texture in the package reads (the masks and effect textures too).
        for entry in archive.entries where entry.path.lowercased().hasSuffix(".tex") {
            let bytes = try #require(archive.slice(of: entry.path))
            _ = try TexFile(data: bytes)
        }
        let assets = try SceneAssets(files: EngineFileSystem(location: location), project: project)
        #expect(!assets.document.layers.isEmpty)
        #expect(assets.textures.count >= 1)
        let report = try EngineInspector.report(for: folder)
        #expect(report.contains("рисуется: слоёв"))
    }
}
