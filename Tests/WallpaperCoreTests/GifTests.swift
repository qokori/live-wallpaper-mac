import Foundation
import ImageIO
import Testing
@testable import WallpaperCore

@Suite struct FrameDelayTests {
    private func gif(_ unclamped: Double? = nil, _ clamped: Double? = nil) -> [String: Any] {
        var dictionary: [String: Any] = [:]
        if let unclamped { dictionary[kCGImagePropertyGIFUnclampedDelayTime as String] = unclamped }
        if let clamped { dictionary[kCGImagePropertyGIFDelayTime as String] = clamped }
        return dictionary
    }

    @Test func unclampedDelayWins() {
        #expect(FrameTimeline.delay(gif: gif(0.04, 0.1), png: nil) == 0.04)
    }

    @Test func clampedDelayIsUsedWithoutTheUnclampedOne() {
        #expect(FrameTimeline.delay(gif: gif(nil, 0.2), png: nil) == 0.2)
    }

    @Test func zeroAndHundredthOfASecondBecomeTenthLikeInBrowsers() {
        #expect(FrameTimeline.delay(gif: gif(0, 0), png: nil) == 0.1)
        #expect(FrameTimeline.delay(gif: gif(0.01), png: nil) == 0.1)
        #expect(FrameTimeline.delay(gif: gif(0.02), png: nil) == 0.02)
    }

    @Test func missingDelayIsATenth() {
        #expect(FrameTimeline.delay(gif: nil, png: nil) == 0.1)
        #expect(FrameTimeline.delay(gif: [:], png: [:]) == 0.1)
    }

    @Test func apngDelayIsRead() {
        #expect(FrameTimeline.delay(gif: nil, png: [kCGImagePropertyAPNGUnclampedDelayTime as String: 0.5]) == 0.5)
        #expect(FrameTimeline.delay(gif: nil, png: [kCGImagePropertyAPNGDelayTime as String: 0.25]) == 0.25)
    }
}

@Suite struct FrameTimelineTests {
    let timeline = FrameTimeline(delays: [0.1, 0.2, 0.1])

    @Test func durationIsTheSumOfDelays() {
        #expect(abs(timeline.duration - 0.4) < 1e-9)
        #expect(timeline.frameCount == 3)
    }

    @Test func eachFrameIsShownForItsOwnDelay() {
        #expect(timeline.frame(at: 0) == 0)
        #expect(timeline.frame(at: 0.099) == 0)
        #expect(timeline.frame(at: 0.1) == 1)
        #expect(timeline.frame(at: 0.299) == 1)
        #expect(timeline.frame(at: 0.3) == 2)
        #expect(timeline.frame(at: 0.399) == 2)
    }

    @Test func theLoopNeverEnds() {
        #expect(timeline.frame(at: 0.4) == 0)
        #expect(timeline.frame(at: 0.55) == 1)
        #expect(timeline.frame(at: 400.25) == 1)
        #expect(timeline.frame(at: 1_000_000.05) == 0)
    }

    @Test func waitsUntilTheNextFrameStarts() {
        #expect(abs(timeline.untilNextFrame(after: 0) - 0.1) < 1e-9)
        #expect(abs(timeline.untilNextFrame(after: 0.15) - 0.15) < 1e-9)
        #expect(abs(timeline.untilNextFrame(after: 0.35) - 0.05) < 1e-9)
        #expect(abs(timeline.untilNextFrame(after: 0.45) - 0.05) < 1e-9)
    }

    @Test func oneFrameOrNoneNeverAdvances() {
        #expect(FrameTimeline(delays: [0.1]).frame(at: 5) == 0)
        #expect(FrameTimeline(delays: [0.1]).untilNextFrame(after: 5) == .infinity)
        #expect(FrameTimeline(delays: []).frame(at: 5) == 0)
    }
}

@Suite struct AnimatedImageTests {
    @Test func readsDelaysAndSizeOfAGif() throws {
        let dir = try TestImages.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "a.gif")
        try TestImages.write(url, size: (40, 30), delays: [0.05, 0.2, 0.5, 0])
        let info = try AnimatedImageInfo.read(url)
        #expect(info.frameCount == 4)
        #expect(info.pixelWidth == 40 && info.pixelHeight == 30)
        #expect(info.timeline.delays.count == 4)
        #expect(abs(info.timeline.delays[0] - 0.05) < 0.011)
        #expect(abs(info.timeline.delays[1] - 0.2) < 0.011)
        #expect(abs(info.timeline.delays[2] - 0.5) < 0.011)
        #expect(info.timeline.delays[3] == 0.1) // 0 is read as a tenth
        #expect(info.frameBytes == 40 * 30 * 4)
    }

    @Test func readsDelaysOfAnApng() throws {
        let dir = try TestImages.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "a.png")
        try TestImages.write(url, delays: [0.3, 0.6], apng: true)
        let info = try AnimatedImageInfo.read(url)
        #expect(info.frameCount == 2)
        #expect(abs(info.timeline.delays[0] - 0.3) < 0.011)
        #expect(abs(info.timeline.delays[1] - 0.6) < 0.011)
    }

    @Test func oneFrameIsNotAnAnimation() throws {
        let dir = try TestImages.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "still.gif")
        try TestImages.write(url, delays: [0.1])
        #expect(throws: AnimatedImageInfo.Failure.notAnimated) { try AnimatedImageInfo.read(url) }
    }

    @Test func aBrokenOrMissingFileIsUnreadable() throws {
        let dir = try TestImages.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let broken = dir.appending(path: "broken.gif")
        try Data("GIF89a-not-really".utf8).write(to: broken)
        #expect(throws: AnimatedImageInfo.Failure.unreadable) { try AnimatedImageInfo.read(broken) }
        #expect(throws: AnimatedImageInfo.Failure.unreadable) { try AnimatedImageInfo.read(dir.appending(path: "none.gif")) }
    }
}

