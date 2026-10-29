import Foundation

/// A text report on a project for `--we-inspect`: its type and main fields, the package version and files, and what
/// the scene holds. Reads only; nothing is unpacked.
public enum EngineInspector {
    public static func report(for url: URL) throws -> String {
        let location = try EngineLocation.resolve(url)
        let project = try EngineProject(contentsOf: location.projectFile)
        var lines: [String] = []
        lines.append("Проект: \(location.folder.path)")
        lines.append("type: \(project.rawType)" + (project.kind == .application ? " (программа для Windows, на Mac не запустится)" : ""))
        lines.append("title: \(project.title ?? "—")")
        lines.append("file: \(project.file ?? "—")")
        lines.append("preview: \(project.preview ?? "—")")
        if let id = project.workshopID { lines.append("workshopid: \(id)") }
        if let version = project.version { lines.append("version: \(version)") }
        lines.append("настройки: \(project.properties.count)")
        for property in project.properties {
            lines.append("  \(property.key) [\(property.type)] = \(property.valueJSON ?? "—")")
        }
        guard let package = location.package else {
            lines.append("пакет: нет")
            return lines.joined(separator: "\n")
        }
        do {
            let archive = try PKGArchive(contentsOf: package)
            let bytes = archive.entries.reduce(0) { $0 + $1.length }
            lines.append("пакет: \(package.lastPathComponent), \(archive.version), файлов \(archive.entries.count), данных \(bytes) байт")
            if let scene = archive.contents(of: "scene.json") { lines.append(contentsOf: sceneLines(scene)) }
            lines.append(contentsOf: drawingLines(location: location, project: project))
            lines.append("файлы:")
            for entry in archive.entries { lines.append("  \(entry.path) (\(entry.length))") }
        } catch {
            lines.append("пакет: \(package.lastPathComponent): \(error.localizedDescription)")
        }
        return lines.joined(separator: "\n")
    }

    /// What the app would draw: layers and textures, and what it leaves out and why.
    static func drawingLines(location: EngineLocation, project: EngineProject) -> [String] {
        guard project.kind == .scene else { return [] }
        do {
            let assets = try SceneAssets(files: EngineFileSystem(location: location), project: project)
            let videos = assets.textures.filter { $0.kind == "video" }.count
            var lines = ["рисуется: слоёв \(assets.document.layers.count), текстур \(assets.textures.count) (видео \(videos))"]
            let parallax = assets.document.parallax
            if parallax.enabled {
                lines.append("параллакс: amount \(parallax.amount), delay \(parallax.delay), mouseinfluence \(parallax.mouseInfluence)")
            }
            for layer in assets.document.layers {
                lines.append("  слой «\(layer.name)» \(layer.texture) режим \(layer.blendMode) смешивание \(layer.blending)")
            }
            lines.append(contentsOf: assets.skipped.map { "не рисуется: \($0)" })
            return lines
        } catch {
            return ["рисуется: нет (\(error.localizedDescription)), будет превью"]
        }
    }

    /// Counts of objects by kind and of effects in `scene.json`.
    static func sceneLines(_ data: Data) -> [String] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return ["сцена: scene.json не читается"] }
        let objects = root["objects"] as? [[String: Any]] ?? []
        var kinds: [String: Int] = [:]
        var effects = 0
        for object in objects {
            let kind = ["image", "particle", "sound", "text", "light", "shape"].first { object[$0] != nil } ?? "группа"
            kinds[kind, default: 0] += 1
            effects += (object["effects"] as? [Any])?.count ?? 0
        }
        let list = kinds.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        var lines = ["сцена: объектов \(objects.count) (\(list)), эффектов \(effects)"]
        if let general = root["general"] as? [String: Any],
           let size = general["orthogonalprojection"] as? [String: Any],
           let width = size["width"], let height = size["height"] {
            lines.append("проекция: \(width)×\(height)")
        }
        return lines
    }
}
