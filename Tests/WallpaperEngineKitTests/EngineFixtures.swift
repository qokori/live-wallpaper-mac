import Compression
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Wallpaper Engine files built in code. Nothing here is a copy of a real project: no binary fixtures in the repository.
enum EngineFixtures {
    static func int32(_ value: Int) -> [UInt8] {
        let v = UInt32(bitPattern: Int32(truncatingIfNeeded: value))
        return [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)]
    }

    static func string(_ text: String) -> [UInt8] {
        let bytes = Array(text.utf8)
        return int32(bytes.count) + bytes
    }

    /// A `.pkg`: version, count, then (path, offset, length) per file, then the data.
    static func pkg(entries: [(String, Data)], version: String = "PKGV0024") -> Data {
        var table: [UInt8] = string(version) + int32(entries.count)
        var body = Data()
        for (path, bytes) in entries {
            table += string(path) + int32(body.count) + int32(bytes.count)
            body.append(bytes)
        }
        return Data(table) + body
    }

    static func projectJSON(_ fields: String = "", type: String = "scene", file: String = "scene.json", bom: Bool = false) -> Data {
        let json = """
        {"type":"\(type)","file":"\(file)","title":"Тест","preview":"preview.jpg"\(fields.isEmpty ? "" : "," + fields)}
        """
        return (bom ? Data([0xEF, 0xBB, 0xBF]) : Data()) + Data(json.utf8)
    }

    static func tempFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "lw-we-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    struct Mip {
        var width: Int
        var height: Int
        var bytes: [UInt8]
        var lz4 = false
        /// The unpacked size written into the file when it is not the real one (a lie about a packed level).
        var claimed: Int? = nil
    }

    static func lz4(_ bytes: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: bytes.count + bytes.count / 255 + 64)
        let written = compression_encode_buffer(&out, out.count, bytes, bytes.count, nil, COMPRESSION_LZ4_RAW)
        return Array(out.prefix(written))
    }

    /// A `.tex`: TEXV/TEXI header, container TEXB000`container` with one picture of `mips`, and optional TEXS frames.
    static func tex(
        container: Int = 3, format: Int = 0, flags: Int = 2, size: (Int, Int)? = nil, image: (Int, Int)? = nil,
        fif: Int = -1, mp4Flag: Int = 0, mips: [Mip], frames: [(id: Int, time: Float, x: Float, y: Float, w: Float, h: Float)] = [], framesVersion: Int = 2
    ) -> Data {
        let (w, h) = (mips[0].width, mips[0].height)
        let (tw, th) = size ?? (w, h)
        let (iw, ih) = image ?? (w, h)
        var out = Array("TEXV0005".utf8) + [0] + Array("TEXI0001".utf8) + [0]
        out += int32(format) + int32(flags) + int32(tw) + int32(th) + int32(iw) + int32(ih) + int32(0)
        out += Array("TEXB000\(container)".utf8) + [0] + int32(1)
        if container >= 3 { out += int32(fif) }
        if container >= 4 { out += int32(mp4Flag) }
        out += int32(mips.count)
        for mip in mips {
            if container >= 4, mp4Flag == 1 { out += int32(1) + int32(2) + Array("{}".utf8) + [0] + int32(1) }
            out += int32(mip.width) + int32(mip.height)
            let stored = mip.lz4 ? lz4(mip.bytes) : mip.bytes
            if container >= 2 { out += int32(mip.lz4 ? 1 : 0) + int32(mip.claimed ?? mip.bytes.count) }
            out += int32(stored.count) + stored
        }
        if !frames.isEmpty {
            out += Array("TEXS000\(framesVersion)".utf8) + [0] + int32(frames.count)
            if framesVersion >= 3 { out += int32(w) + int32(h) }
            func number(_ v: Float) -> [UInt8] { framesVersion == 1 ? int32(Int(v)) : int32(Int(Int32(bitPattern: v.bitPattern))) }
            for f in frames {
                out += int32(f.id) + int32(Int(Int32(bitPattern: f.time.bitPattern)))
                out += number(f.x) + number(f.y) + number(f.w) + number(0) + number(0) + number(f.h)
            }
        }
        return Data(out)
    }

    static func png(width: Int, height: Int, rgba: [UInt8], type: UTType = .png) -> Data {
        let provider = CGDataProvider(data: Data(rgba) as CFData)!
        let image = CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}
