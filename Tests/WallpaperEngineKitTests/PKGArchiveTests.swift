import Foundation
import Testing
@testable import WallpaperEngineKit

@Suite struct PKGArchiveTests {
    private let scene = Data(#"{"objects":[{"image":"models/a.json","effects":[{},{}]},{"particle":"p.json"},{"name":"group"}],"general":{"orthogonalprojection":{"width":3840,"height":2160}}}"#.utf8)

    @Test func readsTheTableAndTheFiles() throws {
        let data = EngineFixtures.pkg(entries: [("scene.json", scene), ("materials/人物.tex", Data([1, 2, 3]))])
        let archive = try PKGArchive(data: data)
        #expect(archive.version == "PKGV0024")
        #expect(archive.entries.map(\.path) == ["scene.json", "materials/人物.tex"])
        #expect(archive.contents(of: "scene.json") == scene)
        #expect(archive.contents(of: "materials/人物.tex") == Data([1, 2, 3]))
    }

    @Test func lookupIgnoresCaseAndBackslashes() throws {
        let archive = try PKGArchive(data: EngineFixtures.pkg(entries: [("Materials\\Layer.TEX", Data([7]))]))
        #expect(archive.entries.first?.path == "Materials/Layer.TEX")
        #expect(archive.contents(of: "materials/layer.tex") == Data([7]))
        #expect(archive.contents(of: "MATERIALS\\LAYER.TEX") == Data([7]))
        #expect(archive.contents(of: "materials/other.tex") == nil)
    }

    @Test func anyVersionNumberIsAccepted() throws {
        #expect(try PKGArchive(data: EngineFixtures.pkg(entries: [], version: "PKGV0012")).version == "PKGV0012")
    }

    @Test func aMacInstallerIsRefusedByName() {
        let installer = Data("xar!".utf8) + Data(repeating: 0, count: 64)
        #expect(throws: PKGArchive.Failure.installerPackage) { try PKGArchive(data: installer) }
        #expect(PKGArchive.Failure.installerPackage.errorDescription?.contains("установщик macOS") == true)
    }

    @Test func otherFilesAreNotPackages() {
        #expect(throws: PKGArchive.Failure.self) { try PKGArchive(data: Data("hello world, not a package".utf8)) }
        #expect(throws: PKGArchive.Failure.self) { try PKGArchive(data: Data()) }
        #expect(throws: PKGArchive.Failure.notAPackage) {
            try PKGArchive(data: Data(EngineFixtures.string("ABCD0001") + EngineFixtures.int32(0)))
        }
    }

    @Test func aTruncatedPackageIsDamaged() throws {
        let whole = EngineFixtures.pkg(entries: [("scene.json", scene), ("a.bin", Data([1, 2, 3, 4]))])
        // Cut inside the table, and cut inside the data.
        for length in [3, 10, 20, 40, whole.count - 1] {
            #expect(throws: PKGArchive.Failure.self, "cut at \(length)") { try PKGArchive(data: whole.prefix(length)) }
        }
    }

    @Test func absurdCountsAreRefused() {
        #expect(throws: PKGArchive.Failure.self) {
            try PKGArchive(data: Data(EngineFixtures.string("PKGV0024") + EngineFixtures.int32(-1)))
        }
        #expect(throws: PKGArchive.Failure.self) {
            try PKGArchive(data: Data(EngineFixtures.string("PKGV0024") + EngineFixtures.int32(2_000_000_000)))
        }
        // A path length that runs past the file.
        #expect(throws: PKGArchive.Failure.self) {
            try PKGArchive(data: Data(EngineFixtures.string("PKGV0024") + EngineFixtures.int32(1) + EngineFixtures.int32(500)))
        }
    }

    @Test func aFileOutsideTheDataIsRefused() {
        var table: [UInt8] = EngineFixtures.string("PKGV0024") + EngineFixtures.int32(1)
        table += EngineFixtures.string("a.bin") + EngineFixtures.int32(5) + EngineFixtures.int32(100)
        #expect(throws: PKGArchive.Failure.self) { try PKGArchive(data: Data(table) + Data(repeating: 0, count: 10)) }
        var negative: [UInt8] = EngineFixtures.string("PKGV0024") + EngineFixtures.int32(1)
        negative += EngineFixtures.string("a.bin") + EngineFixtures.int32(-4) + EngineFixtures.int32(2)
        #expect(throws: PKGArchive.Failure.self) { try PKGArchive(data: Data(negative) + Data(repeating: 0, count: 10)) }
    }

    @Test func dangerousPathsAreRefused() {
        for path in ["../x.tex", "a/../../x", "/etc/passwd", "C:/x", "a//b"] {
            #expect(throws: PKGArchive.Failure.self, "\(path)") {
                try PKGArchive(data: EngineFixtures.pkg(entries: [(path, Data([1]))]))
            }
        }
    }

    @Test func aPathThatIsNotUTF8IsRefused() {
        var table: [UInt8] = EngineFixtures.string("PKGV0024") + EngineFixtures.int32(1)
        table += EngineFixtures.int32(3) + [0xFF, 0xFE, 0xFD] + EngineFixtures.int32(0) + EngineFixtures.int32(0)
        #expect(throws: PKGArchive.Failure.self) { try PKGArchive(data: Data(table)) }
    }

    @Test func readsAFileOnDiskMapped() throws {
        let dir = try EngineFixtures.tempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "scene.pkg")
        try EngineFixtures.pkg(entries: [("scene.json", scene)]).write(to: file)
        #expect(try PKGArchive(contentsOf: file).contents(of: "scene.json") == scene)
    }
}
