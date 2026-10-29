import Foundation

/// The files of a project as one tree: the scene package first, then the project folder. Names are matched in any
/// letter case (the files come from Windows).
public struct EngineFileSystem: Sendable {
    public let archive: PKGArchive?
    public let folder: URL

    public init(folder: URL, archive: PKGArchive?) {
        self.folder = folder
        self.archive = archive
    }

    public init(location: EngineLocation) throws {
        self.init(folder: location.folder, archive: try location.package.map { try PKGArchive(contentsOf: $0) })
    }

    /// The bytes of a file. From the package they are a window onto the mapped file, not a copy.
    public func data(_ path: String) -> Data? {
        if let slice = archive?.slice(of: path) { return slice }
        guard let url = EngineLocation.file(path, in: folder) else { return nil }
        return try? Data(contentsOf: url, options: .alwaysMapped)
    }

    public func contains(_ path: String) -> Bool {
        if archive?.contains(path) == true { return true }
        return EngineLocation.file(path, in: folder) != nil
    }
}
