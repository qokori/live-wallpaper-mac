import Foundation

/// S3TC (DXT1, DXT3, DXT5) blocks to RGBA8888 on the CPU. WebGL on a Mac has no s3tc extension and the textures are
/// small enough for this to be cheap.
enum DXTDecoder {
    enum Variant {
        case dxt1
        case dxt3
        case dxt5

        var blockBytes: Int { self == .dxt1 ? 8 : 16 }
    }

    /// Returns `width * height * 4` bytes, or nil when `data` is shorter than the blocks need.
    static func decode(_ data: Data, width: Int, height: Int, variant: Variant) -> Data? {
        guard width > 0, height > 0 else { return nil }
        let blocksX = (width + 3) / 4
        let blocksY = (height + 3) / 4
        guard data.count >= blocksX * blocksY * variant.blockBytes else { return nil }
        var out = Data(count: width * height * 4)
        let base = data.startIndex
        out.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) in
        for by in 0..<blocksY {
            for bx in 0..<blocksX {
                let at = base + (by * blocksX + bx) * variant.blockBytes
                let color = at + (variant == .dxt1 ? 0 : 8)
                let palette = colors(data, color, opaqueOnly: variant != .dxt1)
                let indices = UInt32(data[color + 4]) | UInt32(data[color + 5]) << 8 | UInt32(data[color + 6]) << 16 | UInt32(data[color + 7]) << 24
                let alphas: [UInt8] = switch variant {
                case .dxt1: []
                case .dxt3: explicitAlpha(data, at)
                case .dxt5: interpolatedAlpha(data, at)
                }
                for py in 0..<4 {
                    for px in 0..<4 {
                        let x = bx * 4 + px
                        let y = by * 4 + py
                        guard x < width, y < height else { continue }
                        let n = py * 4 + px
                        let c = palette[Int(indices >> UInt32(2 * n)) & 3]
                        let o = (y * width + x) * 4
                        out[o] = c.0
                        out[o + 1] = c.1
                        out[o + 2] = c.2
                        out[o + 3] = variant == .dxt1 ? c.3 : alphas[n]
                    }
                }
            }
        }
        }
        return out
    }

    private static func rgb565(_ value: UInt16) -> (Int, Int, Int) {
        let r = Int(value >> 11 & 31)
        let g = Int(value >> 5 & 63)
        let b = Int(value & 31)
        return ((r << 3) | (r >> 2), (g << 2) | (g >> 4), (b << 3) | (b >> 2))
    }

    private static func colors(_ data: Data, _ at: Int, opaqueOnly: Bool) -> [(UInt8, UInt8, UInt8, UInt8)] {
        let c0 = UInt16(data[at]) | UInt16(data[at + 1]) << 8
        let c1 = UInt16(data[at + 2]) | UInt16(data[at + 3]) << 8
        let a = rgb565(c0)
        let b = rgb565(c1)
        func px(_ r: Int, _ g: Int, _ b: Int, _ alpha: UInt8 = 255) -> (UInt8, UInt8, UInt8, UInt8) {
            (UInt8(r), UInt8(g), UInt8(b), alpha)
        }
        if c0 > c1 || opaqueOnly {
            return [px(a.0, a.1, a.2), px(b.0, b.1, b.2),
                    px((2 * a.0 + b.0) / 3, (2 * a.1 + b.1) / 3, (2 * a.2 + b.2) / 3),
                    px((a.0 + 2 * b.0) / 3, (a.1 + 2 * b.1) / 3, (a.2 + 2 * b.2) / 3)]
        }
        return [px(a.0, a.1, a.2), px(b.0, b.1, b.2), px((a.0 + b.0) / 2, (a.1 + b.1) / 2, (a.2 + b.2) / 2), px(0, 0, 0, 0)]
    }

    private static func explicitAlpha(_ data: Data, _ at: Int) -> [UInt8] {
        (0..<16).map { n in
            let byte = data[at + n / 2]
            let nibble = n % 2 == 0 ? byte & 15 : byte >> 4
            return nibble * 17
        }
    }

    private static func interpolatedAlpha(_ data: Data, _ at: Int) -> [UInt8] {
        let a0 = Int(data[at])
        let a1 = Int(data[at + 1])
        var table = [a0, a1]
        if a0 > a1 {
            for i in 1...6 { table.append(((7 - i) * a0 + i * a1) / 7) }
        } else {
            for i in 1...4 { table.append(((5 - i) * a0 + i * a1) / 5) }
            table += [0, 255]
        }
        var bits: UInt64 = 0
        for i in 0..<6 { bits |= UInt64(data[at + 2 + i]) << UInt64(8 * i) }
        return (0..<16).map { UInt8(table[Int(bits >> UInt64(3 * $0)) & 7]) }
    }
}
