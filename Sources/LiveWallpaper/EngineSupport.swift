import AppKit
import ImageIO
import WallpaperCore
import WallpaperEngineKit

enum EngineSourceError: LocalizedError {
    case application
    case unknownType(String)
    case missingFile(String)
    case unsupportedVideo(String)
    case noPreview
    case noPackage

    var errorDescription: String? {
        switch self {
        case .application: "Это программа для Windows (type: application), на Mac её запустить нельзя."
        case .unknownType(let type): "Неизвестный тип проекта «\(type)»."
        case .missingFile(let name): "В проекте нет файла «\(name)»."
        case .unsupportedVideo(let ext):
            "Видео в формате «\(ext)» macOS не воспроизводит. Подходят mp4, m4v и mov."
        case .noPreview: "Эту сцену пока нельзя нарисовать, а картинки предпросмотра в проекте нет."
        case .noPackage: "В проекте нет пакета scene.pkg: сцену нечем рисовать."
        }
    }
}

/// A Wallpaper Engine project that is ready to show: where it is, what it says, and the files that matter.
struct EngineItem {
    let folder: URL
    let project: EngineProject
    let type: EngineType
    /// The video file or the page's entry; nil for a scene.
    let mainFile: URL?
    /// The preview picture, if the project has one.
    let previewFile: URL?
    /// The scene package (`scene.pkg`).
    var package: URL? = nil
}

/// What the controller gets for a source: content to show now, or a job that produces it without blocking the main thread.
enum ContentBuild {
    case ready(WallpaperContent)
    case later(@MainActor () async throws -> WallpaperContent)
}

/// Wallpaper Engine projects: what is accepted, what is shown, and with which pictures.
enum EngineSupport {
    static let videoExtensions: Set<String> = ["mp4", "m4v", "mov"]
    private static let previewNames = ["preview.gif", "preview.jpg", "preview.jpeg", "preview.png"]

    /// Reads a project from a folder, a `project.json` or a `.pkg` and checks it can be shown.
    static func open(_ url: URL) throws -> EngineItem {
        let location = try EngineLocation.resolve(url)
        let project = try EngineProject(contentsOf: location.projectFile)
        let folder = location.folder
        let preview = project.preview.flatMap { EngineLocation.file($0, in: folder) }
            ?? previewNames.lazy.compactMap { EngineLocation.find($0, in: folder) }.first
        switch project.kind {
        case .application:
            throw EngineSourceError.application
        case .other(let type):
            throw EngineSourceError.unknownType(type)
        case .video:
            guard let name = project.file, let file = EngineLocation.file(name, in: folder) else {
                throw EngineSourceError.missingFile(project.file ?? "video")
            }
            let ext = file.pathExtension.lowercased()
            guard videoExtensions.contains(ext) else { throw EngineSourceError.unsupportedVideo(ext) }
            return EngineItem(folder: folder, project: project, type: .video, mainFile: file, previewFile: preview)
        case .web:
            let name = project.file ?? "index.html"
            guard let file = EngineLocation.file(name, in: folder) else { throw EngineSourceError.missingFile(name) }
            return EngineItem(folder: folder, project: project, type: .web, mainFile: file, previewFile: preview)
        case .scene:
            guard location.package != nil || preview != nil else { throw EngineSourceError.noPackage }
            return EngineItem(folder: folder, project: project, type: .scene, mainFile: nil, previewFile: preview, package: location.package)
        }
    }

    /// The source as it goes into the library: the project's folder (also when a `.pkg` or `project.json` was chosen),
    /// a bookmark to the folder and the project's type.
    static func prepare(_ source: WallpaperSource) throws -> WallpaperSource {
        let item = try open(source.resolvedURL)
        var prepared = source
        prepared.location = item.folder.path
        prepared.bookmark = try? item.folder.bookmarkData()
        prepared.engine = item.type
        return prepared
    }

    static func title(of source: WallpaperSource) -> String? {
        guard let item = try? open(source.resolvedURL) else { return nil }
        let title = item.project.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return title?.isEmpty == false ? title : nil
    }

    /// What a project's content needs before it can be put on screen: nothing (`ready`), or work that must not block
    /// the main thread (`later`: the scene's package is read and its textures decoded in the background).
    ///
    /// `settings` is asked when the content is made, so a scene that was built while the settings changed gets the new ones.
    /// A build that is cancelled while it waits stops decoding and makes no web view.
    @MainActor
    static func build(
        for source: WallpaperSource, settings: @escaping @MainActor () -> SceneSettings, label: String,
        snapshotStored: @escaping @MainActor () -> Void = {}
    ) throws -> ContentBuild {
        let item = try open(source.resolvedURL)
        let known = item.type == .scene ? cachedSceneAssets(item) : nil
        guard item.type == .scene, known == nil else {
            let now = settings()
            return .ready(try content(for: item, assets: known, frameRate: now.frameRate, quality: now.quality, label: label, snapshotStored: snapshotStored))
        }
        return .later {
            let assets: SceneAssets?
            do { assets = try await loadSceneAssets(item) } catch is CancellationError { throw CancellationError() } catch {
                Log.event("\(label): сцену не удалось разобрать: \(error.localizedDescription)")
                assets = nil
            }
            try Task.checkCancellation()
            let now = settings()
            return try content(for: item, assets: assets, frameRate: now.frameRate, quality: now.quality, label: label, snapshotStored: snapshotStored)
        }
    }

