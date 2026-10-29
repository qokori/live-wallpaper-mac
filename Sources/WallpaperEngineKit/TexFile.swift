import Compression
import Foundation

/// A Wallpaper Engine texture (`.tex`): a header, then pictures with mip levels. Only the first level of the first
/// picture is read; it comes back as plain RGBA bytes, a whole image file (PNG, JPEG, GIF, BMP) or a whole MP4.
public struct TexFile: Sendable {
    /// A limit on the bytes a scene's textures may hold once unpacked. One budget is shared by all textures of a scene,
    /// so many small files cannot add up to more than the machine has.
    public final class Budget: @unchecked Sendable {
        public static let sceneLimit = 1 << 30
        private let limit: Int
        private var used = 0
        private let lock = NSLock()

        public init(limit: Int = Budget.sceneLimit) { self.limit = limit }

        public var bytesUsed: Int { lock.lock(); defer { lock.unlock() }; return used }

        func reserve(_ bytes: Int) throws {
            lock.lock(); defer { lock.unlock() }
            guard bytes >= 0, used + bytes <= limit else { throw Failure.damaged("сцена превысила предел памяти (\(limit >> 20) МиБ)") }
            used += bytes
        }

        func release(_ bytes: Int) {
            lock.lock(); defer { lock.unlock() }
            used = max(0, used - bytes)
        }
    }

    public enum Payload: Sendable {
        /// Straight (not premultiplied) RGBA8888, `width * height * 4` bytes.
        case pixels(width: Int, height: Int, rgba: Data)
        /// A whole image file; the system decodes it.
        case image(Data, mime: String)
        /// A whole MP4 file (a video layer). May be a window onto a mapped file.
        case video(Data)
    }

    public struct Frame: Equatable, Sendable {
        public let imageID: Int
        public let time: Float
        public let x: Float
        public let y: Float
        public let width: Float
        public let height: Float
    }

    public enum Failure: Error, Equatable, LocalizedError {
        case notATexture
        case damaged(String)
        case unsupported(String)

        public var errorDescription: String? {
            switch self {
            case .notATexture: "Файл не похож на текстуру Wallpaper Engine."
            case .damaged(let why): "Текстура повреждена: \(why)."
            case .unsupported(let what): "Формат текстуры не поддерживается: \(what)."
            }
        }
    }

    /// 0 RGBA8888, 4 DXT5, 6 DXT3, 7 DXT1, 8 RG88, 9 R8.
    public let format: Int
    /// 1 no smoothing, 2 clamp UV, 4 frame animation, 32 video.
    public let flags: Int
    /// The size of the picture inside the texture (a texture may be padded to a power of two).
    public let imageWidth: Int
    public let imageHeight: Int
    public let containerVersion: Int
    public let payload: Payload
    /// Animation frames (`flags & 4`), empty when there are none or they cannot be read.
    public let frames: [Frame]

    public var isVideo: Bool {
        if case .video = payload { return true }
        return false
    }

    static let maxSide = 16384
    /// Largest picture decoded to pixels (8192 × 8192).
    static let maxPixels = 1 << 26
    static let maxMips = 32

    public init(data: Data, budget: Budget? = nil) throws {
        let budget = budget ?? Budget()
        var held = 0
        do {
            try self.init(parsing: data, budget: budget, held: &held)
        } catch {
            budget.release(held)
            throw error
        }
    }

    private init(parsing data: Data, budget: Budget, held: inout Int) throws {
        var r = Reader(data: data)
        guard try r.magic("TEXV", digits: 4) != nil else { throw Failure.notATexture }
        guard try r.magic("TEXI", digits: 4) != nil else { throw Failure.notATexture }
        format = try r.int32()
        flags = try r.int32()
        _ = try r.int32()
        _ = try r.int32()
        let imageWidth = try r.int32()
        let imageHeight = try r.int32()
        _ = try r.int32()
        guard let container = try r.magic("TEXB", digits: 4), (1...4).contains(container) else { throw Failure.notATexture }
        containerVersion = container
        let imageCount = try r.int32()
        guard (1...4096).contains(imageCount) else { throw Failure.damaged("число картинок \(imageCount)") }
        var fif = -1
        var mp4Flag = 0
        if container >= 3 { fif = try r.int32() }
        if container >= 4 { mp4Flag = try r.int32() }

        var first: (width: Int, height: Int, bytes: Data)?
        for image in 0..<imageCount {
            let mips = try r.int32()
            guard (1...Self.maxMips).contains(mips) else { throw Failure.damaged("число мипов \(mips)") }
            for mip in 0..<mips {
                // Only the first level of the first picture is used; the others are stepped over, not unpacked.
                let wanted = image == 0 && mip == 0
                let level = try r.mip(container: container, video: container >= 4 && mp4Flag == 1, unpack: wanted, budget: budget, held: &held)
                if wanted { first = level }
            }
        }
        guard let first else { throw Failure.damaged("нет картинки") }
        self.imageWidth = imageWidth > 0 ? imageWidth : first.width
        self.imageHeight = imageHeight > 0 ? imageHeight : first.height

        frames = flags & 4 != 0 ? (try? r.frames()) ?? [] : []
        payload = try Self.payload(first, format: format, flags: flags, fif: fif, imageWidth: self.imageWidth, imageHeight: self.imageHeight, budget: budget, held: &held)
    }

