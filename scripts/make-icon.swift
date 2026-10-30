// Draws the app icon and writes an .iconset (16...1024 px, @1x and @2x). scripts/make-icon.sh compiles this file together
// with Sources/LiveWallpaper/Logo.swift, which holds the drawing, and turns the iconset into AppIcon.icns.
// Usage: make-icon <output.iconset>
// Offscreen only: bitmaps, no window is created.
import AppKit

// make-icon --icon <AppIcon.icon>: the Icon Composer icon (icon.json and the layers), for `actool`; the system tints it.
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--icon" {
    let bundle = URL(filePath: CommandLine.arguments[2])
    try FileManager.default.createDirectory(at: bundle.appending(path: "Assets"), withIntermediateDirectories: true)
    try Data(Logo.iconLayerSVG().utf8).write(to: bundle.appending(path: "Assets/waves.svg"))
    // White background, black waves; in the dark appearance the other way round. Tinted and clear are made by the system.
    let json = """
    {
      "fill": { "solid": "srgb:1.00000,1.00000,1.00000,1.00000" },
      "fill-specializations": [
        { "appearance": "dark", "value": { "solid": "srgb:0.11000,0.11000,0.12000,1.00000" } }
      ],
      "groups": [
        {
          "layers": [
            {
              "image-name": "waves.svg",
              "name": "waves",
              "glass": false,
              "fill-specializations": [
                { "appearance": "dark", "value": { "solid": "srgb:1.00000,1.00000,1.00000,1.00000" } }
              ]
            }
          ],
          "shadow": { "kind": "neutral", "opacity": 0.5 },
          "translucency": { "enabled": false, "value": 0 }
        }
      ],
      "supported-platforms": { "squares": ["macOS"] }
    }

    """
    try Data(json.utf8).write(to: bundle.appending(path: "icon.json"))
    exit(0)
}
guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-icon <output.iconset> | make-icon --icon <AppIcon.icon>\n".utf8))
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
