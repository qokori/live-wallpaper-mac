import Foundation

/// `scene.json` of a Wallpaper Engine scene, reduced to what the first version draws: flat picture layers with their
/// place on the canvas, colour, blending and texture. Everything else is listed in `skipped` with the reason.
public struct SceneDocument: Sendable {
    public enum Blending: Int, Sendable {
        case normal = 0
        case translucent = 1
        case additive = 2
    }

    public struct Layer: Sendable, Equatable {
        public let id: Int
        public let name: String
        /// Texture path inside the project (`materials/x.tex`).
        public let texture: String
        /// Layer pixel to canvas pixel (y up): a, b, c, d, tx, ty, with the parent chain already applied.
        public let transform: [Double]
        public let size: [Double]
        public let alpha: Double
        public let color: [Double]
        public let brightness: Double
        public let blending: Blending
        /// `colorBlendMode` as written; 0 when absent.
        public let blendMode: Int
        public let parallaxDepth: [Double]
        /// Effects the layer carries; they are not drawn yet.
        public let effects: Int
    }

    public struct Parallax: Sendable, Equatable {
        public let enabled: Bool
        public let amount: Double
        public let delay: Double
        public let mouseInfluence: Double
    }

    public enum Failure: Error, Equatable, LocalizedError {
        case unreadable
        case noLayers

        public var errorDescription: String? {
            switch self {
            case .unreadable: "scene.json не читается."
            case .noLayers: "В сцене нет картинок, которые можно нарисовать."
            }
        }
    }

    public let width: Int
    public let height: Int
    public let clearColor: [Double]
    public let parallax: Parallax
    public let layers: [Layer]
    public let skipped: [String]

    /// Texture paths in first-use order; the index is the texture's number for the renderer.
    public var textures: [String] {
        var seen = Set<String>()
        return layers.map(\.texture).filter { seen.insert($0.lowercased()).inserted }
    }

    public init(data: Data, files: EngineFileSystem, properties: [EngineProject.Property] = []) throws {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw Failure.unreadable }
        let values = Dictionary(properties.compactMap { p in p.valueJSON.flatMap(Self.fragment).map { (p.key, $0) } }, uniquingKeysWith: { a, _ in a })
        let general = root["general"] as? [String: Any] ?? [:]
        let projection = general["orthogonalprojection"] as? [String: Any]
        width = Self.int(projection?["width"]).flatMap { (1...65536).contains($0) ? $0 : nil } ?? 1920
        height = Self.int(projection?["height"]).flatMap { (1...65536).contains($0) ? $0 : nil } ?? 1080
        clearColor = Self.vector(Self.resolve(general["clearcolor"], values), count: 3) ?? [0, 0, 0]
        parallax = Parallax(
            enabled: Self.bool(Self.resolve(general["cameraparallax"], values)) ?? false,
            amount: Self.number(Self.resolve(general["cameraparallaxamount"], values)) ?? 0.5,
            delay: Self.number(Self.resolve(general["cameraparallaxdelay"], values)) ?? 0.1,
            mouseInfluence: Self.number(Self.resolve(general["cameraparallaxmouseinfluence"], values)) ?? 0.5
        )

        let objects = root["objects"] as? [[String: Any]] ?? []
        var byID: [Int: [String: Any]] = [:]
        for object in objects { if let id = Self.int(object["id"]) { byID[id] = object } }
        var skipped: [String] = []
        var notes: [String] = []
        var layers: [Layer] = []
        var worlds: [Int: [Double]] = [:]
        var hidden = Set<Int>()

        func world(of id: Int, depth: Int = 0) -> [Double] {
            if let cached = worlds[id] { return cached }
            guard let object = byID[id] else { return Self.identity }
            let local = Self.local(object, values)
            var result = local
            if let parent = Self.int(object["parent"]), parent != id, depth < 32, byID[parent] != nil {
                let chained = Self.multiply(world(of: parent, depth: depth + 1), local)
                if chained.allSatisfy({ $0.isFinite && abs($0) <= Self.limit * 1e3 }) {
                    result = chained
                } else {
                    notes.append("\(object["name"] as? String ?? "объект \(id)"): преобразование родителей вне допустимых пределов, родитель не учтён")
                }
            }
            worlds[id] = result
            return result
        }
        func isHidden(_ id: Int, depth: Int = 0) -> Bool {
            if hidden.contains(id) { return true }
            guard let object = byID[id] else { return false }
            if Self.bool(Self.resolve(object["visible"], values)) == false { return true }
            if let parent = Self.int(object["parent"]), parent != id, depth < 32 { return isHidden(parent, depth: depth + 1) }
            return false
        }

