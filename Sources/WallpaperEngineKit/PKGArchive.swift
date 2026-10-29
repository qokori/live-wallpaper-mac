import Foundation

/// The file container of a Wallpaper Engine scene (`scene.pkg`): a version string, a table of paths with offsets and
/// lengths, then the file bytes. Only the table is read; files are cut out of the (memory-mapped) data on request.
///
/// Layout, little-endian: a length-prefixed string `PKGVxxxx`; int32 file count; for each file a length-prefixed UTF-8
/// path, int32 offset (from the end of the table) and int32 length; then the data.
public struct PKGArchive: Sendable {
    public struct Entry: Equatable, Sendable {
        public let path: String
        /// From the start of the archive data.
        public let offset: Int
        public let length: Int
    }

    public enum Failure: Error, Equatable, LocalizedError {
        /// A macOS installer package (xar), not a Wallpaper Engine one.
        case installerPackage
        case notAPackage
        case damaged(String)

        public var errorDescription: String? {
            switch self {
            case .installerPackage: "Это установщик macOS (.pkg), а не пакет Wallpaper Engine."
            case .notAPackage: "Файл не похож на пакет Wallpaper Engine (нет сигнатуры PKGV)."
            case .damaged(let why): "Пакет Wallpaper Engine повреждён: \(why)."
            }
        }
    }

    /// Limits that keep a hostile or broken file from asking for a huge table.
    static let maxFiles = 100_000
    static let maxPathBytes = 1024

    /// `PKGV0024` and the like. Only the prefix is checked; the number is for the log.
    public let version: String
    public let entries: [Entry]
    private let data: Data
    private let index: [String: Int]

    public init(contentsOf url: URL) throws {
        try self.init(data: try Data(contentsOf: url, options: .alwaysMapped))
    }

    public init(data: Data) throws {
        if data.starts(with: Array("xar!".utf8)) { throw Failure.installerPackage }
        var reader = Reader(data: data)
        let version = try reader.string(limit: 32, what: "версия")
        guard version.hasPrefix("PKGV") else { throw Failure.notAPackage }
        let count = try reader.int32("число файлов")
        guard count >= 0, count <= Self.maxFiles else { throw Failure.damaged("число файлов \(count)") }
        var raw: [(String, Int, Int)] = []
        raw.reserveCapacity(count)
        for _ in 0..<count {
            let path = try Self.clean(try reader.string(limit: Self.maxPathBytes, what: "путь"))
            let offset = try reader.int32("смещение")
            let length = try reader.int32("длина")
            raw.append((path, offset, length))
        }
        let base = reader.position
        var entries: [Entry] = []
        var index: [String: Int] = [:]
        for (path, offset, length) in raw {
            guard offset >= 0, length >= 0, offset <= data.count - base, length <= data.count - base - offset else {
                throw Failure.damaged("файл «\(path)» выходит за конец пакета")
            }
            index[path.lowercased()] = entries.count
            entries.append(Entry(path: path, offset: base + offset, length: length))
        }
        self.version = version
        self.entries = entries
        self.data = data
        self.index = index
    }

    /// Paths are written on Windows: any case, maybe backslashes. Absolute paths and `..` are refused.
    static func clean(_ path: String) throws -> String {
        let slashed = path.replacingOccurrences(of: "\\", with: "/")
        let parts = slashed.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !slashed.isEmpty, !slashed.hasPrefix("/"), !parts.contains(".."), !parts.contains(""),
              !(parts[0].count == 2 && parts[0].hasSuffix(":"))
        else { throw Failure.damaged("недопустимый путь «\(path)»") }
        return slashed
    }

    public func entry(_ path: String) -> Entry? {
        let key = path.replacingOccurrences(of: "\\", with: "/").lowercased()
        return index[key].map { entries[$0] }
    }

    public func contains(_ path: String) -> Bool { entry(path) != nil }

    /// The bytes of one file (a slice of the mapped data, copied only if the caller mutates it).
    public func contents(of path: String) -> Data? {
        guard let entry = entry(path) else { return nil }
        return data.subdata(in: entry.offset..<(entry.offset + entry.length))
    }

    private struct Reader {
        let data: Data
        private(set) var position = 0

        init(data: Data) {
            self.data = data
        }

        mutating func int32(_ what: String) throws -> Int {
            guard data.count - position >= 4 else { throw Failure.damaged("файл оборван (\(what))") }
            let start = data.startIndex + position
            let value = UInt32(data[start]) | UInt32(data[start + 1]) << 8 | UInt32(data[start + 2]) << 16 | UInt32(data[start + 3]) << 24
            position += 4
            return Int(Int32(bitPattern: value))
        }

        mutating func string(limit: Int, what: String) throws -> String {
            let length = try int32(what)
            guard length > 0, length <= limit else { throw Failure.damaged("длина строки \(length) (\(what))") }
            guard data.count - position >= length else { throw Failure.damaged("файл оборван (\(what))") }
            let start = data.startIndex + position
            position += length
            guard let text = String(data: data[start..<start + length], encoding: .utf8) else {
                throw Failure.damaged("не UTF-8 (\(what))")
            }
            return text
        }
    }
}
