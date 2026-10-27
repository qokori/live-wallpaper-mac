import AppKit
import WallpaperCore

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    /// Stable across reconnects and reboots, unlike the numeric display ID.
    var displayUUID: String? {
        guard let id = displayID, let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
}

struct ScreenStatus: Identifiable, Equatable {
    let id: String
    let name: String
    let video: URL?
    let playing: Bool
    let reasons: [PauseReason]
}

/// Keeps one wallpaper window per connected display in sync with the chosen videos and the pause conditions.
@MainActor
final class WallpaperController {
    /// Windows on screen, by display UUID.
    private var active: [String: ScreenWallpaper] = [:]
    /// Replacements still loading; they take over from `active` on their first frame.
    private var pending: [String: ScreenWallpaper] = [:]
    private var failed: [String: URL] = [:]

    var conditions = SystemConditions() {
        didSet { if conditions != oldValue { updatePlayback() } }
    }
    /// LW_IGNORE_OCCLUSION=1 keeps playing under other windows (for measurements only).
    private let ignoreOcclusion = ProcessInfo.processInfo.environment["LW_IGNORE_OCCLUSION"] == "1"

    var onChange: (() -> Void)?
    var onShown: ((String, URL) -> Void)?
    var onFailure: ((URL, Error) -> Void)?

    /// Creates, moves, swaps or closes windows so that every connected screen shows `videoFor(displayUUID)`.
    func reconcile(videoFor: (String) -> URL?) {
        var connected = Set<String>()
        for screen in NSScreen.screens {
            guard let id = screen.displayUUID else { continue }
            connected.insert(id)
            let url = videoFor(id)
            active[id]?.fit(to: screen.frame)
            if let loading = pending[id], loading.video == url {
                loading.fit(to: screen.frame)
                continue
            }
            pending.removeValue(forKey: id)?.close()
            if active[id]?.video == url, url != nil { continue }
            guard let url else {
                active.removeValue(forKey: id)?.close()
                continue
            }
            // A file that failed to load is retried only after the choice changes (see `forgetFailures`).
            if failed[id] == url { continue }
            let wallpaper = ScreenWallpaper(displayUUID: id, video: url, frame: screen.frame)
            wallpaper.onVisibilityChange = { [weak self] in self?.updatePlayback() }
            wallpaper.onReady = { [weak self, weak wallpaper] in
                guard let self, let wallpaper else { return }
                self.promote(wallpaper)
            }
            wallpaper.onFailure = { [weak self, weak wallpaper] error in
                guard let self, let wallpaper else { return }
                self.drop(wallpaper, error: error)
            }
            pending[id] = wallpaper
            Log.event("screen \(wallpaper.shortID) (\(screen.localizedName)): loading \(url.lastPathComponent)")
            wallpaper.start()
        }
        for id in Set(active.keys).union(pending.keys).subtracting(connected) {
            Log.event("screen \(id.prefix(8)): disconnected")
            pending.removeValue(forKey: id)?.close()
            active.removeValue(forKey: id)?.close()
        }
        updatePlayback()
    }

    func forgetFailures() {
        failed.removeAll()
    }

    func closeAll() {
        (Array(active.values) + Array(pending.values)).forEach { $0.close() }
        active.removeAll()
        pending.removeAll()
    }

    func updatePlayback() {
        for wallpaper in Array(active.values) + Array(pending.values) {
            wallpaper.apply(PausePolicy.reasons(conditions, screenVisible: ignoreOcclusion || wallpaper.isVisible))
        }
        onChange?()
    }

    var statuses: [ScreenStatus] {
        NSScreen.screens.compactMap { screen in
            guard let id = screen.displayUUID else { return nil }
            let wallpaper = active[id]
            return ScreenStatus(
                id: id, name: screen.localizedName, video: wallpaper?.video,
                playing: wallpaper?.isPlaying ?? false, reasons: wallpaper?.pauseReasons ?? []
            )
        }
    }

    private func promote(_ wallpaper: ScreenWallpaper) {
        let id = wallpaper.displayUUID
        guard pending[id] === wallpaper else { return }
        pending[id] = nil
        active.removeValue(forKey: id)?.close()
        active[id] = wallpaper
        updatePlayback()
        onShown?(id, wallpaper.video)
    }

    private func drop(_ wallpaper: ScreenWallpaper, error: Error) {
        let id = wallpaper.displayUUID
        if pending[id] === wallpaper { pending[id] = nil }
        if active[id] === wallpaper { active[id] = nil }
        wallpaper.close()
        failed[id] = wallpaper.video
        updatePlayback()
        onFailure?(wallpaper.video, error)
    }
}
