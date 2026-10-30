import Foundation
import Testing
@testable import LiveWallpaper

/// Sparkle must never start outside an `.app`: under `swift run` and in tests there is no feed, no key and nothing to replace.
@MainActor
@Suite struct UpdateModelTests {
    @Test func isOffOutsideAnApp() {
        let model = UpdateModel(bundleURL: URL(filePath: "/tmp/.build/debug/LiveWallpaper"))
        #expect(!model.isEnabled)
        #expect(!model.canCheck)
        #expect(!model.autoUpdate)
        model.checkNow()
        model.autoUpdate = true
        #expect(!model.autoUpdate, "nothing to switch without an updater")
    }

    @Test func theAppModelOfTheTestsHasNoUpdater() {
        #expect(!AppModel().updates.isEnabled, "the test runner is not an .app")
    }

    @Test func staysOffEvenInsideAnAppWhenTheCallerSaysSo() {
        #expect(!UpdateModel(bundleURL: URL(filePath: "/tmp/x/LiveWallpaper.app"), startUpdater: false).isEnabled)
    }
}
