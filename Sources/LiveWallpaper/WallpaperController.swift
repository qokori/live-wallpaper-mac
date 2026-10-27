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
    let source: WallpaperSource?
    let playing: Bool
    let reasons: [PauseReason]
}

/// Keeps one wallpaper window per connected display in sync with the chosen sources and the pause conditions.
/// What to do on a change is decided by `ScreenReconciler` (tested); this class carries it out.
@MainActor
final class WallpaperController {
    /// Windows on screen, by display UUID.
    private var active: [String: ScreenWallpaper] = [:]
    /// Replacements still loading; they take over from `active` on their first frame.
    private var pending: [String: ScreenWallpaper] = [:]
    private var failed: [String: WallpaperSource] = [:]

    var conditions = SystemConditions() {
        didSet { if conditions != oldValue { updatePlayback() } }
    }
    /// LW_IGNORE_OCCLUSION=1 keeps playing under other windows (for measurements only).
    private let ignoreOcclusion = ProcessInfo.processInfo.environment["LW_IGNORE_OCCLUSION"] == "1"

    var makeContent: ((WallpaperSource, String) throws -> WallpaperContent)?
    var onChange: (() -> Void)?
    var onShown: ((String, WallpaperSource) -> Void)?
    var onFailure: ((WallpaperSource, Error) -> Void)?

    func reconcile(sourceFor: (String) -> WallpaperSource?) {
        var screens: [ScreenReconciler.Screen] = []
        var names: [String: String] = [:]
        for screen in NSScreen.screens {
            guard let id = screen.displayUUID else { continue }
            screens.append(.init(id: id, frame: screen.frame, desired: sourceFor(id)))
            names[id] = screen.localizedName
        }
        let known = Set(active.keys).union(pending.keys).union(failed.keys)
        let state = Dictionary(uniqueKeysWithValues: known.map {
            ($0, ScreenReconciler.State(active: active[$0]?.source, pending: pending[$0]?.source, failed: failed[$0]))
        })
        for action in ScreenReconciler.plan(screens: screens, state: state) {
            switch action {
            case .fit(let id, let frame):
                active[id]?.fit(to: frame)
                pending[id]?.fit(to: frame)
            case .load(let id, let source, let frame):
                load(source, on: id, name: names[id] ?? "", frame: frame)
            case .cancelPending(let id):
                pending.removeValue(forKey: id)?.close()
            case .closeActive(let id):
                active.removeValue(forKey: id)?.close()
            case .disconnect(let id):
                Log.event("screen \(id.prefix(8)): disconnected")
                pending.removeValue(forKey: id)?.close()
                active.removeValue(forKey: id)?.close()
            }
        }
        updatePlayback()
    }

    /// A failed source is retried only after the choice changes; a new choice clears the record.
    func forgetFailures() {
        failed.removeAll()
    }

    func closeAll() {
        (Array(active.values) + Array(pending.values)).forEach { $0.close() }
        active.removeAll()
        pending.removeAll()
    }

    func updatePlayback() {
        let plan = PausePolicy.plan(conditions, visible: active.mapValues(\.isVisible), ignoreOcclusion: ignoreOcclusion)
        for (id, wallpaper) in active { wallpaper.apply(plan[id] ?? []) }
        for wallpaper in pending.values {
            wallpaper.apply(PausePolicy.reasons(conditions, screenVisible: ignoreOcclusion || wallpaper.isVisible))
        }
        onChange?()
    }

    func setWebFrameRate(_ frameRate: Int) {
        for wallpaper in Array(active.values) + Array(pending.values) {
            (wallpaper.content as? WebContent)?.setFrameRate(frameRate)
        }
    }

    /// Web pages on screen with their window rectangles, for pointer forwarding.
    var webTargets: [(bounds: CGRect, content: WebContent)] {
        active.values.compactMap { wallpaper in
            (wallpaper.content as? WebContent).map { (wallpaper.boundsInCG, $0) }
        }
    }

    var statuses: [ScreenStatus] {
        NSScreen.screens.compactMap { screen in
            guard let id = screen.displayUUID else { return nil }
            let wallpaper = active[id]
            return ScreenStatus(
                id: id, name: screen.localizedName, source: wallpaper?.source,
                playing: wallpaper?.isPlaying ?? false, reasons: wallpaper?.pauseReasons ?? []
            )
        }
    }

    private func load(_ source: WallpaperSource, on id: String, name: String, frame: NSRect) {
        failed[id] = nil
        let content: WallpaperContent
        do {
            guard let makeContent else { return }
            content = try makeContent(source, "screen \(id.prefix(8))")
        } catch {
            failed[id] = source
            Log.event("screen \(id.prefix(8)): cannot open \(source.title): \(error.localizedDescription)")
            onFailure?(source, error)
            return
        }
        let wallpaper = ScreenWallpaper(displayUUID: id, source: source, content: content, frame: frame)
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
        Log.event("screen \(wallpaper.shortID) (\(name)): loading \(source.title)")
        wallpaper.start()
    }

    private func promote(_ wallpaper: ScreenWallpaper) {
        let id = wallpaper.displayUUID
        guard pending[id] === wallpaper else { return }
        pending[id] = nil
        active.removeValue(forKey: id)?.close()
        active[id] = wallpaper
        updatePlayback()
        onShown?(id, wallpaper.source)
    }

    private func drop(_ wallpaper: ScreenWallpaper, error: Error) {
        let id = wallpaper.displayUUID
        if pending[id] === wallpaper { pending[id] = nil }
        if active[id] === wallpaper { active[id] = nil }
        wallpaper.close()
        failed[id] = wallpaper.source
        updatePlayback()
        onFailure?(wallpaper.source, error)
    }
}
