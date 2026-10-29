import AppKit
import AVFoundation
import Foundation
import Testing
import WallpaperCore
import WallpaperEngineKit
import WebKit
@testable import LiveWallpaper

/// A two-frame MP4 made with AVAssetWriter, so a video project has something real to play.
enum TestVideo {
    static func write(_ url: URL, fill: UInt8? = nil, width: Int = 64, height: Int = 48) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for index in 0..<2 {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
            if let fill, let buffer {
                CVPixelBufferLockBaseAddress(buffer, [])
                memset(CVPixelBufferGetBaseAddress(buffer), Int32(fill), CVPixelBufferGetBytesPerRow(buffer) * height)
                CVPixelBufferUnlockBaseAddress(buffer, [])
            }
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            adaptor.append(buffer!, withPresentationTime: CMTime(value: Int64(index), timescale: 2))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if let error = writer.error { throw error }
    }
}

@MainActor
@Suite struct EngineSupportTests {
    private func project(_ box: Sandbox, name: String = "p", type: String, file: String? = nil, preview: String? = "preview.jpg", extra: String = "") throws -> URL {
        let dir = box.directory.appending(path: name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var fields = ["\"type\":\"\(type)\"", "\"title\":\"Дождь в окне\""]
        if let file { fields.append("\"file\":\"\(file)\"") }
        if let preview { fields.append("\"preview\":\"\(preview)\"") }
        if !extra.isEmpty { fields.append(extra) }
        try Data("{\(fields.joined(separator: ","))}".utf8).write(to: dir.appending(path: "project.json"))
        return dir
    }

    private func writeStill(_ url: URL) throws {
        try TestImages.write(url.deletingPathExtension().appendingPathExtension("gif"), delays: [0.1, 0.1])
        // A one-frame JPEG made from the same solid picture.
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, TestImages.solid(64, 40, red: 0.3), nil)
        CGImageDestinationFinalize(destination)
    }

    private func source(_ url: URL) -> WallpaperSource {
        WallpaperSource(kind: WallpaperSource.Kind.detect(url: url), location: url.path, bookmark: try? url.bookmarkData())
    }

    @Test func aSceneIsAddedAsItsFolderNamedByTitleWhateverFileWasChosen() async throws {
        let box = Sandbox()
        defer { box.cleanup() }
        let dir = try project(box, type: "Scene", file: "scene.json")
        try writeStill(dir.appending(path: "preview.jpg"))
        try EngineFixtures.package.write(to: dir.appending(path: "scene.pkg"))
        for chosen in [dir, dir.appending(path: "project.json"), dir.appending(path: "scene.pkg")] {
            let model = box.model()
            #expect(await model.addToLibrary(source(chosen)), "\(chosen.lastPathComponent)")
            let item = try #require(model.library.items.first)
            #expect(item.source.kind == .wallpaperEngine)
            #expect(item.source.engine == .scene)
            #expect(URL(filePath: item.source.location).resolvingSymlinksInPath().path == dir.resolvingSymlinksInPath().path, "\(item.source.location) vs \(dir.path)")
            #expect(item.title == "Дождь в окне")
            try? FileManager.default.removeItem(at: box.store.fileURL)
        }
    }

    @Test func aRenamedItemKeepsItsNameWhenAddedAgain() async throws {
        let box = Sandbox()
        defer { box.cleanup() }
        let dir = try project(box, type: "scene", file: "scene.json")
        try writeStill(dir.appending(path: "preview.jpg"))
        let model = box.model()
        await model.addToLibrary(source(dir))
        let id = try #require(model.library.items.first?.id)
        model.library.rename(id: id, to: "Мой дождь")
        await model.addToLibrary(source(dir))
        #expect(model.library.items.count == 1)
        #expect(model.library.items.first?.title == "Мой дождь")
    }

    @Test(arguments: [
        ("application", "run.exe", "программа для Windows"),
        ("hologram", "x", "Неизвестный тип"),
        ("video", "clip.webm", "webm"),
        ("video", "clip.avi", "avi"),
        ("video", "missing.mp4", "нет файла"),
        ("web", "index.html", "нет файла"),
    ])
    func projectsThatCannotBeShownAreRefusedWithAReason(type: String, file: String, reason: String) async throws {
        let box = Sandbox()
        defer { box.cleanup() }
        let dir = try project(box, type: type, file: file)
        if file.hasPrefix("clip") { try Data([0]).write(to: dir.appending(path: file)) }
        let model = box.model()
        #expect(await !model.addToLibrary(source(dir)))
        #expect(model.notice?.text.contains(reason) == true, "\(model.notice?.text ?? "nil")")
        #expect(model.library.items.isEmpty)
    }

