import AppKit
import Observation
import UniformTypeIdentifiers
import WallpaperCore

/// Settings, persisted in UserDefaults, and the glue between the menu, the system monitor and the windows.
@MainActor
@Observable
final class AppModel {
    private enum Key {
        static let assignments = "assignments"
        static let pauseOnBattery = "pauseOnBattery"
        static let syncSystemWallpaper = "syncSystemWallpaper"
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

    init() {
        let data = UserDefaults.standard.data(forKey: Key.assignments)
        assignments = data.flatMap { try? JSONDecoder().decode(WallpaperAssignments.self, from: $0) } ?? WallpaperAssignments()
        pauseOnBattery = UserDefaults.standard.bool(forKey: Key.pauseOnBattery)
        syncSystemWallpaper = UserDefaults.standard.object(forKey: Key.syncSystemWallpaper) as? Bool ?? true
        launchAtLogin = LaunchAtLogin.isEnabled
    }

    func start() {
        controller.onChange = { [weak self] in self?.refreshScreens() }
        controller.onShown = { [weak self] uuid, video in
            guard let self, self.syncSystemWallpaper else { return }
            Task {
                await SystemWallpaper.applyFirstFrame(of: video, toDisplay: uuid)
                self.canRestoreWallpaper = SystemWallpaper.hasOriginals
            }
        }
        controller.onFailure = { video, error in
            Self.alert("Не удалось воспроизвести «\(video.lastPathComponent)»", error.localizedDescription)
        }
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
        let withVideo = screens.filter { $0.video != nil }
        guard !withVideo.isEmpty else { return assignments.isEmpty ? "Видео не выбрано" : "Загрузка…" }
        let playing = withVideo.filter(\.playing).count
        if playing == withVideo.count {
            return withVideo.count == 1 ? "Играет" : "Играет на всех экранах (\(playing))"
        }
        if playing > 0 { return "Играет на \(playing) из \(withVideo.count) экранов" }
        let reason = withVideo.compactMap(\.reasons.first).min { $0.priority < $1.priority }
        return "Пауза: " + (reason?.title ?? "")
    }

    func chooseVideo(forDisplay uuid: String?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if let uuid, let screen = screens.first(where: { $0.id == uuid }) {
            panel.message = "Видео для экрана «\(screen.name)» (mp4, mov, HEVC)"
        } else {
            panel.message = perScreen ? "Видео для экранов без своего видео" : "Видео для всех экранов (mp4, mov, HEVC)"
        }
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setVideo(url, forDisplay: uuid)
    }

    /// Also used by `--video <path>` on the command line.
    func setVideo(_ url: URL, forDisplay uuid: String?) {
        Task {
            if let problem = await Self.problem(with: url) {
                Self.alert("Это видео не подойдёт", problem)
                return
            }
            let ref = VideoRef(path: url.path, bookmark: try? url.bookmarkData())
            if let uuid {
                assignments.perScreen[uuid] = ref
                assignments.mode = .perScreen
            } else {
                assignments.shared = ref
            }
        }
    }

    func useSharedVideo(forDisplay uuid: String) {
        assignments.perScreen[uuid] = nil
    }

    /// Clears every choice and puts the previous desktop pictures back; frame sync stays on for the next video.
    func removeVideos() {
        assignments = WallpaperAssignments(mode: assignments.mode)
        SystemWallpaper.restoreOriginals()
        canRestoreWallpaper = SystemWallpaper.hasOriginals
    }

    func restoreSystemWallpaper() {
        syncSystemWallpaper = false
        SystemWallpaper.restoreOriginals()
        canRestoreWallpaper = SystemWallpaper.hasOriginals
    }

    func ownVideo(forDisplay uuid: String) -> String? {
        assignments.perScreen[uuid]?.fileName
    }

    var sharedVideoName: String? { assignments.shared?.fileName }

    // MARK: Plumbing

    private func reconcile() {
        controller.reconcile { [assignments] uuid in assignments.video(forDisplay: uuid)?.resolvedURL }
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
            guard let video = screen.video else { continue }
            Task {
                await SystemWallpaper.applyFirstFrame(of: video, toDisplay: screen.id)
                canRestoreWallpaper = SystemWallpaper.hasOriginals
            }
        }
    }

    private static func problem(with url: URL) async -> String? {
        let asset = AVURLAsset(url: url)
        do {
            guard try await asset.load(.isPlayable) else { return "macOS не умеет воспроизводить этот файл." }
            guard try await !asset.loadTracks(withMediaType: .video).isEmpty else { return VideoError.noVideoTrack.localizedDescription }
        } catch {
            return error.localizedDescription
        }
        return nil
    }

    private static func alert(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        NSApp.activate()
        alert.runModal()
    }
}

import AVFoundation

extension VideoRef {
    /// The bookmark finds the file after a move or rename; the stored path is the fallback.
    var resolvedURL: URL {
        if let bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], bookmarkDataIsStale: &stale) {
                return url
            }
        }
        return URL(filePath: path)
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
