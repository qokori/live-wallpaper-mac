import AppKit
import AVFoundation
import Observation
import UniformTypeIdentifiers
import WallpaperCore

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
    }

    var assignments: WallpaperAssignments {
        didSet {
            guard assignments != oldValue else { return }
            if let data = try? JSONEncoder().encode(assignments) { defaults.set(data, forKey: Key.assignments) }
            controller.forgetFailures()
            reconcile()
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

    /// 30 or 60 frames per second for web wallpapers.
    var webFrameRate: Int {
        didSet {
            defaults.set(webFrameRate, forKey: Key.webFrameRate)
            controller.setWebFrameRate(webFrameRate)
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
    @ObservationIgnored private let controller = WallpaperController()
    @ObservationIgnored private let monitor = SystemMonitor()
    @ObservationIgnored private let pointer = PointerForwarder()

    /// Settings and the library live in `defaults` and `libraryStore`; tests pass their own.
    init(
        defaults: UserDefaults = .standard,
        libraryStore: LibraryStore = LibraryStore(fileURL: URL.applicationSupportDirectory.appending(path: "LiveWallpaper/library.json"))
    ) {
        self.defaults = defaults
        self.libraryStore = libraryStore
        let data = defaults.data(forKey: Key.assignments)
        let chosen = data.flatMap { try? JSONDecoder().decode(WallpaperAssignments.self, from: $0) } ?? WallpaperAssignments()
        assignments = chosen
        scaling = defaults.data(forKey: Key.scaling).flatMap { try? JSONDecoder().decode(ScalingChoices.self, from: $0) } ?? ScalingChoices()
        pauseOnBattery = defaults.bool(forKey: Key.pauseOnBattery)
        syncSystemWallpaper = defaults.object(forKey: Key.syncSystemWallpaper) as? Bool ?? true
        webInteractive = defaults.bool(forKey: Key.webInteractive)
        webFrameRate = defaults.integer(forKey: Key.webFrameRate) == 60 ? 60 : 30
        launchAtLogin = LaunchAtLogin.isEnabled
        var library = libraryStore.load()
        // Once, on the first launch with a library: the choices made before it existed. Later ones come in through apply.
        if !defaults.bool(forKey: Key.libraryAdopted) {
            library.adopt(chosen)
            try? libraryStore.save(library)
            defaults.set(true, forKey: Key.libraryAdopted)
        }
        self.library = library
    }

    func start() {
        controller.makeContent = { [weak self] source, label in
            guard let self else { throw CocoaError(.userCancelled) }
            return try self.makeContent(for: source, label: label)
        }
        controller.scalingFor = { [weak self] uuid in self?.scaling(forDisplay: uuid) ?? .fill }
        controller.onChange = { [weak self] in self?.refreshScreens() }
        controller.onShown = { [weak self] uuid, source in
            guard let self, self.syncSystemWallpaper, source.kind == .video else { return }
            self.applyFrame(of: source, toDisplay: uuid)
        }
        controller.onFailure = { [weak self] source, error in
            self?.notice = Notice(title: "Не удалось показать «\(source.title)»", text: error.localizedDescription)
        }
        pointer.targets = { [weak self] in self?.controller.webTargets.filter { $0.content.isPlaying } ?? [] }
        pointer.setEnabled(webInteractive)
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
        Task {
            guard await accept(source) else { return }
            apply(source, to: uuid.map(ApplyTarget.display) ?? .all)
        }
    }

    /// Adds to the library only (the window's «Добавить»); returns whether the source was accepted.
    @discardableResult
    func addToLibrary(_ source: WallpaperSource) async -> Bool {
        guard await accept(source) else { return false }
        library.add(source)
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
        library.add(source)
        assignments.apply(source, to: target)
    }

    func apply(_ item: SavedWallpaper, to target: ApplyTarget) {
        apply(item.source, to: target)
    }

    func removeFromLibrary(_ item: SavedWallpaper) {
        library.remove(id: item.id)
    }

    /// Displays that show this item now, by name.
    func screenNames(showing item: SavedWallpaper) -> [String] {
        let ids = assignments.displays(showing: item.source, among: screens.map(\.id))
        return screens.filter { ids.contains($0.id) }.map(\.name)
    }

    private func accept(_ source: WallpaperSource) async -> Bool {
        if let problem = await Self.problem(with: source) {
            notice = Notice(title: "Это не подойдёт", text: problem)
            return false
        }
        return true
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

    private func makeContent(for source: WallpaperSource, label: String) throws -> WallpaperContent {
        switch source.kind {
        case .video:
            return VideoContent(url: source.resolvedURL, label: label)
        case .web where source.isRemote:
            guard let url = WebAddress.normalize(source.location) else { throw SourceError.badAddress }
            return WebContent(target: .remote(url), frameRate: webFrameRate, label: label)
        case .web:
            let page = try Self.localPage(source.resolvedURL)
            return WebContent(target: .local(page), frameRate: webFrameRate, label: label)
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
    }

    private func applyFramesToAllScreens() {
        for screen in screens {
            guard let source = screen.source, source.kind == .video else { continue }
            applyFrame(of: source, toDisplay: screen.id)
        }
    }

    private func applyFrame(of source: WallpaperSource, toDisplay uuid: String) {
        Task {
            await SystemWallpaper.applyFirstFrame(of: source.resolvedURL, toDisplay: uuid) { [weak self] in
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
        case .video:
            let asset = AVURLAsset(url: source.resolvedURL)
            do {
                guard try await asset.load(.isPlayable) else { return "macOS не умеет воспроизводить этот файл." }
                guard try await !asset.loadTracks(withMediaType: .video).isEmpty else { return VideoError.noVideoTrack.localizedDescription }
            } catch {
                return error.localizedDescription
            }
            return nil
        }
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
