import AppKit
import Foundation

/// Wallpaper Engine files built in code (the kit's own tests have the full set; here only what the app tests need).
enum EngineFixtures {
    static func int32(_ value: Int) -> [UInt8] {
        let v = UInt32(bitPattern: Int32(truncatingIfNeeded: value))
        return [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)]
    }

    static func string(_ text: String) -> [UInt8] {
        let bytes = Array(text.utf8)
        return int32(bytes.count) + bytes
    }

    static func pkg(entries: [(String, Data)], version: String = "PKGV0024") -> Data {
        var table: [UInt8] = string(version) + int32(entries.count)
        var body = Data()
        for (path, bytes) in entries {
            table += string(path) + int32(body.count) + int32(bytes.count)
            body.append(bytes)
        }
        return Data(table) + body
    }

    /// A `.tex` with one uncompressed RGBA picture (container TEXB0003) or any bytes in the first mip (an MP4, a PNG).
    static func tex(width: Int, height: Int, bytes: [UInt8], format: Int = 0, flags: Int = 2) -> Data {
        var out = Array("TEXV0005".utf8) + [0] + Array("TEXI0001".utf8) + [0]
        out += int32(format) + int32(flags) + int32(width) + int32(height) + int32(width) + int32(height) + int32(0)
        out += Array("TEXB0003".utf8) + [0] + int32(1) + int32(-1)
        out += int32(1) + int32(width) + int32(height) + int32(0) + int32(bytes.count) + int32(bytes.count) + bytes
        return Data(out)
    }

    /// A 1x1 texture of one colour (0...1 per channel).
    static func solid(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> Data {
        tex(width: 1, height: 1, bytes: [r, g, b, a].map { UInt8(($0 * 255).rounded()) })
    }

    /// A small PNG of one colour.
    static func png(width: Int, height: Int) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }

    struct Layer {
        var name: String
        var texture: Data
        var origin = "50 30 0"
        var size = "100 60"
        var scale = "1 1 1"
        var alpha = 1.0
        var blendMode = 0
        var blending = "translucent"
        var depth: String?
    }

    /// A project folder with a scene of the given layers on a 100x60 canvas, parallax optional.
    static func scene(
        in folder: URL, layers: [Layer], clear: String = "0.5 0.5 0.5", parallax: String = "false",
        amount: Double = 0.1, delay: Double = 0, influence: Double = 1
    ) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var entries: [(String, Data)] = []
        var objects: [String] = []
        for (index, layer) in layers.enumerated() {
            let key = "l\(index)"
            entries.append(("models/\(key).json", Data(#"{"material":"materials/\#(key).json"}"#.utf8)))
            entries.append(("materials/\(key).json", Data(#"{"passes":[{"blending":"\#(layer.blending)","shader":"genericimage4","textures":["\#(key)"]}]}"#.utf8)))
            entries.append(("materials/\(key).tex", layer.texture))
            let depth = layer.depth.map { #","parallaxDepth":"\#($0)""# } ?? ""
            objects.append(#"{"id":\#(index + 1),"name":"\#(layer.name)","image":"models/\#(key).json","origin":"\#(layer.origin)","size":"\#(layer.size)","scale":"\#(layer.scale)","alpha":\#(layer.alpha),"colorBlendMode":\#(layer.blendMode)\#(depth)}"#)
        }
        let json = #"{"general":{"clearcolor":"\#(clear)","cameraparallax":\#(parallax),"cameraparallaxamount":\#(amount),"cameraparallaxdelay":\#(delay),"cameraparallaxmouseinfluence":\#(influence),"orthogonalprojection":{"width":100,"height":60}},"objects":[\#(objects.joined(separator: ","))]}"#
        entries.insert(("scene.json", Data(json.utf8)), at: 0)
        try pkg(entries: entries).write(to: folder.appending(path: "scene.pkg"))
        try Data(#"{"type":"scene","file":"scene.json","title":"Тест"}"#.utf8).write(to: folder.appending(path: "project.json"))
        return folder
    }
}
