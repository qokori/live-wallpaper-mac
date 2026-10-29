import Foundation

/// One saved wallpaper in the library: a source plus the name it is shown under.
public struct SavedWallpaper: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var source: WallpaperSource
    /// Own name; nil shows the source's file, folder or host name.
    public var name: String?
    public let added: Date

    public init(id: String, source: WallpaperSource, name: String? = nil, added: Date) {
        self.id = id
        self.source = source
        self.name = name
        self.added = added
    }

    public var title: String {
        guard let name, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return source.title }
        return name
    }
}

/// Wallpapers the person has added, in the order they were added. A source is in the library once: adding the same
/// video, folder or address again returns the item that is already there.
public struct WallpaperLibrary: Codable, Equatable, Sendable {
    public private(set) var items: [SavedWallpaper]
    /// Entries this version cannot read: a kind of source it does not know (written by a newer version) or a damaged
    /// item. They are not shown, and they are written back untouched, so one odd entry never costs the whole library.
    public private(set) var unreadable: [JSONValue]

    public init(items: [SavedWallpaper] = []) {
        self.items = items
        unreadable = []
    }

    private enum CodingKeys: String, CodingKey {
        case items
    }

    /// Reads the item list entry by entry; an entry that does not decode is kept as it is.
    private struct Entry: Decodable {
        let item: SavedWallpaper?
        let raw: JSONValue

        init(from decoder: Decoder) throws {
            raw = try JSONValue(from: decoder)
            item = try? SavedWallpaper(from: decoder)
        }
    }

    public init(from decoder: Decoder) throws {
        let entries = try decoder.container(keyedBy: CodingKeys.self).decode([Entry].self, forKey: .items)
        items = entries.compactMap(\.item)
        unreadable = entries.filter { $0.item == nil }.map(\.raw)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        var list = container.nestedUnkeyedContainer(forKey: .items)
        for item in items { try list.encode(item) }
        for raw in unreadable { try list.encode(raw) }
    }

    /// Same kind and same place; the bookmark and the name do not matter.
    private static func same(_ a: WallpaperSource, _ b: WallpaperSource) -> Bool {
        a.kind == b.kind && a.location == b.location
    }

    public func item(for source: WallpaperSource) -> SavedWallpaper? {
        items.first { Self.same($0.source, source) }
    }

    public func item(id: String) -> SavedWallpaper? {
        items.first { $0.id == id }
    }

    /// An existing item keeps its id and name and takes the fresh bookmark, so a file that was moved and added
    /// again is found at its new place.
    @discardableResult
    public mutating func add(
        _ source: WallpaperSource, now: Date = Date(), makeID: () -> String = { UUID().uuidString }
    ) -> SavedWallpaper {
        if let index = items.firstIndex(where: { Self.same($0.source, source) }) {
            if let bookmark = source.bookmark { items[index].source.bookmark = bookmark }
            return items[index]
        }
        let item = SavedWallpaper(id: makeID(), source: source, added: now)
        items.append(item)
        return item
    }

    @discardableResult
    public mutating func remove(id: String) -> SavedWallpaper? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        return items.remove(at: index)
    }

    public mutating func rename(id: String, to name: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        items[index].name = trimmed.isEmpty ? nil : trimmed
    }

    /// Puts every source that is already chosen into the library: the choices made before the library existed
    /// (an upgrade) and those made from the command line.
    public mutating func adopt(_ assignments: WallpaperAssignments, now: Date = Date()) {
        let chosen = [assignments.shared].compactMap { $0 } + assignments.perScreen.keys.sorted().compactMap { assignments.perScreen[$0] }
        for source in chosen { add(source, now: now) }
    }
}

/// The library in a JSON file. A missing file is an empty library. A file that is not a library at all is set aside as
/// `library.unreadable.json` before an empty one is used, so the next save cannot destroy it. Entries of an unknown kind
/// stay in the file (see `WallpaperLibrary.unreadable`). Saving never leaves a half-written file.
public struct LibraryStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() -> WallpaperLibrary {
        guard let data = try? Data(contentsOf: fileURL) else { return WallpaperLibrary() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        if let library = try? decoder.decode(WallpaperLibrary.self, from: data) { return library }
        let aside = fileURL.deletingLastPathComponent().appending(path: "library.unreadable.json")
        try? FileManager.default.removeItem(at: aside)
        try? FileManager.default.copyItem(at: fileURL, to: aside)
        return WallpaperLibrary()
    }

    public func save(_ library: WallpaperLibrary) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(library).write(to: fileURL, options: .atomic)
    }
}
