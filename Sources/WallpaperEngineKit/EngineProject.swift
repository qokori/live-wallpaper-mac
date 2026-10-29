import Foundation

/// `project.json` of a Wallpaper Engine project: what it is, which file is the main one, the preview and the
/// user's settings with their default values.
public struct EngineProject: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case scene
        case video
        case web
        /// A Windows program; it cannot run on a Mac.
        case application
        case other(String)
    }

    public struct Property: Equatable, Sendable {
        public let key: String
        /// `color`, `slider`, `bool`, `combo`, `textinput`…
        public let type: String
        public let text: String?
        /// The default value as JSON text, ready to put into a script: `true`, `0.5`, `"0.2 0.4 1"`.
        public let valueJSON: String?
        public let order: Int
    }

    public enum Failure: Error, Equatable, LocalizedError {
        case noProject
        case unreadable
        case noType

        public var errorDescription: String? {
            switch self {
            case .noProject: "В папке нет project.json — это не проект Wallpaper Engine."
            case .unreadable: "Не удалось прочитать project.json."
            case .noType: "В project.json не указан тип обоев (type)."
            }
        }
    }

    public let kind: Kind
    /// The `type` as written.
    public let rawType: String
    /// The main file, relative to the project folder (`scene.json`, a video, `index.html`).
    public let file: String?
    public let title: String?
    public let preview: String?
    public let workshopID: String?
    public let version: Int?
    public let properties: [Property]

    public init(data: Data) throws {
        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        guard let root = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw Failure.unreadable }
        // Keys are not case-sensitive in Wallpaper Engine's own files.
        let fields = Dictionary(root.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        guard let type = (fields["type"] as? String)?.trimmingCharacters(in: .whitespaces), !type.isEmpty else { throw Failure.noType }
        rawType = type
        switch type.lowercased() {
        case "scene": kind = .scene
        case "video": kind = .video
        case "web": kind = .web
        case "application": kind = .application
        default: kind = .other(type)
        }
        file = Self.text(fields["file"])
        title = Self.text(fields["title"])
        preview = Self.text(fields["preview"])
        workshopID = Self.text(fields["workshopid"])
        version = (fields["version"] as? NSNumber)?.intValue
        let general = fields["general"] as? [String: Any]
        let raw = general?["properties"] as? [String: Any] ?? [:]
        properties = raw.compactMap { Self.property(key: $0.key, value: $0.value) }
            .sorted { ($0.order, $0.key) < ($1.order, $1.key) }
    }

    /// A string, or a number written as one (`workshopid` comes as either).
    private static func text(_ value: Any?) -> String? {
        if let string = value as? String { return string.isEmpty ? nil : string }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.stringValue }
        return nil
    }

    private static func property(key: String, value: Any) -> Property? {
        guard let fields = value as? [String: Any], let type = fields["type"] as? String else { return nil }
        var json: String?
        if let value = fields["value"], JSONSerialization.isValidJSONObject([value]),
           let data = try? JSONSerialization.data(withJSONObject: [value]), var text = String(data: data, encoding: .utf8) {
            text.removeFirst()
            text.removeLast()
            json = text
        }
        return Property(
            key: key, type: type, text: fields["text"] as? String, valueJSON: json,
            order: (fields["order"] as? NSNumber)?.intValue ?? Int.max
        )
    }

    public init(contentsOf url: URL) throws {
        guard let data = try? Data(contentsOf: url) else { throw Failure.noProject }
        try self.init(data: data)
    }
}