@Suite struct FrameCachePolicyTests {
    @Test func smallPicturesStayDecoded() {
        #expect(FrameCachePolicy.keepsAllFrames(frameCount: 60, frameBytes: 480 * 270 * 4)) // 31 MB
    }

    @Test func bigPicturesDecodeOnDemand() {
        #expect(!FrameCachePolicy.keepsAllFrames(frameCount: 120, frameBytes: 1920 * 1080 * 4)) // 995 MB
    }

    @Test func aPictureBiggerThanTheScreenIsShrunk() {
        #expect(FrameCachePolicy.decodeSize(pixelWidth: 8000, pixelHeight: 4500, maxSide: 3456) == 3456)
        #expect(FrameCachePolicy.decodeSize(pixelWidth: 480, pixelHeight: 270, maxSide: 3456) == 480)
    }
}

@Suite struct GifScalingTests {
    @Test func layerGravityFollowsTheScalingChoice() {
        #expect(WallpaperScaling.fill.layerGravity == "resizeAspectFill")
        #expect(WallpaperScaling.fit.layerGravity == "resizeAspect")
        #expect(WallpaperScaling.stretch.layerGravity == "resize")
    }

    @Test func scalingAppliesToGifButNotToPages() {
        var assignments = WallpaperAssignments()
        assignments.apply(WallpaperSource(kind: .gif, location: "/g/a.gif"), to: .all)
        #expect(assignments.scalingApplies(forDisplay: nil))
        assignments.apply(WallpaperSource(kind: .web, location: "/p"), to: .all)
        #expect(!assignments.scalingApplies(forDisplay: nil))
    }
}

@Suite struct GifLibraryTests {
    let gif = WallpaperSource(kind: .gif, location: "/g/cat.gif", bookmark: Data([1, 2]))

    @Test func detectsGifAndApngByExtension() {
        #expect(WallpaperSource.Kind.detect(path: "/x/cat.gif", isDirectory: false) == .gif)
        #expect(WallpaperSource.Kind.detect(path: "/x/CAT.GIF", isDirectory: false) == .gif)
        #expect(WallpaperSource.Kind.detect(path: "/x/anim.apng", isDirectory: false) == .gif)
        #expect(WallpaperSource.Kind.detect(path: "/x/anim.png", isDirectory: false) == .gif)
        #expect(WallpaperSource.Kind.detect(path: "/x/clip.mp4", isDirectory: false) == .video)
        #expect(WallpaperSource.Kind.detect(path: "/x/gif", isDirectory: true) == .web)
    }

    @Test func gifIsSavedAndLoadedFromLibraryJson() throws {
        let dir = try TestImages.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LibraryStore(fileURL: dir.appending(path: "library.json"))
        var library = WallpaperLibrary()
        library.add(gif, now: Date(timeIntervalSince1970: 5))
        library.add(WallpaperSource(kind: .video, location: "/v/a.mov"), now: Date(timeIntervalSince1970: 6))
        try store.save(library)
        let json = try String(contentsOf: store.fileURL, encoding: .utf8)
        #expect(json.contains("\"kind\" : \"gif\""))
        let loaded = store.load()
        #expect(loaded == library)
        #expect(loaded.items.first?.source.kind == .gif)
    }

    @Test func gifAndVideoAtOnePathAreTwoItems() {
        var library = WallpaperLibrary()
        library.add(WallpaperSource(kind: .gif, location: "/x/a.gif"))
        library.add(WallpaperSource(kind: .video, location: "/x/a.gif"))
        #expect(library.items.count == 2)
    }

    @Test func aLibraryWrittenByVersion020StillLoads() throws {
        let dir = try TestImages.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = """
        {
          "items" : [
            { "added" : 1000, "id" : "A1", "name" : "Дождь",
              "source" : { "bookmark" : "AQI=", "kind" : "video", "location" : "/v/rain.mov" } },
            { "added" : 2000, "id" : "B2",
              "source" : { "kind" : "web", "location" : "https://example.com/w" } }
          ]
        }
        """
        let file = dir.appending(path: "library.json")
        try Data(old.utf8).write(to: file)
        let library = LibraryStore(fileURL: file).load()
        #expect(library.items.map(\.id) == ["A1", "B2"])
        #expect(library.items.map(\.source.kind) == [.video, .web])
        #expect(library.items[0].title == "Дождь")
        #expect(library.items[0].source.bookmark == Data([1, 2]))
    }

    @Test func assignmentsWithGifSurviveTheEncoder() throws {
        var assignments = WallpaperAssignments()
        assignments.apply(gif, to: .display("UUID-1"))
        let data = try JSONEncoder().encode(assignments)
        #expect(try JSONDecoder().decode(WallpaperAssignments.self, from: data) == assignments)
    }
}
