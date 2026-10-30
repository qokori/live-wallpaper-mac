import AppKit

/// The logo: black wavy stripes, on a white macOS tile for the app icon and alone, as a template image, for the menu bar
/// and the window. Own paths only. `scripts/make-icon.swift` compiles this file to draw the icon, so it uses AppKit only.
enum Logo {
    /// Everything is laid out on a 1024-point canvas; the stripes fill the 700-point square at 162...862.
    private static let field = CGRect(x: 162, y: 162, width: 700, height: 700)

    /// The stripes' count for an icon of this many pixels: fewer and thicker when small.
    static func stripeCount(pixels: Int) -> Int {
        pixels >= 512 ? 9 : pixels >= 64 ? 6 : pixels >= 32 ? 4 : 3
    }

    /// Horizontal stripes in `field`, each bent by a sine wave whose phase grows with the stripe: they "flow".
    /// `wavy: false` draws them straight (the paused state of the menu bar mark). Points on the 1024-point canvas, y up.
    private static func stripeLines(count: Int, wavy: Bool) -> [(points: [CGPoint], width: CGFloat)] {
        let pitch = field.width / CGFloat(count)
        return (0..<count).map { i in
            let base = field.minY + pitch * (CGFloat(i) + 0.5)
            let points = stride(from: CGFloat(60), through: 964, by: 4).map { x -> CGPoint in
                let bend = wavy ? pitch * 0.55 * sin((x - 100) / 824 * 2 * .pi + CGFloat(i) * 0.55) : 0
                return CGPoint(x: x, y: base + bend)
            }
            return (points, pitch * 0.5)
        }
    }

    private static func drawStripes(_ ctx: CGContext, count: Int, wavy: Bool, color: NSColor) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        color.setStroke()
        for line in stripeLines(count: count, wavy: wavy) {
            let path = NSBezierPath()
            path.move(to: line.points[0])
            for point in line.points.dropFirst() { path.line(to: point) }
            path.lineWidth = line.width
            path.stroke()
        }
    }

    /// The stripes as the SVG layer of an Icon Composer icon (`.icon`): the same drawing, black, on a transparent 1024
    /// canvas. The system icon grid has no margin there (the system cuts the tile), so the 824-point tile of
    /// `iconPNG` is stretched over the whole canvas and the stripes with it.
    static func iconLayerSVG(stripes: Int = 9) -> String {
        let k = 1024.0 / 824.0
        func x(_ value: CGFloat) -> String { String(format: "%.2f", (value - 100) * k) }
        func y(_ value: CGFloat) -> String { String(format: "%.2f", 1024 - (value - 100) * k) }
        let clip = String(format: "x=\"%.2f\" y=\"%.2f\" width=\"%.2f\" height=\"%.2f\" rx=\"%.2f\"",
                          (field.minX - 100) * k, 1024 - (field.maxY - 100) * k, field.width * k, field.height * k, 125 * k)
        var paths = ""
        for line in stripeLines(count: stripes, wavy: true) {
            let d = line.points.enumerated().map { "\($0.offset == 0 ? "M" : "L")\(x($0.element.x)) \(y($0.element.y))" }.joined(separator: " ")
            paths += "    <path d=\"\(d)\" fill=\"none\" stroke=\"#000000\" stroke-width=\"\(String(format: "%.2f", line.width * k))\"/>\n"
        }
        return """
        <svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
          <defs><clipPath id="field"><rect \(clip)/></clipPath></defs>
          <g clip-path="url(#field)">
        \(paths)  </g>
        </svg>

        """
    }

    private static var fieldShape: NSBezierPath { NSBezierPath(roundedRect: field, xRadius: 125, yRadius: 125) }

    /// The app icon at a pixel size: a white tile (824 on the 1024 grid, 100 of margin) with the stripes and the
    /// system icons' shadow. PNG data.
    static func iconPNG(pixels: Int) -> Data? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let graphics = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        defer { NSGraphicsContext.restoreGraphicsState() }
        let ctx = graphics.cgContext
        ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        draw(in: ctx, stripes: stripeCount(pixels: pixels))
        return rep.representation(using: .png, properties: [:])
    }

    /// The icon as an image (the Dock icon when the app runs outside a bundle).
    static func icon(size: Int = 512) -> NSImage {
        iconPNG(pixels: size).flatMap { NSImage(data: $0) } ?? NSImage()
    }

    private static func draw(in ctx: CGContext, stripes: Int) {
        let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
        let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
        ctx.saveGState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
        shadow.shadowBlurRadius = 14
        shadow.shadowOffset = NSSize(width: 0, height: -7)
        shadow.set()
        NSColor.white.setFill()
        shape.fill()
        ctx.restoreGState()
        ctx.saveGState()
        fieldShape.addClip()
        drawStripes(ctx, count: stripes, wavy: true, color: .black)
        ctx.restoreGState()
    }

    /// The stripes alone as a template image (the system colours it for light and dark): `size` points square.
    /// Playing: wavy; paused: straight.
    static func template(size: CGFloat, playing: Bool = true, stripes: Int = 4) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.saveGState()
            let scale = rect.width / field.width
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -field.minX, y: -field.minY)
            fieldShape.addClip()
            drawStripes(ctx, count: stripes, wavy: playing, color: .black)
            ctx.restoreGState()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Live Wallpaper"
        return image
    }

    /// The menu bar's picture: 18 points.
    static func menuBar(playing: Bool) -> NSImage { template(size: 18, playing: playing) }
}
