import AppKit
import Testing
@testable import LiveWallpaper

@Suite struct LogoTests {
    private func pixels(_ data: Data) -> NSBitmapImageRep? { NSBitmapImageRep(data: data) }

    private func color(_ rep: NSBitmapImageRep, _ x: Double, _ y: Double) -> NSColor? {
        rep.colorAt(x: Int(x * Double(rep.pixelsWide - 1)), y: Int(y * Double(rep.pixelsHigh - 1)))?.usingColorSpace(.deviceRGB)
    }

    @Test func theIconIsAWhiteTileWithBlackStripesAndTransparentCorners() throws {
        let png = try #require(Logo.iconPNG(pixels: 1024))
        let rep = try #require(pixels(png))
        #expect(rep.pixelsWide == 1024)
        // The corner is outside the 824-point tile.
        #expect(color(rep, 0.01, 0.01)?.alphaComponent == 0)
        // The tile margin inside the stripes' field is white; the field holds black.
        let margin = try #require(color(rep, 0.13, 0.5))
        #expect(margin.alphaComponent > 0.99 && margin.redComponent > 0.99)
        var darkest = 1.0
        for i in 0..<200 { darkest = min(darkest, color(rep, 0.5, 0.2 + Double(i) / 400)?.redComponent ?? 1) }
        #expect(darkest < 0.05)
    }

    @Test func smallSizesUseFewerStripes() {
        #expect(Logo.stripeCount(pixels: 1024) == 9 && Logo.stripeCount(pixels: 64) == 6)
        #expect(Logo.stripeCount(pixels: 32) == 4 && Logo.stripeCount(pixels: 16) == 3)
        #expect(Logo.iconPNG(pixels: 16) != nil)
    }

    @Test func theMenuBarMarkIsAnEighteenPointTemplateThatChangesWithPlayback() throws {
        let playing = Logo.menuBar(playing: true)
        let paused = Logo.menuBar(playing: false)
        #expect(playing.isTemplate && paused.isTemplate)
        #expect(playing.size == NSSize(width: 18, height: 18))
        func data(_ image: NSImage) throws -> Data { try #require(image.tiffRepresentation) }
        #expect(try data(playing) != data(paused), "волнистые и прямые полосы различаются")
    }
}
