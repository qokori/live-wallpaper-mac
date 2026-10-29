/// A hash of text that is the same on every launch (`Hasher` is not), for names of files made from a path.
public enum StableHash {
    /// FNV-1a, 64 bit, as 16 hex digits.
    public static func hex(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }
}
