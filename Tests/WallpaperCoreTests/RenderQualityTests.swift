import Testing
@testable import WallpaperCore

@Suite struct RenderQualityTests {
    @Test func theStandardsAre30FramesAndTheScreen() {
        #expect(RenderQuality.standardFrameRate == 30)
        #expect(RenderQuality.standard == .screen)
        #expect(RenderQuality(stored: nil) == .screen)
        #expect(RenderQuality(stored: "nonsense") == .screen)
    }

    @Test func sixtyAndMaximumStayAvailable() {
        #expect(RenderQuality.frameRates == [15, 30, 60])
        #expect(RenderQuality.frameRate(60) == 60 && RenderQuality.frameRate(15) == 15)
        #expect(RenderQuality.frameRate(45) == 30 && RenderQuality.frameRate(0) == 30)
        #expect(RenderQuality(stored: "maximum") == .maximum)
        #expect(RenderQuality.allCases.map(\.rawValue) == ["economy", "screen", "maximum"])
    }

    @Test func eachLevelSpendsAsItSays() {
        #expect(RenderQuality.economy.canvasRatio(devicePixelRatio: 2) == 1)
        #expect(RenderQuality.screen.canvasRatio(devicePixelRatio: 2) == 2)
        #expect(RenderQuality.maximum.canvasRatio(devicePixelRatio: 3) == 2)
        #expect(RenderQuality.economy.pictureScale == 0.5 && RenderQuality.screen.pictureScale == 1 && RenderQuality.maximum.pictureScale == 1)
        #expect(RenderQuality.economy.shrinksVideo && RenderQuality.screen.shrinksVideo && !RenderQuality.maximum.shrinksVideo)
    }
}
