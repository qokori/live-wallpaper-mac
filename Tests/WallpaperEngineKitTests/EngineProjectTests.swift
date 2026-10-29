import Foundation
import Testing
@testable import WallpaperEngineKit

@Suite struct EngineProjectTests {
    @Test(arguments: [("scene", EngineProject.Kind.scene), ("video", .video), ("web", .web), ("application", .application)])
    func knowsTheTypes(type: String, kind: EngineProject.Kind) throws {
        #expect(try EngineProject(data: EngineFixtures.projectJSON(type: type)).kind == kind)
    }

    @Test func typeIsReadInAnyCase() throws {
        #expect(try EngineProject(data: EngineFixtures.projectJSON(type: "Scene")).kind == .scene)
        #expect(try EngineProject(data: EngineFixtures.projectJSON(type: "VIDEO")).kind == .video)
        let project = try EngineProject(data: Data(#"{"Type":"Web","File":"index.html"}"#.utf8))
        #expect(project.kind == .web)
        #expect(project.file == "index.html")
    }

    @Test func anUnknownTypeIsKeptAsWritten() throws {
        let project = try EngineProject(data: EngineFixtures.projectJSON(type: "hologram"))
        #expect(project.kind == .other("hologram"))
        #expect(project.rawType == "hologram")
    }

    @Test func aByteOrderMarkIsSkipped() throws {
        let project = try EngineProject(data: EngineFixtures.projectJSON(bom: true))
        #expect(project.title == "Тест")
        #expect(project.preview == "preview.jpg")
    }

    @Test func workshopIDComesAsNumberOrString() throws {
        #expect(try EngineProject(data: EngineFixtures.projectJSON(#""workshopid":"1234567890""#)).workshopID == "1234567890")
        #expect(try EngineProject(data: EngineFixtures.projectJSON(#""workshopid":1234567890"#)).workshopID == "1234567890")
        #expect(try EngineProject(data: EngineFixtures.projectJSON()).workshopID == nil)
    }

    @Test func settingsKeepTheirTypesAndDefaults() throws {
        let fields = """
        "general":{"supportsaudioprocessing":true,"properties":{
          "schemecolor":{"order":0,"text":"scheme","type":"color","value":"0.5 0.25 1"},
          "speed":{"order":2,"text":"Speed","type":"slider","min":0,"max":10,"value":3.5},
          "glow":{"order":1,"text":"Glow","type":"bool","value":true},
          "label":{"order":3,"type":"textinput","value":"a \\"b\\" </script>"},
          "heading":{"order":4,"type":"group","text":"Section"},
          "broken":"not an object"
        }}
        """
        let project = try EngineProject(data: EngineFixtures.projectJSON(fields, type: "web", file: "index.html"))
        #expect(project.properties.map(\.key) == ["schemecolor", "glow", "speed", "label", "heading"])
        #expect(project.properties.map(\.type) == ["color", "bool", "slider", "textinput", "group"])
        #expect(project.properties[0].valueJSON == "\"0.5 0.25 1\"")
        #expect(project.properties[1].valueJSON == "true")
        #expect(project.properties[2].valueJSON == "3.5")
        #expect(project.properties[4].valueJSON == nil)
    }

    @Test func badJSONAndMissingTypeAreFailures() {
        #expect(throws: EngineProject.Failure.unreadable) { try EngineProject(data: Data("not json".utf8)) }
        #expect(throws: EngineProject.Failure.unreadable) { try EngineProject(data: Data("[1,2]".utf8)) }
        #expect(throws: EngineProject.Failure.noType) { try EngineProject(data: Data(#"{"title":"x"}"#.utf8)) }
        #expect(throws: EngineProject.Failure.noType) { try EngineProject(data: Data(#"{"type":""}"#.utf8)) }
    }
}

@Suite struct EngineLocationTests {
    private func project(files: [String], in dir: URL) throws {
        for name in files {
            let url = dir.appending(path: name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if name.lowercased() == "project.json" {
                try EngineFixtures.projectJSON().write(to: url)
            } else if name.hasSuffix(".pkg") {
                try EngineFixtures.pkg(entries: [("scene.json", Data("{}".utf8))]).write(to: url)
            } else {
                try Data([1]).write(to: url)
            }
        }
    }

    @Test func aFolderAProjectFileAndAPackageAllLeadToTheFolder() throws {
        let dir = try EngineFixtures.tempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try project(files: ["project.json", "scene.pkg", "preview.jpg"], in: dir)
        for chosen in [dir, dir.appending(path: "project.json"), dir.appending(path: "scene.pkg")] {
            let location = try EngineLocation.resolve(chosen)
            #expect(location.folder.standardizedFileURL == dir.standardizedFileURL)
            #expect(location.package?.lastPathComponent == "scene.pkg")
        }
    }

    @Test func aGifScenePackageIsFoundToo() throws {
        let dir = try EngineFixtures.tempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try project(files: ["Project.JSON", "gifscene.pkg"], in: dir)
        #expect(try EngineLocation.resolve(dir).package?.lastPathComponent == "gifscene.pkg")
        #expect(EngineLocation.find("project.json", in: dir)?.lastPathComponent == "Project.JSON")
    }

    @Test func aFolderWithoutProjectJSONIsRefused() throws {
        let dir = try EngineFixtures.tempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try project(files: ["index.html"], in: dir)
        #expect(throws: EngineProject.Failure.noProject) { try EngineLocation.resolve(dir) }
        #expect(throws: EngineLocation.Failure.notAProject) { try EngineLocation.resolve(dir.appending(path: "index.html")) }
        #expect(throws: EngineLocation.Failure.notAProject) { try EngineLocation.resolve(dir.appending(path: "missing")) }
    }

    @Test func aPackageAloneNeedsItsProjectFile() throws {
        let dir = try EngineFixtures.tempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try project(files: ["scene.pkg"], in: dir)
        #expect(throws: EngineLocation.Failure.noProjectBesidePackage) { try EngineLocation.resolve(dir.appending(path: "scene.pkg")) }
    }

    @Test func aMacInstallerIsNotAProject() throws {
        let dir = try EngineFixtures.tempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try project(files: ["project.json"], in: dir)
        try (Data("xar!".utf8) + Data(repeating: 0, count: 80)).write(to: dir.appending(path: "Setup.pkg"))
        #expect(throws: PKGArchive.Failure.installerPackage) { try EngineLocation.resolve(dir.appending(path: "Setup.pkg")) }
    }

    @Test func projectFilesStayInsideTheFolder() throws {
        let dir = try EngineFixtures.tempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try project(files: ["sub/Clip.MP4", "preview.jpg"], in: dir)
        #expect(EngineLocation.file("sub/clip.mp4", in: dir)?.lastPathComponent == "Clip.MP4")
        #expect(EngineLocation.file("PREVIEW.JPG", in: dir)?.lastPathComponent == "preview.jpg")
        #expect(EngineLocation.file("../x", in: dir) == nil)
        #expect(EngineLocation.file("/etc/hosts", in: dir) == nil)
        #expect(EngineLocation.file("sub/../preview.jpg", in: dir) == nil)
        #expect(EngineLocation.file("nothing.gif", in: dir) == nil)
    }
}

@Suite struct EngineInspectorTests {
    @Test func reportsTheProjectAndWhatTheScenePackageHolds() throws {
        let dir = try EngineFixtures.tempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try EngineFixtures.projectJSON(#""workshopid":"42","general":{"properties":{"glow":{"type":"bool","value":true,"order":1}}}"#)
            .write(to: dir.appending(path: "project.json"))
        let scene = Data(#"{"objects":[{"image":"a","effects":[{},{}]},{"particle":"p"},{"name":"g"}],"general":{"orthogonalprojection":{"width":3840,"height":2160}}}"#.utf8)
        try EngineFixtures.pkg(entries: [("scene.json", scene), ("materials/a.tex", Data([1, 2]))]).write(to: dir.appending(path: "scene.pkg"))
        let report = try EngineInspector.report(for: dir)
        #expect(report.contains("type: scene"))
        #expect(report.contains("workshopid: 42"))
        #expect(report.contains("glow [bool] = true"))
        #expect(report.contains("PKGV0024"))
        #expect(report.contains("файлов 2"))
        #expect(report.contains("объектов 3 (image 1, particle 1, группа 1), эффектов 2"))
        #expect(report.contains("3840×2160"))
        #expect(report.contains("materials/a.tex (2)"))
    }

    @Test func aProjectWithoutAPackageSaysSo() throws {
        let dir = try EngineFixtures.tempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try EngineFixtures.projectJSON(type: "application", file: "run.exe").write(to: dir.appending(path: "project.json"))
        let report = try EngineInspector.report(for: dir)
        #expect(report.contains("программа для Windows"))
        #expect(report.contains("пакет: нет"))
    }
}

@Suite struct EngineWebShimTests {
    @Test func settingsBecomeAScriptLiteral() throws {
        let project = try EngineProject(data: EngineFixtures.projectJSON(
            #""general":{"properties":{"a":{"type":"bool","value":false,"order":0},"b":{"type":"textinput","value":"x</script>y","order":1},"g":{"type":"group","order":2}}}"#
        ))
        let literal = EngineWebShim.propertiesLiteral(project.properties)
        #expect(literal == #"{"a": {value: false}, "b": {value: "x<\/script>y"}}"#)
    }

    @Test func theScriptCarriesTheStartingValues() {
        let script = EngineWebShim.source(properties: [], frameRate: 30, paused: true)
        #expect(script.contains("let fps = 30;"))
        #expect(script.contains("let paused = true;"))
        #expect(script.contains("wallpaperPropertyListener"))
        #expect(EngineWebShim.setPaused(false) == "window.__engineShim && window.__engineShim.setPaused(false)")
    }
}
