import Foundation

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
}