    @Test func aSceneWithNeitherPackageNorPreviewIsRefused() async throws {
        let box = Sandbox()
        defer { box.cleanup() }
        let dir = try project(box, type: "scene", file: "scene.json", preview: nil)
        let model = box.model()
        #expect(await !model.addToLibrary(source(dir)))
        #expect(model.notice?.text == EngineSourceError.noPackage.localizedDescription)
    }

    @Test func aMacInstallerIsRefusedByName() async throws {
        let box = Sandbox()
        defer { box.cleanup() }
        let dir = try project(box, type: "scene", file: "scene.json")
        let installer = dir.appending(path: "Setup.pkg")
        try (Data("xar!".utf8) + Data(repeating: 0, count: 80)).write(to: installer)
        let model = box.model()
        #expect(await !model.addToLibrary(source(installer)))
        #expect(model.notice?.text.contains("установщик macOS") == true)
    }

    @Test func aFolderWithoutAProjectFileIsRefusedAsAProject() async throws {
        let box = Sandbox()
        defer { box.cleanup() }
        try FileManager.default.createDirectory(at: box.directory, withIntermediateDirectories: true)
        let model = box.model()
        #expect(await !model.addToLibrary(WallpaperSource(kind: .wallpaperEngine, location: box.directory.path)))
        #expect(model.notice?.text.contains("project.json") == true)
    }

    @Test func aVideoProjectPlaysItsFileAndTheFirstFrameIsTheDesktopPicture() async throws {
        let box = Sandbox()
        defer { box.cleanup() }
        let dir = try project(box, type: "video", file: "Clip.MP4")
        try await TestVideo.write(dir.appending(path: "Clip.MP4"))
        let model = box.model()
        #expect(await model.addToLibrary(source(dir)))
        let item = try #require(model.library.items.first)
        #expect(item.source.engine == .video)
        let content = try EngineSupport.content(for: item.source, frameRate: 30, label: "t")
        #expect(content is VideoContent)
        #expect(EngineSupport.frameURL(of: item.source)?.lastPathComponent == "Clip.MP4")
    }

    @Test func aSceneShowsItsPreviewAsAStillOrAnAnimation() async throws {
        let box = Sandbox()
        defer { box.cleanup() }
        let still = try project(box, name: "still", type: "scene", file: "scene.json", preview: "preview.jpg")
        try writeStill(still.appending(path: "preview.jpg"))
        let animated = try project(box, name: "animated", type: "scene", file: "scene.json", preview: "preview.gif")
        try TestImages.write(animated.appending(path: "preview.gif"), delays: [0.1, 0.1, 0.1])
        let model = box.model()
        #expect(await model.addToLibrary(source(still)))
        #expect(await model.addToLibrary(source(animated)))
        let sources = model.library.items.map(\.source)
        #expect(try EngineSupport.content(for: sources[0], frameRate: 30, label: "t") is StillContent)
        #expect(try EngineSupport.content(for: sources[1], frameRate: 30, label: "t") is GifContent)
        #expect(EngineSupport.frameURL(of: sources[0])?.lastPathComponent == "preview.jpg")
        #expect(EngineSupport.frameURL(of: sources[1])?.lastPathComponent == "preview.gif")
    }

    @Test func aStillPreviewFillsTheLayerAndFollowsScaling() async throws {
        let box = Sandbox()
        defer { box.cleanup() }
        let dir = try project(box, type: "scene", file: "scene.json")
        try writeStill(dir.appending(path: "preview.jpg"))
        let content = StillContent(url: dir.appending(path: "preview.jpg"), label: "t")
        var ready = false
        content.start(ready: { ready = true }, failed: { _ in })
        #expect(ready)
        #expect(content.view.layer?.contents != nil)
        content.setScaling(.fit)
        #expect(content.view.layer?.contentsGravity == .resizeAspect)
        content.stop()
        #expect(content.view.layer?.contents == nil)
    }

