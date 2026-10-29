// Draws the app icon and writes an .iconset (16...1024 px, @1x and @2x). scripts/make-icon.sh compiles this file together
// with Sources/LiveWallpaper/Logo.swift, which holds the drawing, and turns the iconset into AppIcon.icns.
// Usage: make-icon <output.iconset>
// Offscreen only: bitmaps, no window is created.
import AppKit

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-icon <output.iconset>\n".utf8))
    exit(2)
}
let directory = URL(filePath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for factor in [1, 2] {
        let name = factor == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        guard let data = Logo.iconPNG(pixels: base * factor) else { fatalError("could not draw \(name)") }
        try data.write(to: directory.appending(path: name))
    }
}
