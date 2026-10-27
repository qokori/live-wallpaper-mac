import AppKit
import AVFoundation
import Observation
import UniformTypeIdentifiers
import WallpaperCore

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

    private(set) var screens: [ScreenStatus] = []
    private(set) var canRestoreWallpaper = SystemWallpaper.hasOriginals

    var perScreen: Bool {
        get { assignments.mode == .perScreen }
        set { assignments.mode = newValue ? .perScreen : .sameForAll }
    }

    var isPlaying: Bool { screens.contains(where: \.playing) }

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let controller = WallpaperController()
    @ObservationIgnored private let monitor = SystemMonitor()
    @ObservationIgnored private let pointer = PointerForwarder()

    init() {
        let defaults = UserDefaults.standard
        let data = defaults.data(forKey: Key.assignments)
        assignments = data.flatMap { try? JSONDecoder().decode(WallpaperAssignments.self, from: $0) } ?? WallpaperAssignments()
        pauseOnBattery = defaults.bool(forKey: Key.pauseOnBattery)
        syncSystemWallpaper = defaults.object(forKey: Key.syncSystemWallpaper) as? Bool ?? true
        webInteractive = defaults.bool(forKey: Key.webInteractive)
        webFrameRate = defaults.integer(forKey: Key.webFrameRate) == 60 ? 60 : 30
        launchAtLogin = LaunchAtLogin.isEnabled
    }

    func start() {
        controller.makeContent = { [weak self] source, label in
            guard let self else { throw CocoaError(.userCancelled) }
            return try self.makeContent(for: source, label: label)
        }
        controller.onChange = { [weak self] in self?.refreshScreens() }
        controller.onShown = { [weak self] uuid, source in
            guard let self, self.syncSystemWallpaper, source.kind == .video else { return }
            Task {
                await SystemWallpaper.applyFirstFrame(of: source.resolvedURL, toDisplay: uuid)
                self.canRestoreWallpaper = SystemWallpaper.hasOriginals
            }
        }
        controller.onFailure = { source, error in
            Self.alert("Не удалось показать «\(source.title)»", error.localizedDescription)
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

    func chooseVideo(forDisplay uuid: String?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        panel.message = panelMessage("Видео (mp4, mov, HEVC)", uuid)
        guard let url = run(panel) else { return }
        setSource(WallpaperSource(kind: .video, location: url.path, bookmark: try? url.bookmarkData()), forDisplay: uuid)
    }

    func chooseWebFolder(forDisplay uuid: String?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.html]
        panel.message = panelMessage("Папка с index.html или файл .html", uuid)
        guard let url = run(panel) else { return }
        setSource(WallpaperSource(kind: .web, location: url.path, bookmark: try? url.bookmarkData()), forDisplay: uuid)
    }

    func enterWebAddress(forDisplay uuid: String?) {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = "https://example.com/wallpaper/"
        if let current = assignments.shared, current.isRemote { field.stringValue = current.location }
        let alert = NSAlert()
        alert.messageText = "Адрес веб-страницы"
        alert.informativeText = panelMessage("Страница откроется на рабочем столе", uuid)
        alert.accessoryView = field
        alert.addButton(withTitle: "Открыть")
        alert.addButton(withTitle: "Отмена")
        alert.window.initialFirstResponder = field
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let url = WebAddress.normalize(field.stringValue) else {
            Self.alert("Неверный адрес", SourceError.badAddress.localizedDescription)
            return
        }
        setSource(WallpaperSource(kind: .web, location: url.absoluteString), forDisplay: uuid)
    }

    /// Also used by the command line (`--video`, `--web`, `--video-for`, `--web-for`).
    func setSource(_ source: WallpaperSource, forDisplay uuid: String?) {
        Task {
            if let problem = await Self.problem(with: source) {
                Self.alert("Это не подойдёт", problem)
                return
            }
            if let uuid {
                assignments.perScreen[uuid] = source
                assignments.mode = .perScreen
            } else {
                assignments.shared = source
            }
        }
    }

    func useShared(forDisplay uuid: String) {
        assignments.perScreen[uuid] = nil
    }

    /// Clears every choice and puts the previous desktop pictures back; frame sync stays on for the next video.
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
            Task {
                await SystemWallpaper.applyFirstFrame(of: source.resolvedURL, toDisplay: screen.id)
                canRestoreWallpaper = SystemWallpaper.hasOriginals
            }
        }
    }

    private func panelMessage(_ text: String, _ uuid: String?) -> String {
        if let uuid, let screen = screens.first(where: { $0.id == uuid }) { return "\(text) — экран «\(screen.name)»" }
        return perScreen ? "\(text) — для экранов без своих обоев" : "\(text) — для всех экранов"
    }

    private func run(_ panel: NSOpenPanel) -> URL? {
        panel.allowsMultipleSelection = false
        NSApp.activate()
        return panel.runModal() == .OK ? panel.url : nil
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

    private static func alert(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        NSApp.activate()
        alert.runModal()
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
