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
        // A 4096-pixel picture on a 1920-pixel canvas.
        #expect(RenderQuality.maximum.pictureScale(side: 4096, canvasSide: 1920) == 1)
        #expect(RenderQuality.screen.pictureScale(side: 4096, canvasSide: 1920) == 1920.0 / 4096)
        #expect(RenderQuality.economy.pictureScale(side: 4096, canvasSide: 1920) == 1920.0 / 4096)
        #expect(RenderQuality.economy.pictureScale(side: 8192, canvasSide: 3000) == 3000.0 / 8192)
        #expect(RenderQuality.economy.pictureScale(side: 2000, canvasSide: 3000) == 0.5)
        // A picture that fits the canvas: the screen level keeps it, economy halves it.
        #expect(RenderQuality.screen.pictureScale(side: 1024, canvasSide: 1920) == 1)
        #expect(RenderQuality.economy.pictureScale(side: 1024, canvasSide: 1920) == 0.5)
        // Small pictures and tiny canvases are left alone.
        #expect(RenderQuality.economy.pictureScale(side: 64, canvasSide: 1920) == 1)
        #expect(RenderQuality.screen.pictureScale(side: 400, canvasSide: 16) == 1)
    }
}
