import Foundation

/// What the scene page asks for, by path: the page itself, the scene description and one file per texture. Built once
/// per scene; the app's scheme handler only forwards requests to `resource(path:range:)`.
public final class SceneAssets: @unchecked Sendable {
    public struct Resource: Sendable {
        public let status: Int
        public let headers: [String: String]
        public let body: Data
    }

    public struct Texture: Sendable {
        public let path: String
        public let kind: String
        public let width: Int
        public let height: Int
        let file: TexFile
    }

    public let document: SceneDocument
    /// What the page cannot show and why: layers dropped here and objects dropped by the document.
    public let skipped: [String]
    public let textures: [Texture]
    private let layers: [SceneDocument.Layer]
    private let lock = NSLock()

    public init(files: EngineFileSystem, project: EngineProject) throws {
        let sceneName = project.file ?? "scene.json"
        guard let data = files.data(sceneName) else { throw SceneDocument.Failure.unreadable }
        let document = try SceneDocument(data: data, files: files, properties: project.properties)
        var skipped = document.skipped
        var textures: [Texture] = []
        var index: [String: Int] = [:]
        var failed = Set<String>()
        for path in document.textures {
            do {
                guard let bytes = files.data(path) else { throw TexFile.Failure.damaged("нет файла") }
                let file = try TexFile(data: bytes)
                switch file.payload {
                case .pixels(let w, let h, _): textures.append(Texture(path: path, kind: "raw", width: w, height: h, file: file))
                case .image: textures.append(Texture(path: path, kind: "image", width: file.imageWidth, height: file.imageHeight, file: file))
                case .video: textures.append(Texture(path: path, kind: "video", width: file.imageWidth, height: file.imageHeight, file: file))
                }
                index[path.lowercased()] = textures.count - 1
            } catch {
                failed.insert(path.lowercased())
                skipped.append("\(path): \(error.localizedDescription)")
            }
        }
        let drawable = document.layers.filter { !failed.contains($0.texture.lowercased()) }
        guard !drawable.isEmpty else { throw SceneDocument.Failure.noLayers }
        self.document = document
        self.skipped = skipped
        self.textures = textures
        self.layers = drawable
        self.index = index
    }

    private let index: [String: Int]

    /// The scene as the page reads it.
    public func sceneJSON() -> Data {
        let list: [[String: Any]] = textures.enumerated().map { i, t in
            ["url": "t/\(i)", "kind": t.kind, "w": t.width, "h": t.height]
        }
        let drawn: [[String: Any]] = layers.map { l in
            [
                "name": l.name, "tex": index[l.texture.lowercased()] ?? 0, "m": l.transform, "size": l.size, "alpha": l.alpha,
                "color": l.color, "brightness": l.brightness, "blending": l.blending.rawValue, "mode": l.blendMode,
                "depth": l.parallaxDepth,
            ]
        }
        let root: [String: Any] = [
            "width": document.width, "height": document.height, "clear": document.clearColor,
            "parallax": [
                "enabled": document.parallax.enabled, "amount": document.parallax.amount,
                "delay": document.parallax.delay, "influence": document.parallax.mouseInfluence,
            ] as [String: Any],
            "textures": list, "layers": drawn,
        ]
        return (try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    /// `path` is the URL path: `/index.html`, `/scene.json`, `/t/<number>`. `range` is the `Range` header, for video.
    public func resource(path: String, range: String? = nil) -> Resource? {
        switch path {
        case "/", "/index.html":
            return Resource(status: 200, headers: ["Content-Type": "text/html; charset=utf-8"], body: Data(SceneRendererPage.html.utf8))
        case "/scene.json":
            return Resource(status: 200, headers: ["Content-Type": "application/json"], body: sceneJSON())
        default:
            guard path.hasPrefix("/t/"), let i = Int(path.dropFirst(3)), textures.indices.contains(i) else { return nil }
            lock.lock()
            defer { lock.unlock() }
            switch textures[i].file.payload {
            case .pixels(_, _, let rgba): return Resource(status: 200, headers: ["Content-Type": "application/octet-stream"], body: rgba)
            case .image(let bytes, let mime): return Resource(status: 200, headers: ["Content-Type": mime], body: bytes)
            case .video(let bytes): return Self.ranged(bytes, mime: "video/mp4", range: range)
            }
        }
    }

    /// Answers a `Range: bytes=a-b` request the way a web server does; without one, the whole file.
    static func ranged(_ bytes: Data, mime: String, range: String?) -> Resource {
        let total = bytes.count
        var headers = ["Content-Type": mime, "Accept-Ranges": "bytes"]
        guard let range, range.lowercased().hasPrefix("bytes="), total > 0 else {
            headers["Content-Length"] = String(total)
            return Resource(status: 200, headers: headers, body: bytes)
        }
        let spec = range.dropFirst(6).split(separator: ",").first.map(String.init) ?? ""
        let parts = spec.split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        var start = 0
        var end = total - 1
        if parts.count == 2 {
            if parts[0].isEmpty, let n = Int(parts[1]) {
                start = max(0, total - n)
            } else if let a = Int(parts[0]) {
                start = a
                if let b = Int(parts[1]) { end = min(b, total - 1) }
            }
        }
        guard start <= end, start < total else {
            return Resource(status: 416, headers: ["Content-Range": "bytes */\(total)"], body: Data())
        }
        headers["Content-Range"] = "bytes \(start)-\(end)/\(total)"
        headers["Content-Length"] = String(end - start + 1)
        return Resource(status: 206, headers: headers, body: bytes[(bytes.startIndex + start)...(bytes.startIndex + end)])
    }
}
