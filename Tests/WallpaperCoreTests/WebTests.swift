import CoreGraphics
import Foundation
import Testing
@testable import WallpaperCore

@Suite struct WebAddressTests {
    @Test func addsHttpsWhenSchemeIsMissing() {
        #expect(WebAddress.normalize("  example.com/waves ")?.absoluteString == "https://example.com/waves")
        #expect(WebAddress.normalize("http://localhost:8000")?.absoluteString == "http://localhost:8000")
    }

    @Test func rejectsWhatIsNotAWebAddress() {
        #expect(WebAddress.normalize("") == nil)
        #expect(WebAddress.normalize("two words") == nil)
        #expect(WebAddress.normalize("file:///etc/hosts") == nil)
        #expect(WebAddress.normalize("javascript:alert(1)") == nil)
    }

    @Test func remoteMeansHttpOrHttps() {
        #expect(WebAddress.isRemote("HTTPS://example.com"))
        #expect(!WebAddress.isRemote("/pages/waves"))
        #expect(WallpaperSource(kind: .web, location: "https://example.com/x").title == "example.com")
        #expect(WallpaperSource(kind: .web, location: "/pages/waves").title == "waves")
        #expect(!WallpaperSource(kind: .video, location: "https://example.com/a.mp4").isRemote)
    }
}

@Suite struct LocalPageTests {
    @Test func folderLoadsItsIndex() {
        let page = LocalPage.resolve(path: "/pages/waves/", isDirectory: true)
        #expect(page == LocalPage(entry: "/pages/waves/index.html", readAccess: "/pages/waves"))
    }

    @Test func htmlFileReadsItsFolder() {
        let page = LocalPage.resolve(path: "/pages/waves/demo.html", isDirectory: false)
        #expect(page == LocalPage(entry: "/pages/waves/demo.html", readAccess: "/pages/waves"))
    }

    @Test func navigationStaysInTheFolder() {
        let page = LocalPage.resolve(path: "/pages/waves", isDirectory: true)
        #expect(page.allows(path: "/pages/waves/other.html"))
        #expect(!page.allows(path: "/pages/waves-evil/index.html"))
        #expect(!page.allows(path: "/etc/hosts"))
    }
}

@Suite struct DesktopPointerTests {
    let screen = CGRect(x: 0, y: 0, width: 1470, height: 956)
    let iconsAndWidgets = DesktopPointer.Window(layer: -2_147_483_603, bounds: CGRect(x: 0, y: 0, width: 1470, height: 956))
    let browser = DesktopPointer.Window(layer: 0, bounds: CGRect(x: 100, y: 100, width: 600, height: 400))
    let menuBar = DesktopPointer.Window(layer: 24, bounds: CGRect(x: 0, y: 0, width: 1470, height: 33))

    @Test func iconLayerDoesNotBlockThePage() {
        #expect(DesktopPointer.isOnDesktop(CGPoint(x: 1000, y: 700), windows: [iconsAndWidgets, browser, menuBar]))
    }

    @Test func appWindowsAndMenuBarBlockThePage() {
        #expect(!DesktopPointer.isOnDesktop(CGPoint(x: 300, y: 300), windows: [iconsAndWidgets, browser, menuBar]))
        #expect(!DesktopPointer.isOnDesktop(CGPoint(x: 1000, y: 10), windows: [iconsAndWidgets, browser, menuBar]))
    }

    @Test func pagePointIsRelativeToTheScreen() {
        let second = CGRect(x: 1470, y: -200, width: 1920, height: 1080)
        #expect(DesktopPointer.pagePoint(CGPoint(x: 1500, y: -100), windowBounds: second) == CGPoint(x: 30, y: 100))
        #expect(DesktopPointer.pagePoint(CGPoint(x: 10, y: 10), windowBounds: second) == nil)
    }

    @Test func appKitCoordinatesFlipAroundTheMainScreen() {
        #expect(DesktopPointer.cgPoint(fromAppKit: CGPoint(x: 5, y: 956), mainScreenHeight: 956) == CGPoint(x: 5, y: 0))
        let appKitSecond = CGRect(x: 1470, y: 76, width: 1920, height: 1080)
        #expect(DesktopPointer.cgRect(fromAppKit: appKitSecond, mainScreenHeight: 956) == CGRect(x: 1470, y: -200, width: 1920, height: 1080))
    }
}

@Suite struct ScreenPlanTests {
    @Test func fullscreenOnOneScreenPausesOnlyThatScreen() {
        let plan = PausePolicy.plan(SystemConditions(), visible: ["built-in": false, "external": true])
        #expect(plan["built-in"] == [.occluded])
        #expect(plan["external"] == [])
    }

    @Test func lockPausesEveryScreen() {
        let plan = PausePolicy.plan(SystemConditions(screenLocked: true), visible: ["a": true, "b": true])
        #expect(plan.values.allSatisfy { $0 == [.screenLocked] })
    }

    @Test func measurementModeIgnoresCoverButNotLock() {
        let covered = PausePolicy.plan(SystemConditions(), visible: ["a": false], ignoreOcclusion: true)
        #expect(covered["a"] == [])
        let locked = PausePolicy.plan(SystemConditions(screenLocked: true), visible: ["a": false], ignoreOcclusion: true)
        #expect(locked["a"] == [.screenLocked])
    }
}
