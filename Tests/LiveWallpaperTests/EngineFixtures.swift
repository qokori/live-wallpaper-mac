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
}