    /// The frame rate and quality a scene is drawn with.
    struct SceneSettings {
        var frameRate: Int
        var quality: RenderQuality
    }

    /// The same, built on the calling thread: for tests and for content that needs no waiting.
    @MainActor
    static func content(
        for source: WallpaperSource, frameRate: Int, quality: RenderQuality = .standard, label: String, snapshotStored: @escaping @MainActor () -> Void = {}
    ) throws -> WallpaperContent {
        let item = try open(source.resolvedURL)
        let assets = item.type == .scene ? try? sharedSceneAssets(item) : nil
        return try content(for: item, assets: assets, frameRate: frameRate, quality: quality, label: label, snapshotStored: snapshotStored)
    }

    /// `assets` is the scene's decoded package, nil when it could not be read (the preview is shown then).
    @MainActor
    private static func content(
        for item: EngineItem, assets: SceneAssets?, frameRate: Int, quality: RenderQuality, label: String, snapshotStored: @escaping @MainActor () -> Void
    ) throws -> WallpaperContent {
        switch item.type {
        case .video:
            return VideoContent(url: item.mainFile!, label: label)
        case .web:
            let page = LocalPage(entry: item.mainFile!.path, readAccess: item.folder.path)
            return WebContent(target: .local(page), frameRate: frameRate, label: label, engineProperties: item.project.properties)
        case .scene:
            if let assets {
                for line in assets.skipped { Log.event("\(label): сцена: \(line)") }
                let web = WebContent(target: .scene(assets), frameRate: frameRate, quality: quality, label: label)
                // Once per project: a later run finds the picture there.
                if EngineCache.snapshot(for: item) == nil {
                    web.sceneSnapshot = { image in
                        if EngineCache.storeSnapshot(image, for: item) != nil { snapshotStored() }
                    }
                }
                return web
            }
            // A scene that cannot be drawn shows its preview.
            guard let preview = item.previewFile else { throw EngineSourceError.noPreview }
            Log.event("\(label): сцену нарисовать нельзя, показываю превью")
            if (try? AnimatedImageInfo.read(preview)) != nil { return GifContent(url: preview, label: label) }
            return StillContent(url: preview, label: label)
        }
    }

    static func sceneAssets(_ item: EngineItem) throws -> SceneAssets {
        try SceneAssets(files: try sceneFiles(item), project: item.project)
    }

    private static func sceneFiles(_ item: EngineItem) throws -> EngineFileSystem {
        guard let package = item.package else { throw EngineSourceError.noPackage }
        return EngineFileSystem(folder: item.folder, archive: try PKGArchive(contentsOf: package))
    }

    private final class WeakAssets {
        weak var assets: SceneAssets?
        init(_ assets: SceneAssets) { self.assets = assets }
    }

    private nonisolated(unsafe) static var shared: [String: WeakAssets] = [:]
    private nonisolated(unsafe) static var checks: [String: SceneAssets.Check] = [:]
    private static let cacheLock = NSLock()

