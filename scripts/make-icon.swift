// Draws the app icon and writes an .iconset (16...1024 px, @1x and @2x). scripts/make-icon.sh turns it into AppIcon.icns.
// Usage: swift scripts/make-icon.swift <output.iconset>
// Offscreen only: bitmaps and SF Symbols, no window is created.
import AppKit

func drawIcon(pixels: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ), let graphics = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    defer { NSGraphicsContext.restoreGraphicsState() }

    // Everything is laid out on a 1024-point canvas and scaled to the pixel size.
    let scale = CGFloat(pixels) / 1024
    graphics.cgContext.scaleBy(x: scale, y: scale)

    // The macOS icon grid: an 824-point tile with 100 points of margin.
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)

    graphics.cgContext.saveGState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 16
    shadow.shadowOffset = NSSize(width: 0, height: -8)
    shadow.set()
    NSColor(red: 0.20, green: 0.45, blue: 0.95, alpha: 1).setFill()
    shape.fill()
    graphics.cgContext.restoreGState()

    NSGradient(colors: [NSColor(red: 0.20, green: 0.45, blue: 0.95, alpha: 1), NSColor(red: 0.55, green: 0.25, blue: 0.85, alpha: 1)])?
        .draw(in: shape, angle: -60)

    // A soft glow from the top left, the "live" part of the picture.
    graphics.cgContext.saveGState()
    shape.addClip()
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.38), NSColor.white.withAlphaComponent(0)])?
        .draw(fromCenter: NSPoint(x: 330, y: 800), radius: 0, toCenter: NSPoint(x: 330, y: 800), radius: 520, options: [])
    graphics.cgContext.restoreGState()

    // The menu bar symbol, "play.rectangle.fill": a white screen with a play triangle cut out of it.
    // A second screen peeking out behind it: wallpapers come in layers.
    NSColor.white.withAlphaComponent(0.42).setFill()
    NSBezierPath(roundedRect: NSRect(x: 322, y: 392, width: 380, height: 350), xRadius: 72, yRadius: 72).fill()
    let screen = NSBezierPath(roundedRect: NSRect(x: 272, y: 337, width: 480, height: 350), xRadius: 72, yRadius: 72)
    let play = NSBezierPath()
    play.move(to: NSPoint(x: 458, y: 440))
    play.line(to: NSPoint(x: 458, y: 584))
    play.line(to: NSPoint(x: 590, y: 512))
    play.close()
    screen.append(play)
    screen.windingRule = .evenOdd
    graphics.cgContext.saveGState()
    let lift = NSShadow()
    lift.shadowColor = NSColor.black.withAlphaComponent(0.25)
    lift.shadowBlurRadius = 24
    lift.shadowOffset = NSSize(width: 0, height: -10)
    lift.set()
    NSColor.white.setFill()
    screen.fill()
    graphics.cgContext.restoreGState()
    return rep.representation(using: .png, properties: [:])
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <output.iconset>\n".utf8))
    exit(2)
}
let directory = URL(filePath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for factor in [1, 2] {
        let name = factor == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        guard let data = drawIcon(pixels: base * factor) else { fatalError("could not draw \(name)") }
        try data.write(to: directory.appending(path: name))
    }
}
