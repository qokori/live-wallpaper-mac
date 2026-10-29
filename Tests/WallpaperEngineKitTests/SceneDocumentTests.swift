import Foundation
import Testing
@testable import WallpaperEngineKit

@Suite struct SceneDocumentTests {
    private let solid = EngineFixtures.tex(mips: [.init(width: 1, height: 1, bytes: [255, 255, 255, 255])])

    /// A scene package with `objects` (JSON text) and one texture per name in `textures`; models and materials are made here.
    private func files(
        _ objects: String, general: String = #""orthogonalprojection":{"width":1920,"height":1080}"#,
        textures: [String] = ["a"], extra: [(String, Data)] = []
    ) throws -> (EngineFileSystem, Data) {
        var entries: [(String, Data)] = []
        for name in textures {
            entries.append(("models/\(name).json", Data(#"{"material":"materials/\#(name).json"}"#.utf8)))
            entries.append(("materials/\(name).json", Data(#"{"passes":[{"blending":"translucent","shader":"genericimage4","textures":["\#(name)"]}]}"#.utf8)))
            entries.append(("materials/\(name).tex", solid))
        }
        let scene = Data(#"{"general":{\#(general)},"objects":[\#(objects)]}"#.utf8)
        entries.append(("scene.json", scene))
        let archive = try PKGArchive(data: EngineFixtures.pkg(entries: entries + extra))
        return (EngineFileSystem(folder: URL(filePath: "/nonexistent"), archive: archive), scene)
    }

    private func document(_ objects: String, general: String = #""orthogonalprojection":{"width":1920,"height":1080}"#, textures: [String] = ["a"], properties: [EngineProject.Property] = []) throws -> SceneDocument {
        let (fs, scene) = try files(objects, general: general, textures: textures)
        return try SceneDocument(data: scene, files: fs, properties: properties)
    }

    private func sceneJSON(_ assets: SceneAssets) throws -> [String: Any] {
        let resource = try #require(assets.resource(path: "/scene.json"))
        return try #require(JSONSerialization.jsonObject(with: resource.body) as? [String: Any])
    }

    @Test func aPlainLayerKeepsItsFields() throws {
        let doc = try document(#"{"id":1,"name":"фон","image":"models/a.json","origin":"960 540 0","size":"1920 1080","alpha":0.5,"color":"1 0.5 0","brightness":2,"colorBlendMode":31,"parallaxDepth":"2 0"}"#)
        #expect(doc.width == 1920 && doc.height == 1080)
        let layer = try #require(doc.layers.first)
        #expect(layer.name == "фон" && layer.texture == "materials/a.tex")
        #expect(layer.transform == [1, 0, 0, 1, 960, 540])
        #expect(layer.size == [1920, 1080] && layer.alpha == 0.5 && layer.color == [1, 0.5, 0])
        #expect(layer.brightness == 2 && layer.blendMode == 31 && layer.blending == .translucent)
        #expect(layer.parallaxDepth == [2, 0])
    }

    @Test func defaultsApplyWhenFieldsAreMissing() throws {
        let doc = try document(#"{"id":1,"image":"models/a.json","size":"10 10"}"#)
        let layer = doc.layers[0]
        #expect(layer.alpha == 1 && layer.color == [1, 1, 1] && layer.brightness == 1 && layer.blendMode == 0)
        #expect(layer.parallaxDepth == [1, 1] && layer.transform == [1, 0, 0, 1, 0, 0])
        #expect(doc.clearColor == [0, 0, 0] && !doc.parallax.enabled)
    }

    @Test func scaleAndAngleBuildTheTransform() throws {
        let doc = try document(#"{"id":1,"image":"models/a.json","size":"10 10","origin":"100 50 0","scale":"2 3 1","angles":"0 0 1.5707963"}"#)
        let m = doc.layers[0].transform
        // Rotated a quarter turn counter-clockwise: the local x axis (scale 2) points up, the y axis (scale 3) points left.
        #expect(abs(m[0]) < 1e-6 && abs(m[1] - 2) < 1e-6 && abs(m[2] + 3) < 1e-6 && abs(m[3]) < 1e-6)
        #expect(m[4] == 100 && m[5] == 50)
    }

    @Test func aChildFollowsItsParentGroup() throws {
        let doc = try document("""
        {"id":10,"name":"группа","origin":"100 0 0","scale":"2 2 1"},
        {"id":1,"image":"models/a.json","size":"10 10","origin":"5 0 0","parent":10}
        """)
        // The child's origin is in the group's space: scaled by 2 and moved by 100.
        #expect(doc.layers[0].transform == [2, 0, 0, 2, 110, 0])
    }

    @Test func aHiddenObjectAndItsChildrenAreNotDrawn() throws {
        let doc = try document("""
        {"id":10,"origin":"0 0 0","visible":false},
        {"id":1,"image":"models/a.json","size":"10 10","parent":10},
        {"id":2,"image":"models/a.json","size":"10 10","visible":false},
        {"id":3,"name":"видимый","image":"models/a.json","size":"10 10"}
        """)
        #expect(doc.layers.map(\.name) == ["видимый"])
    }

    @Test func valuesBoundToASettingTakeTheProjectsValue() throws {
        let props = [
            EngineProject.Property(key: "show", type: "bool", text: nil, valueJSON: "false", order: 0),
            EngineProject.Property(key: "tint", type: "color", text: nil, valueJSON: #""0.25 0.5 1""#, order: 1),
            EngineProject.Property(key: "strength", type: "slider", text: nil, valueJSON: "0.3", order: 2),
        ]
        let doc = try document("""
        {"id":1,"name":"спрятан","image":"models/a.json","size":"10 10","visible":{"user":"show","value":true}},
        {"id":2,"name":"цветной","image":"models/a.json","size":"10 10","color":{"user":{"name":"tint","condition":"x"},"value":"1 1 1"},"alpha":{"user":"strength","value":1}},
        {"id":3,"name":"без настройки","image":"models/a.json","size":"10 10","alpha":{"user":"nothing","value":0.7}}
        """, properties: props)
        #expect(doc.layers.map(\.name) == ["цветной", "без настройки"])
        #expect(doc.layers[0].color == [0.25, 0.5, 1] && doc.layers[0].alpha == 0.3)
        #expect(doc.layers[1].alpha == 0.7)
    }

    @Test func parallaxSettingsAreRead() throws {
        let doc = try document(
            #"{"id":1,"image":"models/a.json","size":"10 10"}"#,
            general: #""cameraparallax":true,"cameraparallaxamount":0.08,"cameraparallaxdelay":0.2,"cameraparallaxmouseinfluence":0.5,"clearcolor":"0.7 0.7 0.7","orthogonalprojection":{"width":3840,"height":2160}"#
        )
        #expect(doc.parallax == .init(enabled: true, amount: 0.08, delay: 0.2, mouseInfluence: 0.5))
        #expect(doc.clearColor == [0.7, 0.7, 0.7] && doc.width == 3840)
    }

    @Test func whatIsNotDrawnIsListedWithTheReason() throws {
        let doc = try document("""
        {"id":1,"name":"картинка","image":"models/a.json","size":"10 10","effects":[{"file":"effects/x/effect.json","visible":true},{"file":"effects/y/effect.json","visible":false}]},
        {"id":2,"name":"искры","particle":"particles/x.json"},
        {"id":3,"name":"музыка","sound":["a.mp3"]},
        {"id":4,"name":"часы","text":{}},
        {"id":5,"name":"композиция","image":"models/util/composelayer.json","size":"10 10"},
        {"id":6,"name":"без файлов","image":"models/missing.json","size":"10 10"}
        """)
        #expect(doc.layers.map(\.name) == ["картинка"])
        #expect(doc.layers[0].effects == 1)
        let text = doc.skipped.joined(separator: "\n")
        for word in ["искры", "музыка", "часы", "композиция", "без файлов", "эффектов 1"] { #expect(text.contains(word), "\(word)") }
    }

    @Test func aLayerWithoutSizeTakesTheModelsSize() throws {
        let (fs, _) = try files("", textures: ["a"], extra: [("models/b.json", Data(#"{"material":"materials/a.json","width":640,"height":480}"#.utf8))])
        let doc = try SceneDocument(data: Data(#"{"general":{},"objects":[{"id":1,"image":"models/b.json"}]}"#.utf8), files: fs)
        #expect(doc.layers[0].size == [640, 480])
    }

    @Test func fileNamesMatchInAnyLetterCase() throws {
        let doc = try document(#"{"id":1,"image":"MODELS/A.json","size":"10 10"}"#)
        #expect(doc.layers.count == 1)
    }

    @Test func aSceneWithNothingToDrawIsRefused() throws {
        #expect(throws: SceneDocument.Failure.noLayers) { try document(#"{"id":1,"particle":"x"}"#) }
        let (fs, _) = try files("")
        #expect(throws: SceneDocument.Failure.unreadable) { try SceneDocument(data: Data("not json".utf8), files: fs) }
    }

    @Test func texturesListEachFileOnceInFirstUseOrder() throws {
        let doc = try document("""
        {"id":1,"image":"models/b.json","size":"1 1"},{"id":2,"image":"models/a.json","size":"1 1"},{"id":3,"image":"models/b.json","size":"1 1"}
        """, textures: ["a", "b"])
        #expect(doc.textures == ["materials/b.tex", "materials/a.tex"])
    }

    @Test func sceneAssetsServeThePageTheSceneAndTheTextures() throws {
        let (fs, scene) = try files(#"{"id":1,"image":"models/a.json","size":"10 10"}"#)
        let project = try EngineProject(data: EngineFixtures.projectJSON())
        _ = scene
        let assets = try SceneAssets(files: fs, project: project)
        let page = try #require(assets.resource(path: "/index.html"))
        #expect(page.status == 200 && page.headers["Content-Type"]?.hasPrefix("text/html") == true)
        let json = try sceneJSON(assets)
        #expect((json["layers"] as? [[String: Any]])?.count == 1)
        let textures = try #require(json["textures"] as? [[String: Any]])
        #expect(textures[0]["kind"] as? String == "raw" && textures[0]["url"] as? String == "t/0")
        let pixels = try #require(assets.resource(path: "/t/0"))
        #expect(Array(pixels.body) == [255, 255, 255, 255])
        #expect(assets.resource(path: "/t/9") == nil && assets.resource(path: "/nothing") == nil)
    }

    @Test func aBrokenTextureDropsOnlyItsLayers() throws {
        let (fs, _) = try files("", textures: ["a"], extra: [
            ("models/bad.json", Data(#"{"material":"materials/bad.json"}"#.utf8)),
            ("materials/bad.json", Data(#"{"passes":[{"textures":["bad"]}]}"#.utf8)),
            ("materials/bad.tex", Data("not a texture".utf8)),
        ])
        let scene = Data(#"{"general":{},"objects":[{"id":1,"image":"models/a.json","size":"1 1"},{"id":2,"image":"models/bad.json","size":"1 1"}]}"#.utf8)
        var entries = fs.archive!.entries.map { ($0.path, fs.archive!.contents(of: $0.path)!) }.filter { $0.0 != "scene.json" }
        entries.append(("scene.json", scene))
        let rebuilt = EngineFileSystem(folder: fs.folder, archive: try PKGArchive(data: EngineFixtures.pkg(entries: entries)))
        let assets = try SceneAssets(files: rebuilt, project: try EngineProject(data: EngineFixtures.projectJSON()))
        let json = try sceneJSON(assets)
        #expect((json["layers"] as? [[String: Any]])?.count == 1)
        #expect(assets.skipped.contains { $0.contains("bad.tex") })
    }

    @Test func rangeRequestsAnswerLikeAWebServer() {
        let bytes = Data((0..<100).map { UInt8($0) })
        func ask(_ range: String?) -> SceneAssets.Resource { SceneAssets.ranged(bytes, mime: "video/mp4", range: range) }
        let whole = ask(nil)
        #expect(whole.status == 200 && whole.body.count == 100 && whole.headers["Accept-Ranges"] == "bytes")
        let part = ask("bytes=10-19")
        #expect(part.status == 206 && Array(part.body) == Array(10...19).map { UInt8($0) })
        #expect(part.headers["Content-Range"] == "bytes 10-19/100" && part.headers["Content-Length"] == "10")
        #expect(ask("bytes=90-").body.count == 10)
        #expect(ask("bytes=0-999").body.count == 100)
        #expect(ask("bytes=-5").body.count == 5)
        #expect(ask("bytes=200-300").status == 416)
        // A window onto larger data still answers with the right bytes.
        let slice = (Data([9, 9]) + bytes)[2...]
        #expect(Array(SceneAssets.ranged(slice, mime: "video/mp4", range: "bytes=0-1").body) == [0, 1])
    }
}