    /// Identifies a project's content: where it is and when its package and `project.json` last changed.
    static func key(_ item: EngineItem) -> String {
        func modified(_ url: URL?) -> TimeInterval {
            url.flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }?.timeIntervalSince1970 ?? 0
        }
        return "\(item.folder.path)|\(modified(item.package))|\(modified(item.folder.appending(path: "project.json")))"
    }

    /// A background build and how many screens wait for it; the last to leave cancels it.
    private final class Build: @unchecked Sendable {
        let task: Task<SceneAssets, Error>
        var waiters = 1
        init(_ task: Task<SceneAssets, Error>) { self.task = task }
    }

    private nonisolated(unsafe) static var inFlight: [String: Build] = [:]
    #if DEBUG
    /// For tests only: holds a background build back until it returns.
    nonisolated(unsafe) static var buildGate: (@Sendable () -> Void)?

    /// For tests only: builds running and the screens waiting for them.
    static var buildsInFlight: (builds: Int, waiters: Int) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return (inFlight.count, inFlight.values.reduce(0) { $0 + $1.waiters })
    }
    #endif

    private static func cachedSceneAssets(_ item: EngineItem) -> SceneAssets? {
        let key = key(item)
        cacheLock.lock()
        defer { cacheLock.unlock() }
        shared = shared.filter { $0.value.assets != nil }
        return shared[key]?.assets
    }

    /// One `SceneAssets` per project for every screen showing it; it goes away with the last of them.
    private static func sharedSceneAssets(_ item: EngineItem) throws -> SceneAssets {
        if let known = cachedSceneAssets(item) { return known }
        let assets = try sceneAssets(item)
        let key = key(item)
        cacheLock.lock()
        shared[key] = WeakAssets(assets)
        cacheLock.unlock()
        return assets
    }

    /// The same, read and decoded in the background. Screens that ask for the same scene while it is being built
    /// wait for that one build; when the last of them is cancelled, the build stops too.
    static func loadSceneAssets(_ item: EngineItem) async throws -> SceneAssets {
        let key = key(item)
        let build: Build
        switch join(key, item) {
        case .known(let assets): return assets
        case .running(let running): build = running
        }
        do {
            let assets = try await withTaskCancellationHandler { try await build.task.value } onCancel: { leave(key, build) }
            finish(key, build, assets)
            return assets
        } catch {
            finish(key, build, nil)
            throw error
        }
    }

    private enum Join {
        case known(SceneAssets)
        case running(Build)
    }

    /// One lock section for the cache check and the lookup, so no second decode starts in between.
    private static func join(_ key: String, _ item: EngineItem) -> Join {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let known = shared[key]?.assets { return .known(known) }
        if let running = inFlight[key] {
            running.waiters += 1
            return .running(running)
        }
        let build = Build(Task.detached(priority: .userInitiated) {
            #if DEBUG
            buildGate?()
            #endif
            try Task.checkCancellation()
            return try sceneAssets(item)
        })
        inFlight[key] = build
        return .running(build)
    }

    private static func leave(_ key: String, _ build: Build) {
        cacheLock.lock()
        build.waiters -= 1
        let last = build.waiters <= 0
        if last, inFlight[key] === build { inFlight[key] = nil }
        cacheLock.unlock()
        // Outside the lock: a cancellation handler that touched the cache would otherwise wait for it for ever.
        if last { build.task.cancel() }
    }

    private static func finish(_ key: String, _ build: Build, _ assets: SceneAssets?) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let assets { shared[key] = WeakAssets(assets) }
        if inFlight[key] === build { inFlight[key] = nil }
    }

    /// Whether the scene is drawn (and not only shown by its preview) and what it leaves out. Decodes no texture, so it
    /// is cheap, but it reads files: call it off the main thread. Remembered until the project's package changes.
    static func sceneCheck(_ source: WallpaperSource) -> SceneAssets.Check {
        guard let item = try? open(source.resolvedURL) else { return .init(drawable: false, omissions: .init()) }
        let key = key(item)
        cacheLock.lock()
        let known = checks[key]
        cacheLock.unlock()
        if let known { return known }
        let result = (try? sceneFiles(item)).map { SceneAssets.check(files: $0, project: item.project) }
            ?? .init(drawable: false, omissions: .init())
        cacheLock.lock()
        checks[key] = result
        cacheLock.unlock()
        return result
    }

    static func sceneIsDrawn(_ source: WallpaperSource) -> Bool { sceneCheck(source).drawable }

    /// The file whose first frame becomes the desktop picture: the video, a drawn scene's snapshot (its preview until
    /// there is one). Pages have none.
    static func frameURL(of source: WallpaperSource) -> URL? {
        guard let item = try? open(source.resolvedURL) else { return nil }
        switch item.type {
        case .video: return item.mainFile
        case .scene: return EngineCache.snapshot(for: item) ?? item.previewFile
        case .web: return nil
        }
    }
}

/// One still picture on a layer, scaled like a video. The preview of a scene whose preview is not animated.
@MainActor
final class StillContent: WallpaperContent {
    private let url: URL
    private let label: String
    private let stillView = GifView()

    init(url: URL, label: String) {
        self.url = url
        self.label = label
    }

    var view: NSView { stillView }

    func start(ready: @escaping @MainActor () -> Void, failed: @escaping @MainActor (Error) -> Void) {
        let maxSide = NSScreen.screens.map { Int(max($0.frame.width, $0.frame.height) * $0.backingScaleFactor) }.max() ?? 3840
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceShouldCacheImmediately: true,
                  kCGImageSourceThumbnailMaxPixelSize: max(maxSide, 1),
              ] as CFDictionary)
        else {
            failed(GifError.unreadable)
            return
        }
        stillView.layer?.contents = image
        Log.event("\(label): \(url.lastPathComponent), still picture \(image.width)x\(image.height)")
        ready()
    }

    func setScaling(_ scaling: WallpaperScaling) {
        stillView.layer?.contentsGravity = CALayerContentsGravity(rawValue: scaling.layerGravity)
    }

    func setPlaying(_ playing: Bool) {}

    func stop() {
        stillView.layer?.contents = nil
    }
}
