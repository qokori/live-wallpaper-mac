import AppKit
import Combine
import Foundation
import Sparkle

/// Self-update through Sparkle 2 from the GitHub releases of this repository (feed and public key are in Info.plist). Runs only
/// inside an `.app`; under `swift run` there is no updater at all. «Обновлять автоматически» is Sparkle's
/// `automaticallyDownloadsUpdates` (on by default through `SUAutomaticallyUpdate`); when it is off Sparkle asks before it installs.
@MainActor
@Observable
final class UpdateModel {
    /// False outside an `.app`: nothing to replace, so no updater starts and the menu shows no update items.
    let isEnabled: Bool

    /// Whether a check can be started now (Sparkle is idle).
    private(set) var canCheck = false

    @ObservationIgnored private let controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observation: AnyCancellable?

    /// The default starts Sparkle only inside a bundle; tests pass `false` to be sure nothing starts.
    init(bundleURL: URL = Bundle.main.bundleURL, startUpdater: Bool = true) {
        isEnabled = startUpdater && bundleURL.pathExtension == "app"
        controller = isEnabled ? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil) : nil
        observation = controller?.updater.publisher(for: \.canCheckForUpdates).sink { [weak self] value in
            MainActor.assumeIsolated { self?.canCheck = value }
        }
    }

    /// Sparkle keeps the choice itself; reading it through here keeps the menu and the window in step.
    var autoUpdate: Bool {
        get {
            access(keyPath: \.autoUpdate)
            return controller?.updater.automaticallyDownloadsUpdates ?? false
        }
        set {
            withMutation(keyPath: \.autoUpdate) { controller?.updater.automaticallyDownloadsUpdates = newValue }
        }
    }

    func checkNow() {
        controller?.checkForUpdates(nil)
    }
}
