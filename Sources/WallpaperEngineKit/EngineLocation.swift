import Foundation

/// Where a project is, given what a person chose: the project folder, a `project.json`, or a `.pkg` next to one.
public struct EngineLocation: Equatable, Sendable {
    public enum Failure: Error, Equatable, LocalizedError {
        case notAProject
        case noProjectBesidePackage

        public var errorDescription: String? {
            switch self {
            case .notAProject: "Нужна папка проекта Wallpaper Engine, файл project.json или пакет .pkg."
            case .noProjectBesidePackage:
                "Рядом с пакетом нет project.json. Скопируйте папку проекта целиком, а не только .pkg."
            }
        }
    }

    /// The folder with `project.json`.
    public let folder: URL
    /// The scene package in it (`scene.pkg`, `gifscene.pkg` or any other `.pkg`), if there is one.
    public let package: URL?

    public var projectFile: URL { Self.find("project.json", in: folder) ?? folder.appending(path: "project.json") }

    public init(folder: URL, package: URL?) {
        self.folder = folder
        self.package = package
    }

    public static func resolve(_ url: URL) throws -> EngineLocation {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { throw Failure.notAProject }
        if isDirectory.boolValue {
            guard find("project.json", in: url) != nil else { throw EngineProject.Failure.noProject }
            return EngineLocation(folder: url, package: findPackage(in: url))
        }
        let name = url.lastPathComponent.lowercased()
        if name == "project.json" {
            let folder = url.deletingLastPathComponent()
            return EngineLocation(folder: folder, package: findPackage(in: folder))
        }
        if url.pathExtension.lowercased() == "pkg" {
            // The package must be one of ours (and not a macOS installer) before anything else is said about it.
            _ = try PKGArchive(contentsOf: url)
            let folder = url.deletingLastPathComponent()
            guard find("project.json", in: folder) != nil else { throw Failure.noProjectBesidePackage }
            return EngineLocation(folder: folder, package: url)
        }
        throw Failure.notAProject
    }

    /// A file of the project by name, in any letter case (the folders come from Windows). One name, no slashes.
    public static func find(_ name: String, in folder: URL) -> URL? {
        // The listing gives the real spelling on any volume, case-sensitive or not.
        guard let listed = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return nil }
        let lower = name.lowercased()
        let real = listed.first { $0 == name } ?? listed.first { $0.lowercased() == lower }
        return real.map { folder.appending(path: $0) }
    }

    /// A path from `project.json` (`file`, `preview`) inside the folder, or nil when it is absolute, climbs out with `..`
    /// or is not there.
    public static func file(_ relative: String, in folder: URL) -> URL? {
        let parts = relative.replacingOccurrences(of: "\\", with: "/").split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, !parts.contains(""), !parts.contains("..") else { return nil }
        var url = folder
        for part in parts {
            guard let next = find(part, in: url) else { return nil }
            url = next
        }
        return url
    }

    private static func findPackage(in folder: URL) -> URL? {
        let listed = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
        let packages = listed.filter { $0.lowercased().hasSuffix(".pkg") }
        let name = packages.first { $0.lowercased() == "scene.pkg" } ?? packages.first
        return name.map { folder.appending(path: $0) }
    }
}
