import AppKit
import AVFoundation
import Observation
import UniformTypeIdentifiers
import WallpaperCore
import WallpaperEngineKit

struct Notice: Identifiable {
    let id = UUID()
    let title: String
    let text: String
}

enum SourceError: LocalizedError {
    case noIndexPage
    case badAddress

    var errorDescription: String? {
        switch self {
        case .noIndexPage: "В папке нет index.html"
        case .badAddress: "Это не адрес http или https"
        }
    }
}

/// Settings, persisted in UserDefaults, and the glue between the menu, the system monitor and the windows.
@MainActor
@Observable
final class AppModel {
    private enum Key {
        static let assignments = "assignments"
        static let libraryAdopted = "libraryAdopted"
        static let scaling = "scaling"
        static let pauseOnBattery = "pauseOnBattery"
        static let syncSystemWallpaper = "syncSystemWallpaper"
        static let webInteractive = "webInteractive"
        static let webFrameRate = "webFrameRate"
        static let renderQuality = "renderQuality"
    }

    var assignments: WallpaperAssignments {
        didSet {
            guard assignments != oldValue else { return }
            if let data = try? JSONEncoder().encode(assignments) { defaults.set(data, forKey: Key.assignments) }
            controller.forgetFailures()
            reconcile()
            collectConvertedGarbage()
        }
    }

    /// Fill, fit or stretch, per screen like the sources; applies to videos and their desktop pictures.
    var scaling: ScalingChoices {
        didSet {
            guard scaling != oldValue else { return }
            if let data = try? JSONEncoder().encode(scaling) { defaults.set(data, forKey: Key.scaling) }
            applyScaling()
        }
    }

    var pauseOnBattery: Bool {
        didSet {
            defaults.set(pauseOnBattery, forKey: Key.pauseOnBattery)
            pushConditions()
        }
    }

    /// Manual pause from the menu; not remembered across launches.
    var userPaused = false {
        didSet { pushConditions() }
    }

    var syncSystemWallpaper: Bool {
        didSet {
            defaults.set(syncSystemWallpaper, forKey: Key.syncSystemWallpaper)
            if syncSystemWallpaper && !oldValue { applyFramesToAllScreens() }
        }
    }

    /// Clicks and pointer movement on the bare desktop reach web wallpapers.
    var webInteractive: Bool {
        didSet {
            defaults.set(webInteractive, forKey: Key.webInteractive)
            pointer.setEnabled(webInteractive)
        }
    }

    /// 15, 30 or 60 frames per second for scenes and web wallpapers.
    var webFrameRate: Int {
        didSet {
            // A rate that is not on offer becomes the standard one. The assignment may run this observer once more:
            // the second run sees a valid value and does the same work again, which does no harm.
            let valid = RenderQuality.frameRate(webFrameRate)
            if valid != webFrameRate { webFrameRate = valid }
            defaults.set(valid, forKey: Key.webFrameRate)
            controller.setWebFrameRate(valid)
        }
    }

    /// How large scenes are drawn: economy, to the screen (the standard), maximum.
    var renderQuality: RenderQuality {
        didSet {
            defaults.set(renderQuality.rawValue, forKey: Key.renderQuality)
            controller.setRenderQuality(renderQuality)
        }
    }