    private static func payload(
        _ level: (width: Int, height: Int, bytes: Data), format: Int, flags: Int, fif: Int, imageWidth: Int, imageHeight: Int,
        budget: Budget, held: inout Int
    ) throws -> Payload {
        let bytes = level.bytes
        // The video is told apart by the flag and the `ftyp` box: the container's own fields say nothing in real files.
        if bytes.count > 12, bytes.dropFirst(4).starts(with: Array("ftyp".utf8)) { return .video(bytes) }
        if flags & 32 != 0 { throw Failure.unsupported("видео не в MP4") }
        if let mime = imageMime(bytes) { return .image(bytes, mime: mime) }
        if fif != -1 { throw Failure.unsupported("картинка внутри (FIF \(fif))") }
        let w = level.width
        let h = level.height
        guard (1...maxSide).contains(w), (1...maxSide).contains(h), w * h <= maxPixels else {
            throw Failure.damaged("размер \(w)×\(h)")
        }
        // A padded texture keeps its picture in the top-left corner.
        let crop = imageWidth > 0 && imageHeight > 0 && imageWidth <= w && imageHeight <= h && (imageWidth, imageHeight) != (w, h)
        let outW = crop ? imageWidth : w
        let outH = crop ? imageHeight : h

        // The unpacked level (if any) is `bytes`; it is dropped once the pixels are made, unless it already is them.
        let unpacked = held
        func finish(_ rgba: Data, reusedInput: Bool) -> Payload {
            if !reusedInput { budget.release(unpacked); held -= unpacked }
            return .pixels(width: outW, height: outH, rgba: rgba)
        }
        let rowBytes = outW * 4
        switch format {
        case 0:
            guard bytes.count >= w * h * 4 else { throw Failure.damaged("мало данных RGBA") }
            if !crop, bytes.count == w * h * 4 { return finish(bytes, reusedInput: true) }
            try budget.reserve(outW * outH * 4); held += outW * outH * 4
            let b = bytes.startIndex
            var out = Data(capacity: outW * outH * 4)
            for y in 0..<outH { out.append(bytes[(b + y * w * 4)..<(b + y * w * 4 + rowBytes)]) }
            return finish(out, reusedInput: false)
        case 9, 8:
            let step = format == 9 ? 1 : 2
            guard bytes.count >= w * h * step else { throw Failure.damaged(format == 9 ? "мало данных R8" : "мало данных RG88") }
            try budget.reserve(outW * outH * 4); held += outW * outH * 4
            var out = Data(count: outW * outH * 4)
            out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
                bytes.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
                    for y in 0..<outH {
                        for x in 0..<outW {
                            let from = (y * w + x) * step
                            let to = (y * outW + x) * 4
                            if format == 9 {
                                let v = src[from]
                                dst[to] = v; dst[to + 1] = v; dst[to + 2] = v
                            } else {
                                dst[to] = src[from]; dst[to + 1] = src[from + 1]; dst[to + 2] = 0
                            }
                            dst[to + 3] = 255
                        }
                    }
                }
            }
            return finish(out, reusedInput: false)
        case 7, 6, 4:
            let variant: DXTDecoder.Variant = format == 7 ? .dxt1 : format == 6 ? .dxt3 : .dxt5
            try budget.reserve(w * h * 4); held += w * h * 4
            guard let decoded = DXTDecoder.decode(bytes, width: w, height: h, variant: variant) else { throw Failure.damaged("мало данных DXT") }
            guard crop else { return finish(decoded, reusedInput: false) }
            try budget.reserve(outW * outH * 4); held += outW * outH * 4
            var out = Data(capacity: outW * outH * 4)
            for y in 0..<outH { out.append(decoded[(y * w * 4)..<(y * w * 4 + rowBytes)]) }
            budget.release(w * h * 4); held -= w * h * 4
            return finish(out, reusedInput: false)
        default:
            throw Failure.unsupported("format \(format)")
        }
    }

    static func imageMime(_ bytes: Data) -> String? {
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if bytes.starts(with: Array("GIF8".utf8)) { return "image/gif" }
        if bytes.starts(with: Array("BM".utf8)) && bytes.count > 14 { return "image/bmp" }
        return nil
    }

    private struct Reader {
        let data: Data
        var position: Int

        init(data: Data) {
            self.data = data
            position = data.startIndex
        }

        var remaining: Int { data.endIndex - position }

        mutating func int32() throws -> Int {
            guard remaining >= 4 else { throw Failure.damaged("файл оборван") }
            let v = UInt32(data[position]) | UInt32(data[position + 1]) << 8 | UInt32(data[position + 2]) << 16 | UInt32(data[position + 3]) << 24
            position += 4
            return Int(Int32(bitPattern: v))
        }

        mutating func float() throws -> Float {
            Float(bitPattern: UInt32(truncatingIfNeeded: try int32()))
        }

        /// A tag like `TEXB0003` and a zero byte; returns the number. nil when the tag is another one.
        mutating func magic(_ prefix: String, digits: Int) throws -> Int? {
            let length = prefix.utf8.count + digits + 1
            guard remaining >= length else { throw Failure.damaged("файл оборван") }
            let head = data[position..<position + length - 1]
            guard head.starts(with: Array(prefix.utf8)), data[position + length - 1] == 0,
                  let number = Int(String(decoding: head.dropFirst(prefix.utf8.count), as: UTF8.self))
            else { return nil }
            position += length
            return number
        }

        mutating func take(_ count: Int) throws -> Data {
            guard count >= 0, remaining >= count else { throw Failure.damaged("файл оборван") }
            defer { position += count }
            return data[position..<position + count]
        }

        /// One mip level: its size and bytes, unpacked when they are LZ4-packed and `unpack` is set. A level that is
        /// not wanted comes back with no bytes.
        mutating func mip(container: Int, video: Bool, unpack: Bool, budget: Budget, held: inout Int) throws -> (width: Int, height: Int, bytes: Data) {
            if video {
                // Version 4 with an MP4: two markers and a JSON text before the usual fields.
                _ = try int32()
                _ = try int32()
                while try take(1).first != 0 {}
                _ = try int32()
            }
            let width = try int32()
            let height = try int32()
            var packed = false
            var unpackedSize = 0
            if container >= 2 {
                packed = try int32() == 1
                unpackedSize = try int32()
            }
            let size = try int32()
            let bytes = try take(size)
            guard unpack else { return (width, height, Data()) }
            guard packed else { return (width, height, bytes) }
            // LZ4 cannot make more than 255 bytes of one; a bigger claim is a lie meant to fill memory.
            guard (0...(1 << 30)).contains(unpackedSize), unpackedSize <= size * 255 + 255 else {
                throw Failure.damaged("размер после распаковки \(unpackedSize)")
            }
            try budget.reserve(unpackedSize); held += unpackedSize
            var out = Data(count: unpackedSize)
            let written = unpackedSize == 0 ? 0 : bytes.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
                out.withUnsafeMutableBytes { (target: UnsafeMutableRawBufferPointer) in
                    compression_decode_buffer(
                        target.bindMemory(to: UInt8.self).baseAddress!, unpackedSize,
                        source.bindMemory(to: UInt8.self).baseAddress!, size, nil, COMPRESSION_LZ4_RAW
                    )
                }
            }
            guard written == unpackedSize else { throw Failure.damaged("LZ4 не распаковался (\(written) из \(unpackedSize))") }
            return (width, height, out)
        }

        mutating func frames() throws -> [Frame] {
            guard let version = try magic("TEXS", digits: 4) else { return [] }
            let count = try int32()
            guard (0...65536).contains(count) else { return [] }
            if version >= 3 { _ = try int32(); _ = try int32() }
            var frames: [Frame] = []
            for _ in 0..<count {
                let id = try int32()
                let time = try float()
                func number() throws -> Float { version == 1 ? Float(try int32()) : try float() }
                let x = try number()
                let y = try number()
                let width = try number()
                _ = try number()
                _ = try number()
                let height = try number()
                frames.append(Frame(imageID: id, time: time, x: x, y: y, width: width, height: height))
            }
            return frames
        }
    }
}