    @Test func theCardThumbnailIsThePreview() async throws {
        let box = Sandbox()
        defer { box.cleanup() }
        let dir = try project(box, type: "scene", file: "scene.json")
        try writeStill(dir.appending(path: "preview.jpg"))
        let model = box.model()
        await model.addToLibrary(source(dir))
        let thumbnails = Thumbnails()
        let item = try #require(model.library.items.first)
        await thumbnails.load(item)
        #expect(thumbnails.images[item.id] != nil)
    }

    @Test func aWebProjectGetsItsSettingsAndTheFrameRateWhenTheCardLoads() async throws {
        let box = Sandbox()
        defer { box.cleanup() }
        let dir = try project(box, type: "web", file: "index.html", extra: """
        "general":{"properties":{"schemecolor":{"type":"color","value":"0.25 0.5 1","order":0},"glow":{"type":"bool","value":true,"order":1}}}
        """)
        let page = """
        <!doctype html><title>start</title><script>
        window.wallpaperPropertyListener = {
          applyUserProperties(p) { window.got = (window.got || []).concat('user:' + p.schemecolor.value + ':' + p.glow.value); document.title = window.got.join('|'); },
          applyGeneralProperties(g) { window.got = (window.got || []).concat('fps:' + g.fps); document.title = window.got.join('|'); },
          setPaused(v) { window.got = (window.got || []).concat('paused:' + v); document.title = window.got.join('|'); },
        };
        window.wallpaperRegisterAudioListener(() => {});
        </script>
        """
        try Data(page.utf8).write(to: dir.appending(path: "index.html"))
        let model = box.model()
        #expect(await model.addToLibrary(source(dir)))
        let item = try #require(model.library.items.first)
        #expect(item.source.engine == .web)
        #expect(item.source.isPage)
        let content = try EngineSupport.content(for: item.source, frameRate: 30, label: "t")
        let web = try #require(content as? WebContent)
        var loaded = false
        web.start(ready: { loaded = true }, failed: { _ in })
        let webView = try #require(web.view.subviews.compactMap { $0 as? WKWebView }.first)
        for _ in 0..<200 where !(loaded && (webView.title ?? "").contains("fps:")) { try await Task.sleep(for: .milliseconds(50)) }
        let first = webView.title ?? ""
        #expect(first.contains("fps:30"), "\(first)")
        #expect(first.contains("user:0.25 0.5 1:true"), "\(first)")
        // Our pause reaches the page's listener, and the frame rate follows the menu.
        web.setPlaying(true)
        web.setFrameRate(60)
        for _ in 0..<100 where !(webView.title ?? "").contains("fps:60") { try await Task.sleep(for: .milliseconds(50)) }
        #expect((webView.title ?? "").contains("fps:60"), "\(webView.title ?? "")")
        web.setPlaying(false)
        for _ in 0..<100 where !(webView.title ?? "").hasSuffix("paused:true") { try await Task.sleep(for: .milliseconds(50)) }
        #expect((webView.title ?? "").hasSuffix("paused:true"), "\(webView.title ?? "")")
        web.stop()
    }

    /// LW_WE_SAMPLES: real Workshop projects, added the way a person adds them. Skipped without the variable.
    @Test func realSamplesAreAcceptedAndHaveCards() async throws {
        guard let path = ProcessInfo.processInfo.environment["LW_WE_SAMPLES"], !path.isEmpty else { return }
        let root = URL(filePath: (path as NSString).expandingTildeInPath)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).sorted()
        let box = Sandbox()
        defer { box.cleanup() }
        let model = box.model()
        let thumbnails = Thumbnails()
        var added = 0
        for name in names where FileManager.default.fileExists(atPath: root.appending(path: name + "/project.json").path) {
            let folder = root.appending(path: name)
            #expect(await model.addToLibrary(source(folder)), "\(name): \(model.notice?.text ?? "")")
            let item = try #require(model.library.items.last)
            await thumbnails.load(item)
            #expect(thumbnails.images[item.id] != nil, "\(name) has a card picture")
            _ = try EngineSupport.content(for: item.source, frameRate: 30, label: name)
            #expect(EngineSupport.frameURL(of: item.source) != nil || item.source.isPage)
            added += 1
        }
        #expect(added > 0 && added == model.library.items.count)
    }
}


extension EngineFixtures {
    /// A valid, tiny scene package.
    static var package: Data { pkg(entries: [("scene.json", Data("{}".utf8))]) }
}
