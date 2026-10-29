// Draws the background of the installer window and a preview of the finished window. Offscreen only: bitmaps, no
// window, no Finder. The layout below is the single source; scripts/make-dmg.sh reads it with `layout`.
//
//   swift scripts/dmg-background.swift layout                       prints: width height appX appY applicationsX applicationsY
//   swift scripts/dmg-background.swift background <dir>             writes background.png and background@2x.png
//   swift scripts/dmg-background.swift preview <AppIcon.icns> <out.png>   the window as Finder will draw it, at @2x
import AppKit

// Points, origin at the top left of the window content; icon centers, as Finder stores them.
let width = 660
let height = 400
let appCenter = CGPoint(x: 170, y: 200)
let applicationsCenter = CGPoint(x: 490, y: 200)
let iconSize: CGFloat = 128

func canvas(scale: Int, _ draw: (CGContext) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width * scale, pixelsHigh: height * scale, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    let graphics = NSGraphicsContext(bitmapImageRep: rep)!
    let context = graphics.cgContext
    context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    // Flip to a top-left origin so the numbers read like Finder's.
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 1, y: -1)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    draw(context)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func text(_ string: String, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat, at center: CGPoint, color: NSColor = .white) {
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color.withAlphaComponent(alpha),
        .paragraphStyle: style,
    ]
    let line = NSAttributedString(string: string, attributes: attributes)
    let box = line.size()
    line.draw(in: CGRect(x: center.x - CGFloat(width) / 2, y: center.y - box.height / 2, width: CGFloat(width), height: box.height))
}

func drawBackground(_ context: CGContext) {
    let space = CGColorSpaceCreateDeviceRGB()
    let full = CGRect(x: 0, y: 0, width: width, height: height)
    // Mid-tone on purpose: Finder draws the icon names in black or white by the system theme, and both read on it.
    let base = CGGradient(colorsSpace: space, colors: [
        CGColor(red: 0.26, green: 0.37, blue: 0.86, alpha: 1), CGColor(red: 0.52, green: 0.29, blue: 0.80, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(base, start: CGPoint(x: 0, y: 0), end: CGPoint(x: CGFloat(width), y: CGFloat(height)), options: [])

    func glow(_ center: CGPoint, radius: CGFloat, alpha: CGFloat) {
        let gradient = CGGradient(colorsSpace: space, colors: [
            CGColor(red: 1, green: 1, blue: 1, alpha: alpha), CGColor(red: 1, green: 1, blue: 1, alpha: 0),
        ] as CFArray, locations: [0, 1])!
        context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
    }
    glow(CGPoint(x: 120, y: 30), radius: 380, alpha: 0.30)
    glow(CGPoint(x: 330, y: 205), radius: 150, alpha: 0.16)
    glow(CGPoint(x: 600, y: 420), radius: 300, alpha: 0.18)

    // Soft waves along the bottom: a wallpaper that moves.
    context.saveGState()
    context.clip(to: full)
    for (index, amplitude) in [14.0, 10.0, 7.0].enumerated() {
        let wave = CGMutablePath()
        let base = CGFloat(height) - 26 - CGFloat(index) * 16
        wave.move(to: CGPoint(x: -4, y: base))
        var x = -4.0
        while x <= Double(width) + 4 {
            wave.addLine(to: CGPoint(x: x, y: base + CGFloat(sin(x / 58 + Double(index) * 1.7) * amplitude)))
            x += 4
        }
        context.addPath(wave)
        context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.10 - CGFloat(index) * 0.02))
        context.setLineWidth(2)
        context.strokePath()
    }
    context.restoreGState()

    // The arrow from the app to the Applications folder.
    let y = appCenter.y
    let start = appCenter.x + iconSize / 2 + 16
    let end = applicationsCenter.x - iconSize / 2 - 16
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: 2), blur: 8, color: CGColor(red: 0.1, green: 0.05, blue: 0.4, alpha: 0.5))
    context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.92))
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.92))
    context.setLineWidth(6)
    context.setLineCap(.round)
    context.move(to: CGPoint(x: start, y: y))
    context.addLine(to: CGPoint(x: end - 10, y: y))
    context.strokePath()
    context.move(to: CGPoint(x: end - 22, y: y - 16))
    context.addLine(to: CGPoint(x: end + 2, y: y))
    context.addLine(to: CGPoint(x: end - 22, y: y + 16))
    context.closePath()
    context.fillPath()
    context.restoreGState()

    text("Live Wallpaper", size: 30, weight: .bold, alpha: 1, at: CGPoint(x: CGFloat(width) / 2, y: 50))
    text("Живые обои для Mac  ·  Live wallpapers for Mac", size: 13, weight: .regular, alpha: 0.82, at: CGPoint(x: CGFloat(width) / 2, y: 80))
    text("Перетащите в Applications", size: 14, weight: .semibold, alpha: 1, at: CGPoint(x: CGFloat(width) / 2, y: y - 36))
    text("Drag to Applications", size: 12, weight: .regular, alpha: 0.8, at: CGPoint(x: CGFloat(width) / 2, y: y + 36))
    text("Первый запуск: Системные настройки → Конфиденциальность и безопасность → «Всё равно открыть»",
         size: 11, weight: .regular, alpha: 0.85, at: CGPoint(x: CGFloat(width) / 2, y: CGFloat(height) - 40))
    text("First launch: System Settings → Privacy & Security → “Open Anyway”",
         size: 11, weight: .regular, alpha: 0.7, at: CGPoint(x: CGFloat(width) / 2, y: CGFloat(height) - 24))
}

func write(_ rep: NSBitmapImageRep, to url: URL) throws {
    guard let data = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
    try data.write(to: url)
}

let arguments = CommandLine.arguments
switch arguments.dropFirst().first {
case "layout":
    print(width, height, Int(appCenter.x), Int(appCenter.y), Int(applicationsCenter.x), Int(applicationsCenter.y))
case "background" where arguments.count == 3:
    let directory = URL(filePath: arguments[2])
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try write(canvas(scale: 1, drawBackground), to: directory.appending(path: "background.png"))
    try write(canvas(scale: 2, drawBackground), to: directory.appending(path: "background@2x.png"))
case "preview" where arguments.count == 4:
    guard let icon = NSImage(contentsOf: URL(filePath: arguments[2])) else { fatalError("cannot read \(arguments[2])") }
    let folder = NSWorkspace.shared.icon(forFile: "/Applications")
    let rep = canvas(scale: 2) { context in
        drawBackground(context)
        for (image, center, name) in [(icon, appCenter, "LiveWallpaper"), (folder, applicationsCenter, "Applications")] {
            image.draw(in: CGRect(x: center.x - iconSize / 2, y: center.y - iconSize / 2, width: iconSize, height: iconSize),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            // Finder draws the names under the icons in the system label color; shown here for a light-mode window.
            text(name, size: 13, weight: .regular, alpha: 1, at: CGPoint(x: center.x, y: center.y + iconSize / 2 + 16), color: .black)
        }
    }
    try write(rep, to: URL(filePath: arguments[3]))
default:
    FileHandle.standardError.write(Data("usage: dmg-background.swift layout | background <dir> | preview <AppIcon.icns> <out.png>\n".utf8))
    exit(2)
}