        for (index, object) in objects.enumerated() {
            let id = Self.int(object["id"]) ?? -(index + 1)
            let name = (object["name"] as? String) ?? "объект \(id)"
            // A value that is there but unusable (not a number, not finite, out of range) is left out; say so once.
            for field in ["id", "parent", "alpha", "brightness", "color", "size", "origin", "scale", "angles", "colorBlendMode", "parallaxDepth"] {
                guard Self.unusable(Self.resolve(object[field], values)) else { continue }
                notes.append("\(name): поле \(field) отброшено (не число или вне допустимых пределов)")
            }
            if let kind = ["particle", "sound", "text", "light", "shape"].first(where: { object[$0] != nil }) {
                skipped.append("\(name): \(Self.reasons[kind] ?? kind)")
                continue
            }
            guard let model = object["image"] as? String else { continue } // a group: only its transform matters
            if model.lowercased().hasPrefix("models/util/") {
                skipped.append("\(name): служебная модель \(model)")
                continue
            }
            if isHidden(id) { continue }
            guard let resolved = Self.chain(model, files) else {
                skipped.append("\(name): нет модели, материала или текстуры для \(model)")
                continue
            }
            var size = Self.vector(Self.resolve(object["size"], values), count: 2)
            size = size ?? resolved.size
            guard let size else {
                skipped.append("\(name): неизвестен размер")
                continue
            }
            let effects = (object["effects"] as? [[String: Any]])?.filter { Self.bool(Self.resolve($0["visible"], values)) != false }.count ?? 0
            if effects > 0 { skipped.append("\(name): эффектов \(effects), не рисуются") }
            if object["animationlayers"] != nil { skipped.append("\(name): анимация слоя не рисуется") }
            let blending = Blending(name: resolved.blending)
            layers.append(Layer(
                id: id, name: name, texture: resolved.texture,
                transform: world(of: id), size: size,
                alpha: Self.number(Self.resolve(object["alpha"], values)) ?? 1,
                color: Self.vector(Self.resolve(object["color"], values), count: 3) ?? [1, 1, 1],
                brightness: Self.number(Self.resolve(object["brightness"], values)) ?? 1,
                blending: blending,
                blendMode: Self.int(Self.resolve(object["colorBlendMode"], values)) ?? 0,
                parallaxDepth: Self.vector(Self.resolve(object["parallaxDepth"], values), count: 2) ?? [1, 1],
                effects: effects
            ))
        }
        guard !layers.isEmpty else { throw Failure.noLayers }
        self.layers = layers
        self.skipped = skipped + notes
    }

    private static let reasons = [
        "particle": "частицы не рисуются", "sound": "звук не воспроизводится", "text": "текст не рисуется",
        "light": "свет не рисуется", "shape": "фигура не рисуется",
    ]

    // MARK: Model, material, texture

    private static func chain(_ modelPath: String, _ files: EngineFileSystem) -> (texture: String, blending: String, size: [Double]?)? {
        guard let model = json(files.data(modelPath)), let materialPath = model["material"] as? String,
              let material = json(files.data(materialPath)),
              let pass = (material["passes"] as? [[String: Any]])?.first,
              let name = (pass["textures"] as? [Any])?.compactMap({ $0 as? String }).first
        else { return nil }
        let texture = "materials/\(name).tex"
        guard files.contains(texture) else { return nil }
        var size: [Double]?
        if let w = number(model["width"]), let h = number(model["height"]) { size = [w, h] }
        return (texture, (pass["blending"] as? String ?? "translucent").lowercased(), size)
    }

    private static func json(_ data: Data?) -> [String: Any]? {
        guard var data else { return nil }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { data = data.dropFirst(3) }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: Values

    /// A field is a literal, a text like `"1 0.5 0"`, or an object `{value, user, …}` whose `user` names a setting.
    static func resolve(_ raw: Any?, _ settings: [String: Any]) -> Any? {
        guard let object = raw as? [String: Any] else { return raw }
        var key: String?
        if let name = object["user"] as? String { key = name }
        if let nested = object["user"] as? [String: Any], let name = nested["name"] as? String { key = name }
        if let key, let value = settings[key] { return value }
        return object["value"]
    }

    private static func fragment(_ text: String) -> Any? {
        try? JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed)
    }

    /// Largest magnitude a field may have; a bigger or non-finite value (`nan`, `inf`, `1e999`) is dropped.
    static let limit = 1e9

    static func number(_ raw: Any?) -> Double? {
        let value: Double
        if let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
            value = n.doubleValue
        } else if let s = raw as? String, let parsed = Double(s.trimmingCharacters(in: .whitespaces)) {
            value = parsed
        } else {
            return nil
        }
        return value.isFinite && abs(value) <= limit ? value : nil
    }

    /// A value that is present but cannot be used as a number or a list of numbers.
    static func unusable(_ raw: Any?) -> Bool {
        switch raw {
        case let text as String: text.split(whereSeparator: \.isWhitespace).contains { number(String($0)) == nil }
        case let list as [Any]: list.contains { unusable($0) }
        case let n as NSNumber: CFGetTypeID(n) != CFBooleanGetTypeID() && number(n) == nil
        default: false
        }
    }

    /// A whole number inside the range of `Int`; a fraction is cut off.
    static func int(_ raw: Any?) -> Int? { number(raw).map { Int($0) } }

    static func bool(_ raw: Any?) -> Bool? {
        if let n = raw as? NSNumber { return n.boolValue }
        if let s = (raw as? String)?.lowercased() { return s == "true" ? true : s == "false" ? false : nil }
        return nil
    }

    static func vector(_ raw: Any?, count: Int) -> [Double]? {
        // One bad part spoils the whole value: a colour of `1 nan 0` is not `1 0 0`.
        if unusable(raw) { return nil }
        var parts: [Double]
        if let s = raw as? String {
            parts = s.split(whereSeparator: \.isWhitespace).compactMap { number(String($0)) }
        } else if let list = raw as? [Any] {
            parts = list.compactMap { number($0) }
        } else if let n = number(raw) {
            parts = [n]
        } else {
            return nil
        }
        guard !parts.isEmpty else { return nil }
        while parts.count < count { parts.append(parts.count == 1 && count >= 2 ? parts[0] : 0) }
        return Array(parts.prefix(max(count, 0)))
    }

    // MARK: Transforms (2D affine as a, b, c, d, tx, ty; column vectors, y up)

    static let identity: [Double] = [1, 0, 0, 1, 0, 0]

    static func local(_ object: [String: Any], _ settings: [String: Any]) -> [Double] {
        let origin = vector(resolve(object["origin"], settings), count: 3) ?? [0, 0, 0]
        let scale = vector(resolve(object["scale"], settings), count: 3) ?? [1, 1, 1]
        let angles = vector(resolve(object["angles"], settings), count: 3) ?? [0, 0, 0]
        let c = cos(angles[2])
        let s = sin(angles[2])
        // T * R * S
        return [c * scale[0], s * scale[0], -s * scale[1], c * scale[1], origin[0], origin[1]]
    }

    /// `lhs` applied after `rhs`.
    static func multiply(_ l: [Double], _ r: [Double]) -> [Double] {
        [
            l[0] * r[0] + l[2] * r[1], l[1] * r[0] + l[3] * r[1],
            l[0] * r[2] + l[2] * r[3], l[1] * r[2] + l[3] * r[3],
            l[0] * r[4] + l[2] * r[5] + l[4], l[1] * r[4] + l[3] * r[5] + l[5],
        ]
    }
}

extension SceneDocument.Blending {
    init(name: String) {
        switch name {
        case "additive": self = .additive
        case "normal": self = .normal
        default: self = .translucent
        }
    }
}