    var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != LaunchAtLogin.isEnabled else { return }
            LaunchAtLogin.setEnabled(launchAtLogin)
            launchAtLogin = LaunchAtLogin.isEnabled
        }
    }

    /// The wallpapers the person has added; saved to a file in Application Support on every change.
    var library: WallpaperLibrary {
        didSet {
            guard library != oldValue else { return }
            do { try libraryStore.save(library) } catch { Log.event("library not saved: \(error.localizedDescription)") }
        }
    }

    /// The names of the animations being turned into a video, those waiting included; the window shows them while any is left.
    var converting: [String] = []

    /// Something to tell the person; the window shows it as an alert.
    var notice: Notice? {
        didSet { if notice != nil { onNotice?() } }
    }
    /// Brings the window up when a notice arrives while it is closed.
    @ObservationIgnored var onNotice: (() -> Void)?

    /// Connected displays and what each shows; the controller refreshes it, tests set it.
    var screens: [ScreenStatus] = []
    var canRestoreWallpaper = SystemWallpaper.hasOriginals

    var perScreen: Bool {
        get { assignments.mode == .perScreen }
        set { assignments.mode = newValue ? .perScreen : .sameForAll }
    }

    var isPlaying: Bool { screens.contains(where: \.playing) }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let libraryStore: LibraryStore
    @ObservationIgnored private var knowsWhatIsUsed = false
    /// Videos made from big GIFs; the pictures themselves are never touched.
    @ObservationIgnored private let convertedDirectory: URL
    /// The longer side of the biggest screen, in pixels: the size a GIF is judged and converted at.
    @ObservationIgnored private let screenSide: () -> Int
    /// Conversions under way or waiting, by the video's path: the same picture added twice waits for the one already running.
    @ObservationIgnored private var conversions: [String: Task<Bool, Never>] = [:]
    /// The last conversion queued; the next one starts when it ends, so one encoder runs at a time.
    @ObservationIgnored private var conversionTail: Task<Void, Never>?
    /// Videos made but not yet in the library, so the cleanup leaves them alone.
    @ObservationIgnored private var reserved: Set<String> = []
    /// The name of the picture a video was made from, for its entry in the library.
    @ObservationIgnored private var originalNames: [String: String] = [:]
    @ObservationIgnored private let controller = WallpaperController()
    @ObservationIgnored private let monitor = SystemMonitor()
    @ObservationIgnored private let pointer = PointerForwarder()
    @ObservationIgnored private let sceneParallax = SceneParallax()

    /// Settings and the library live in `defaults` and `libraryStore`; tests pass their own.
    init(
        defaults: UserDefaults = .standard,
        libraryStore: LibraryStore = LibraryStore(fileURL: URL.applicationSupportDirectory.appending(path: "LiveWallpaper/library.json")),
        convertedDirectory: URL = URL.applicationSupportDirectory.appending(path: "LiveWallpaper/Converted", directoryHint: .isDirectory),
        screenSide: @escaping () -> Int = { NSScreen.biggestSide }
    ) {
        self.defaults = defaults
        self.libraryStore = libraryStore
        self.convertedDirectory = convertedDirectory
        self.screenSide = screenSide
        let data = defaults.data(forKey: Key.assignments)
        let chosen = data.flatMap { try? JSONDecoder().decode(WallpaperAssignments.self, from: $0) } ?? WallpaperAssignments()
        let assignmentsRead = data == nil || data.flatMap { try? JSONDecoder().decode(WallpaperAssignments.self, from: $0) } != nil
        assignments = chosen
        scaling = defaults.data(forKey: Key.scaling).flatMap { try? JSONDecoder().decode(ScalingChoices.self, from: $0) } ?? ScalingChoices()
        pauseOnBattery = defaults.bool(forKey: Key.pauseOnBattery)
        syncSystemWallpaper = defaults.object(forKey: Key.syncSystemWallpaper) as? Bool ?? true
        webInteractive = defaults.bool(forKey: Key.webInteractive)
        webFrameRate = RenderQuality.frameRate(defaults.integer(forKey: Key.webFrameRate))
        renderQuality = RenderQuality(stored: defaults.string(forKey: Key.renderQuality))
        launchAtLogin = LaunchAtLogin.isEnabled
        let loaded = libraryStore.read()
        var library = loaded.library
        // Only a library and screen choices that were both read in this run say what is in use.
        knowsWhatIsUsed = loaded.complete && assignmentsRead
        // Once, on the first launch with a library: the choices made before it existed. Later ones come in through apply.
        if !defaults.bool(forKey: Key.libraryAdopted) {
            library.adopt(chosen)
            try? libraryStore.save(library)
            defaults.set(true, forKey: Key.libraryAdopted)
        }
        self.library = library
        collectConvertedGarbage()
    }

    func start() {
        controller.makeContent = { [weak self] source, label in
            guard let self else { throw CocoaError(.userCancelled) }
            return try self.makeContent(for: source, label: label)
        }
        controller.scalingFor = { [weak self] uuid in self?.scaling(forDisplay: uuid) ?? .fill }
        controller.onChange = { [weak self] in self?.refreshScreens() }
        controller.onShown = { [weak self] uuid, source in
            guard let self, self.syncSystemWallpaper, !source.isPage else { return }
            self.applyFrame(of: source, toDisplay: uuid)
        }
        controller.onQualityRolledBack = { [weak self] quality in
            guard let self, self.renderQuality != quality else { return }
            let asked = self.renderQuality
            self.renderQuality = quality
            self.notice = Notice(
                title: "Качество сцены не применилось",
                text: "Сцена не нарисовалась на уровне «\(asked.title)», возвращён «\(quality.title)»."
            )
        }
        controller.onFailure = { [weak self] source, error in
            self?.notice = Notice(title: "Не удалось показать «\(source.title)»", text: error.localizedDescription)
        }
        pointer.targets = { [weak self] in self?.controller.webTargets.filter { $0.content.isPlaying } ?? [] }
        pointer.setEnabled(webInteractive)
        sceneParallax.targets = { [weak self] in self?.controller.sceneTargets ?? [] }
        monitor.onChange = { [weak self] in self?.pushConditions() }
        monitor.onWake = { [weak self] in self?.reconcile() }
        monitor.start()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                Log.event("system: screen parameters changed, \(NSScreen.screens.count) screen(s)")
                self?.reconcile()
            }
        }
        pushConditions()
        reconcile()
    }

    func stop() {
        controller.closeAll()
    }

    // MARK: Menu actions

    var statusLine: String {
        let withSource = screens.filter { $0.source != nil }
        guard !withSource.isEmpty else { return assignments.isEmpty ? "Обои не выбраны" : "Загрузка…" }
        let playing = withSource.filter(\.playing).count
        if playing == withSource.count {
            return withSource.count == 1 ? "Играет" : "Играет на всех экранах (\(playing))"
        }
        if playing > 0 { return "Играет на \(playing) из \(withSource.count) экранов" }
        let reason = withSource.compactMap(\.reasons.first).min { $0.priority < $1.priority }
        return "Пауза: " + (reason?.title ?? "")
    }

    /// Also used by the command line (`--video`, `--web`, `--video-for`, `--web-for`): checks the source, keeps it in
    /// the library and puts it on the screen, or on all screens when `uuid` is nil.
    func setSource(_ source: WallpaperSource, forDisplay uuid: String?) {
        Task { await show(source, forDisplay: uuid) }
    }

    /// Same as `setSource`, for a caller that waits: a big GIF is first turned into a video, as when it is added.
    func show(_ source: WallpaperSource, forDisplay uuid: String?) async {
        guard let accepted = await accept(source) else { return }
        apply(accepted, to: uuid.map(ApplyTarget.display) ?? .all)
    }

    /// Adds to the library only (the window's «Добавить»); returns whether the source was accepted.
    @discardableResult
    func addToLibrary(_ source: WallpaperSource) async -> Bool {
        guard let accepted = await accept(source) else { return false }
        addNamed(accepted)
        return true
    }

    func addWebAddress(_ text: String) async -> Bool {
        guard let url = WebAddress.normalize(text) else {
            notice = Notice(title: "Неверный адрес", text: SourceError.badAddress.localizedDescription)
            return false
        }
        return await addToLibrary(WallpaperSource(kind: .web, location: url.absoluteString))
    }

    func apply(_ source: WallpaperSource, to target: ApplyTarget) {
        addNamed(source)
        assignments.apply(source, to: target)
    }

    func apply(_ item: SavedWallpaper, to target: ApplyTarget) {
        apply(item.source, to: target)
    }

    func removeFromLibrary(_ item: SavedWallpaper) {
        library.remove(id: item.id)
        collectConvertedGarbage()
        if item.source.kind == .wallpaperEngine, let engine = try? EngineSupport.open(item.source.resolvedURL) { EngineCache.remove(for: engine) }
    }

    /// Displays that show this item now, by name.
    func screenNames(showing item: SavedWallpaper) -> [String] {
        let ids = assignments.displays(showing: item.source, among: screens.map(\.id))
        return screens.filter { ids.contains($0.id) }.map(\.name)
    }

    /// The source as it goes into the library, or nil after telling the person why it cannot be shown. A Wallpaper
    /// Engine project comes back as its folder with its type filled in.
    private func accept(_ source: WallpaperSource) async -> WallpaperSource? {
        var source = source
        if source.kind == .wallpaperEngine {
            do { source = try EngineSupport.prepare(source) } catch {
                notice = Notice(title: "Это не подойдёт", text: error.localizedDescription)
                return nil
            }
        }
        if source.kind == .gif {
            // Read once, off the main thread: a big file takes a while to go through.
            let url = source.resolvedURL
            let read = await Task.detached { Result { try AnimatedImageInfo.read(url) } }.value
            switch read {
            case .success(let info): return await convertedIfBig(source, info: info)
            case .failure(let error):
                notice = Notice(title: "Это не подойдёт", text: GifError(error).localizedDescription)
                return nil
            }
        }
        if let problem = await Self.problem(with: source) {
            notice = Notice(title: "Это не подойдёт", text: problem)
            return nil
        }
        return source
    }

    /// A GIF or APNG whose frames do not all stay decoded costs a decode per frame (measured 20–40 % of a core), so it
    /// goes into the library as a video made from it. The original stays where it is. A conversion that fails leaves
    /// the picture as it was: it still plays, only heavier. Several at once go one after another; the same picture twice
    /// is made once.
    private func convertedIfBig(_ source: WallpaperSource, info: AnimatedImageInfo) async -> WallpaperSource {
        let side = screenSide()
        guard GifConversionPolicy.shouldConvert(info, maxSide: side) else { return source }
        let original = source.resolvedURL
        let video = GifTranscoder.videoURL(for: original, maxSide: side, in: convertedDirectory)
        let converted = WallpaperSource(kind: .video, location: video.path)
        originalNames[video.path] = original.deletingPathExtension().lastPathComponent
        let existing = (try? FileManager.default.attributesOfItem(atPath: video.path)[.size] as? Int) ?? 0
        if existing > 0 {
            reserved.insert(video.path)
            return converted
        }
        if let running = conversions[video.path] { return await running.value ? converted : source }
        let name = original.lastPathComponent
        let previous = conversionTail
        converting.append(name)
        let task = Task { @MainActor [weak self] () -> Bool in
            await previous?.value
            var done = false
            do {
                try await GifTranscoder.convert(original, info: info, to: video, maxSide: side)
                Log.event("convert \(name): \(info.frameCount) frames → \(video.lastPathComponent)")
                done = true
            } catch {
                Log.event("convert \(name): \(error.localizedDescription); the picture is used as it is")
            }
            if let self {
                if done { reserved.insert(video.path) }
                conversions[video.path] = nil
                if let at = converting.firstIndex(of: name) { converting.remove(at: at) }
            }
            return done
        }
        conversions[video.path] = task
        conversionTail = Task { _ = await task.value }
        return await task.value ? converted : source
    }

    /// Whether the entry plays a video made from a GIF, which is deleted once nothing shows it.
    func isConvertedVideo(_ item: SavedWallpaper) -> Bool {
        item.source.kind == .video && item.source.resolvedURL.standardizedFileURL.path.hasPrefix(convertedDirectory.standardizedFileURL.path + "/")
    }

    /// Deletes what is left in the folder of converted videos: a folder no library entry and no screen points to, and
    /// half-written files. A video on a screen stays even when its entry is gone, so a restart finds it. Not done when the
    /// library or the screen choices could not be read in this run (what is in use is unknown then).
    private func collectConvertedGarbage() {
        let fm = FileManager.default
        guard knowsWhatIsUsed,
              let folders = try? fm.contentsOfDirectory(at: convertedDirectory, includingPropertiesForKeys: nil)
        else { return }
        let chosen = [assignments.shared].compactMap { $0 } + Array(assignments.perScreen.values)
        var used = Set(conversions.keys).union(reserved)
        for source in library.items.map(\.source) + chosen where source.kind == .video {
            used.insert(source.location)
            used.insert(source.resolvedURL.path)
            used.insert(source.resolvedURL.standardizedFileURL.path)
        }
        for folder in folders where (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            let prefix = folder.standardizedFileURL.path + "/"
            let inUse = used.contains { $0.hasPrefix(prefix) || $0.hasPrefix(folder.path + "/") }
            if !inUse {
                try? fm.removeItem(at: folder)
            } else if !conversions.keys.contains(where: { $0.hasPrefix(prefix) || $0.hasPrefix(folder.path + "/") }) {
                for file in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
                where file.lastPathComponent.hasPrefix(".partial-") {
                    try? fm.removeItem(at: file)
                }
            }
        }
    }

    /// Puts the source in the library; a Wallpaper Engine project that is new there is named by its `title`.
    private func addNamed(_ source: WallpaperSource) {
        let item = library.add(source)
        reserved.remove(source.location)
        if let name = originalNames[source.location], item.name == nil { library.rename(id: item.id, to: name) }
        if source.kind == .wallpaperEngine, item.name == nil, let title = EngineSupport.title(of: source) {
            library.rename(id: item.id, to: title)
        }
    }

    func useShared(forDisplay uuid: String) {
        assignments.perScreen[uuid] = nil
    }

    /// Clears every choice and puts the previous desktop pictures back; frame sync and scaling stay for the next video.
    func removeAll() {
        assignments = WallpaperAssignments(mode: assignments.mode)
        SystemWallpaper.restoreOriginals()
        canRestoreWallpaper = SystemWallpaper.hasOriginals
    }

    func restoreSystemWallpaper() {
        syncSystemWallpaper = false
        SystemWallpaper.restoreOriginals()
        canRestoreWallpaper = SystemWallpaper.hasOriginals
    }

    func ownSource(forDisplay uuid: String) -> String? {
        assignments.perScreen[uuid]?.title
    }

    var sharedTitle: String? { assignments.shared?.title }

    func scaling(forDisplay uuid: String) -> WallpaperScaling {
        scaling.scaling(forDisplay: uuid, mode: assignments.mode)
    }

    // MARK: Plumbing

    private func makeContent(for source: WallpaperSource, label: String) throws -> ContentBuild {
        switch source.kind {
        case .video:
            return .ready(VideoContent(url: source.resolvedURL, label: label))
        case .gif:
            return .ready(GifContent(url: source.resolvedURL, label: label))
        case .wallpaperEngine:
            return try EngineSupport.build(
                for: source, settings: { [weak self] in .init(frameRate: self?.webFrameRate ?? RenderQuality.standardFrameRate, quality: self?.renderQuality ?? .standard) },
                label: label
            ) { [weak self] in
                self?.sceneSnapshotStored(for: source)
            }
        case .web where source.isRemote:
            guard let url = WebAddress.normalize(source.location) else { throw SourceError.badAddress }
            return .ready(WebContent(target: .remote(url), frameRate: webFrameRate, label: label))
        case .web:
            let page = try Self.localPage(source.resolvedURL)
            return .ready(WebContent(target: .local(page), frameRate: webFrameRate, label: label))
        }
    }

    private static func localPage(_ url: URL) throws -> LocalPage {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let page = LocalPage.resolve(path: url.path, isDirectory: isDirectory.boolValue)
        guard FileManager.default.fileExists(atPath: page.entry) else { throw SourceError.noIndexPage }
        return page
    }

    private func reconcile() {
        controller.reconcile { [assignments] uuid in assignments.source(forDisplay: uuid) }
        applyScaling()
    }

    /// Videos on screen follow the scaling at once; their desktop pictures get it too when frame sync is on.
    private func applyScaling() {
        let changed = controller.refreshScaling()
        guard syncSystemWallpaper else { return }
        for (uuid, source) in changed { applyFrame(of: source, toDisplay: uuid) }
    }

    private func pushConditions() {
        controller.conditions = SystemConditions(
            userPaused: userPaused,
            systemSleeping: monitor.systemSleeping,
            screensAsleep: monitor.screensAsleep,
            screenLocked: monitor.screenLocked,
            sessionActive: monitor.sessionActive,
            lowPowerMode: monitor.lowPowerMode,
            onBattery: monitor.onBattery,
            pauseOnBattery: pauseOnBattery
        )
    }

    private func refreshScreens() {
        let current = controller.statuses
        if current != screens { screens = current }
        sceneParallax.refresh()
    }

    /// A scene's snapshot is there: the desktop picture of the screens showing it is the scene itself, not its small preview.
    private func sceneSnapshotStored(for source: WallpaperSource) {
        guard syncSystemWallpaper else { return }
        for screen in screens where screen.source?.location == source.location {
            applyFrame(of: source, toDisplay: screen.id)
        }
    }

    private func applyFramesToAllScreens() {
        for screen in screens {
            guard let source = screen.source, !source.isPage else { continue }
            applyFrame(of: source, toDisplay: screen.id)
        }
    }

    private func applyFrame(of source: WallpaperSource, toDisplay uuid: String) {
        let url = source.kind == .wallpaperEngine ? EngineSupport.frameURL(of: source) : source.resolvedURL
        guard let url else { return }
        Task {
            await SystemWallpaper.applyFirstFrame(of: url, toDisplay: uuid) { [weak self] in
                self?.scaling(forDisplay: uuid) ?? .fill
            }
            canRestoreWallpaper = SystemWallpaper.hasOriginals
        }
    }

    private static func problem(with source: WallpaperSource) async -> String? {
        switch source.kind {
        case .web where source.isRemote:
            return WebAddress.normalize(source.location) == nil ? SourceError.badAddress.localizedDescription : nil
        case .web:
            do { _ = try localPage(source.resolvedURL) } catch { return error.localizedDescription }
            return nil
        case .gif:
            return nil // a GIF is read and turned into a video (or kept) before it gets here
        case .wallpaperEngine:
            do {
                let item = try EngineSupport.open(source.resolvedURL)
                switch item.type {
                case .video: return await videoProblem(item.mainFile!)
                case .scene, .web: return nil
                }
            } catch { return error.localizedDescription }
        case .video:
            return await videoProblem(source.resolvedURL)
        }
    }

    private static func videoProblem(_ url: URL) async -> String? {
        let asset = AVURLAsset(url: url)
        do {
            guard try await asset.load(.isPlayable) else { return "macOS не умеет воспроизводить этот файл." }
            guard try await !asset.loadTracks(withMediaType: .video).isEmpty else { return VideoError.noVideoTrack.localizedDescription }
        } catch {
            return error.localizedDescription
        }
        return nil
    }
}

extension WallpaperSource {
    /// Local file or folder: the bookmark finds it after a move or rename; the stored path is the fallback.
    var resolvedURL: URL {
        if let bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], bookmarkDataIsStale: &stale) {
                return url
            }
        }
        return URL(filePath: location)
    }
}

extension WallpaperScaling {
    var title: String {
        switch self {
        case .fill: "Заполнить"
        case .fit: "По размеру"
        case .stretch: "Растянуть"
        }
    }
}

extension PauseReason {
    var priority: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    var title: String {
        switch self {
        case .userPaused: "вручную"
        case .systemSleep: "сон"
        case .screensAsleep: "экран выключен"
        case .screenLocked: "экран заблокирован"
        case .sessionInactive: "сеанс неактивен"
        case .lowPowerMode: "режим энергосбережения"
        case .onBattery: "питание от батареи"
        case .occluded: "обои закрыты окнами"
        }
    }
}
