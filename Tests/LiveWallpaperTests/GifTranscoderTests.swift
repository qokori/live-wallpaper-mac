import AVFoundation
import Foundation
import Testing
import WallpaperCore
@testable import LiveWallpaper

@MainActor
@Suite struct GifTranscoderTests {
    private func directory() throws -> URL { try TestImages.tempDirectory() }

    @Test func theVideoKeepsTheSizeTheLoopLengthAndEveryFrame() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let gif = dir.appending(path: "a.gif")
        let delays = [0.1, 0.2, 0.1, 0.5, 0.1, 0.1]
        try TestImages.write(gif, size: (320, 240), delays: delays)
        let video = dir.appending(path: "out/a.mp4")
        try await GifTranscoder.convert(gif, to: video, maxSide: 3840)
        let asset = AVURLAsset(url: video)
        #expect(try await asset.load(.isPlayable))
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        #expect(size == CGSize(width: 320, height: 240))
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - delays.reduce(0, +)) < 0.05, "\(duration)")
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        #expect(reader.startReading())
        var times: [Double] = []
        while let sample = output.copyNextSampleBuffer() { times.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds) }
        #expect(times.count == delays.count, "\(times)")
        // Each frame appears when its own delay says: 0, 0.1, 0.3, 0.4, 0.9, 1.0
        let expected = [0, 0.1, 0.3, 0.4, 0.9, 1.0]
        #expect(zip(times.sorted(), expected).allSatisfy { abs($0 - $1) < 0.002 }, "\(times)")
    }

    @Test func aBigPictureIsCutToTheScreenAndTheSidesStayEven() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let gif = dir.appending(path: "b.gif")
        try TestImages.write(gif, size: (801, 451), delays: [0.1, 0.1])
        let info = try AnimatedImageInfo.read(gif)
        let size = GifTranscoder.outputSize(of: info, maxSide: 400)
        #expect(size.width == 400 && size.height % 2 == 0 && abs(Double(size.height) - 451 * 400 / 801) <= 2, "\(size)")
        let whole = GifTranscoder.outputSize(of: info, maxSide: 4000)
        #expect(whole.width == 800 && whole.height == 450, "a smaller screen never enlarges; odd sides round down to even: \(whole)")
    }

    @Test func aCancelledConversionLeavesNoFile() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let gif = dir.appending(path: "c.gif")
        try TestImages.write(gif, size: (640, 480), delays: Array(repeating: 0.04, count: 200))
        let video = dir.appending(path: "out/c.mp4")
        let task = Task { try await GifTranscoder.convert(gif, to: video, maxSide: 3840) }
        task.cancel()
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: video.path))
        let left = (try? FileManager.default.contentsOfDirectory(atPath: dir.appending(path: "out").path)) ?? []
        #expect(left.isEmpty, "\(left)")
    }

    @Test func theNameFollowsTheFileAndChangesWithIt() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let gif = dir.appending(path: "My Loop.gif")
        try TestImages.write(gif, delays: [0.1, 0.1])
        let first = GifTranscoder.videoURL(for: gif, in: dir)
        #expect(first.lastPathComponent == "My Loop.mp4")
        #expect(GifTranscoder.videoURL(for: gif, in: dir) == first)
        try TestImages.write(gif, delays: [0.1, 0.1, 0.1])
        #expect(GifTranscoder.videoURL(for: gif, in: dir) != first, "a changed picture gets its own video")
    }
}

@MainActor
@Suite struct GifConversionOnAddTests {
    /// A 640x480 picture of 70 frames is 82 MiB decoded at this screen size: over the cache budget.
    private func bigGif(_ dir: URL, name: String = "big.gif") throws -> URL {
        let url = dir.appending(path: name)
        try TestImages.write(url, size: (640, 480), delays: Array(repeating: 0.04, count: 70))
        return url
    }

    private func model(_ box: Sandbox, side: Int = 2000) -> AppModel {
        AppModel(defaults: box.defaults, libraryStore: box.store, convertedDirectory: box.directory.appending(path: "Converted"), screenSide: { side })
    }

    @Test func aBigGifGoesIntoTheLibraryAsAVideoAndTheOriginalStays() async throws {
        let box = Sandbox()
        defer { box.cleanup() }
        try FileManager.default.createDirectory(at: box.directory, withIntermediateDirectories: true)
        let gif = try bigGif(box.directory)
        let before = try Data(contentsOf: gif)
        let model = model(box)
        #expect(await model.addToLibrary(WallpaperSource(kind: .gif, location: gif.path)))
        let item = try #require(model.library.items.first)
        #expect(item.source.kind == .video)
        #expect(item.source.title == "big.mp4")
        #expect(item.source.location.hasPrefix(box.directory.appending(path: "Converted").path))
        #expect(FileManager.default.fileExists(atPath: item.source.location))
        #expect(try Data(contentsOf: gif) == before, "the original is not touched")
        #expect(model.converting == nil)
    }

    @Test func aSmallGifStaysAGif() async throws {
        let box = Sandbox()
        defer { box.cleanup() }
        try FileManager.default.createDirectory(at: box.directory, withIntermediateDirectories: true)
        let gif = box.directory.appending(path: "small.gif")
        try TestImages.write(gif, size: (64, 48), delays: [0.1, 0.1, 0.1])
        let model = model(box)
        #expect(await model.addToLibrary(WallpaperSource(kind: .gif, location: gif.path)))
        #expect(model.library.items.first?.source.kind == .gif)
        #expect(!FileManager.default.fileExists(atPath: box.directory.appending(path: "Converted").path))
    }

    @Test func theSameGifAddedAgainReusesTheVideo() async throws {
        let box = Sandbox()
        defer { box.cleanup() }
        try FileManager.default.createDirectory(at: box.directory, withIntermediateDirectories: true)
        let gif = try bigGif(box.directory)
        let model = model(box)
        _ = await model.addToLibrary(WallpaperSource(kind: .gif, location: gif.path))
        let path = try #require(model.library.items.first?.source.location)
        let made = try #require(try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)
        _ = await model.addToLibrary(WallpaperSource(kind: .gif, location: gif.path))
        #expect(model.library.items.count == 1)
        #expect(try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date == made)
    }

    @Test func aConversionThatFailsLeavesTheGifAsItWas() async throws {
        let box = Sandbox()
        defer { box.cleanup() }
        try FileManager.default.createDirectory(at: box.directory, withIntermediateDirectories: true)
        let gif = try bigGif(box.directory)
        // The cache folder cannot be made: a file sits where it should be.
        let blocker = box.directory.appending(path: "Converted")
        try Data().write(to: blocker)
        let model = model(box)
        #expect(await model.addToLibrary(WallpaperSource(kind: .gif, location: gif.path)))
        #expect(model.library.items.first?.source.kind == .gif)
        #expect(model.notice == nil)
    }

    @Test func removingTheItemDeletesTheVideoButNotTheGif() async throws {
        let box = Sandbox()
        defer { box.cleanup() }
        try FileManager.default.createDirectory(at: box.directory, withIntermediateDirectories: true)
        let gif = try bigGif(box.directory)
        let model = model(box)
        _ = await model.addToLibrary(WallpaperSource(kind: .gif, location: gif.path))
        let item = try #require(model.library.items.first)
        model.removeFromLibrary(item)
        #expect(!FileManager.default.fileExists(atPath: item.source.location))
        #expect(FileManager.default.fileExists(atPath: gif.path))
    }
}
