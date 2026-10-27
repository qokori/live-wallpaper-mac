import CoreGraphics
import Foundation
import JavaScriptCore
import Testing
@testable import WallpaperCore

@Suite struct ScreenReconcilerTests {
    let clip = WallpaperSource(kind: .video, location: "/v/clip.mov")
    let page = WallpaperSource(kind: .web, location: "/pages/waves")
    let builtIn = CGRect(x: 0, y: 0, width: 1470, height: 956)
    let external = CGRect(x: 1470, y: 0, width: 1920, height: 1080)

    @Test func pluggedInMonitorGetsItsSource() {
        let actions = ScreenReconciler.plan(
            screens: [.init(id: "A", frame: builtIn, desired: clip), .init(id: "B", frame: external, desired: clip)],
            state: ["A": .init(active: clip)]
        )
        #expect(actions == [.fit("A", builtIn), .load("B", clip, external)])
    }

    @Test func unpluggedMonitorIsClosed() {
        let actions = ScreenReconciler.plan(
            screens: [.init(id: "A", frame: builtIn, desired: clip)],
            state: ["A": .init(active: clip), "B": .init(active: clip)]
        )
        #expect(actions == [.fit("A", builtIn), .disconnect("B")])
    }

    @Test func resolutionChangeOnlyRefitsTheWindow() {
        let smaller = CGRect(x: 1470, y: 0, width: 1280, height: 720)
        let actions = ScreenReconciler.plan(screens: [.init(id: "B", frame: smaller, desired: clip)], state: ["B": .init(active: clip)])
        #expect(actions == [.fit("B", smaller)])
    }

    @Test func newChoiceLoadsBesideTheOldWindow() {
        let actions = ScreenReconciler.plan(screens: [.init(id: "A", frame: builtIn, desired: page)], state: ["A": .init(active: clip)])
        #expect(actions == [.fit("A", builtIn), .load("A", page, builtIn)])
    }

    @Test func switchingBackWhileLoadingCancelsTheReplacement() {
        let actions = ScreenReconciler.plan(screens: [.init(id: "A", frame: builtIn, desired: clip)], state: ["A": .init(active: clip, pending: page)])
        #expect(actions == [.fit("A", builtIn), .cancelPending("A")])
    }

    @Test func removedChoiceClosesTheWindow() {
        let actions = ScreenReconciler.plan(screens: [.init(id: "A", frame: builtIn, desired: nil)], state: ["A": .init(active: clip)])
        #expect(actions == [.fit("A", builtIn), .closeActive("A")])
    }

    @Test func failedSourceIsNotRetriedInALoop() {
        let actions = ScreenReconciler.plan(screens: [.init(id: "A", frame: builtIn, desired: page)], state: ["A": .init(failed: page)])
        #expect(actions.isEmpty)
    }
}

@Suite struct DesktopPictureMemoryTests {
    typealias Picture = DesktopPictureMemory.Picture
    let frames = "/Library/Application Support/LiveWallpaper/Frames"
    let original = Picture(path: "/Pictures/sea.jpg", scaling: 3, clipping: true)

    @Test func frameNameFollowsTheVideoFile() {
        let name = DesktopPictureMemory.frameFileName(path: "/v/clip.mov", modified: 100, size: 5)
        #expect(name.count == 20 && name.hasSuffix(".jpg"))
        #expect(name == DesktopPictureMemory.frameFileName(path: "/v/clip.mov", modified: 100, size: 5))
        #expect(name != DesktopPictureMemory.frameFileName(path: "/v/clip.mov", modified: 101, size: 5))
    }

    @Test func remembersTheFirstOriginalOnly() {
        let first = DesktopPictureMemory.remember(original, display: "A", in: [:], framesDirectory: frames)
        let again = DesktopPictureMemory.remember(Picture(path: "/Pictures/other.jpg", scaling: 1, clipping: false), display: "A", in: first, framesDirectory: frames)
        #expect(again == ["A": original])
    }

    @Test func neverRemembersOurOwnFrame() {
        let ours = Picture(path: frames + "/0123456789abcdef.jpg", scaling: 3, clipping: true)
        #expect(DesktopPictureMemory.remember(ours, display: "A", in: [:], framesDirectory: frames).isEmpty)
    }

    @Test func restoresOnlyConnectedDisplays() {
        let saved = ["A": original, "B": Picture(path: "/Pictures/b.png", scaling: 3, clipping: true)]
        let plan = DesktopPictureMemory.restorePlan(saved: saved, connected: ["A", "C"])
        #expect(plan.map(\.display) == ["A"])
        #expect(plan.first?.picture == original)
    }
}

/// Runs the injected script in JavaScriptCore with a fake 60 Hz display, no WebKit or screen needed.
@Suite struct WebPageScriptTests {
    let harness = """
    var window = this;
    var pending = [];
    var now = 0;
    var dispatched = [];
    window.requestAnimationFrame = function (callback) { pending.push(callback); return pending.length; };
    window.cancelAnimationFrame = function () {};
    function setTimeout() {}
    function PointerEvent(type, init) { this.type = type; this.init = init; }
    function MouseEvent(type, init) { this.type = type; this.init = init; }
    var root = { dispatchEvent: function (event) { dispatched.push(event.type + '@' + event.init.clientX + ',' + event.init.clientY); } };
    var document = {
      getAnimations: function () { return []; },
      querySelectorAll: function () { return []; },
      elementFromPoint: function () { return null; },
      documentElement: root,
    };
    function vsync(count) {
      for (var i = 0; i < count; i++) {
        now += 1000 / 60;
        var due = pending; pending = [];
        due.forEach(function (callback) { callback(now); });
      }
    }
    """
    let page = "var drawn = 0; function draw() { drawn++; requestAnimationFrame(draw); } requestAnimationFrame(draw);"

    func context(frameRate: Int, paused: Bool) throws -> JSContext {
        let context = try #require(JSContext())
        context.exceptionHandler = { _, error in Issue.record("JS error: \(error?.toString() ?? "?")") }
        context.evaluateScript(harness)
        context.evaluateScript(WebPageScript.source(frameRate: frameRate, paused: paused))
        context.evaluateScript(page)
        return context
    }

    func drawn(_ context: JSContext) -> Int32 { context.evaluateScript("drawn").toInt32() }

    @Test func capsTheFrameRate() throws {
        let thirty = try context(frameRate: 30, paused: false)
        thirty.evaluateScript("vsync(120)")
        #expect((59...61).contains(drawn(thirty)))
        let sixty = try context(frameRate: 60, paused: false)
        sixty.evaluateScript("vsync(120)")
        #expect((119...121).contains(drawn(sixty)))
    }

    @Test func pauseStopsAnimationFramesAndResumeRestartsThem() throws {
        let js = try context(frameRate: 60, paused: true)
        js.evaluateScript("vsync(60)")
        #expect(drawn(js) == 0)
        js.evaluateScript(WebPageScript.setPaused(false))
        js.evaluateScript("vsync(60)")
        #expect(drawn(js) >= 59)
        js.evaluateScript(WebPageScript.setPaused(true))
        let before = drawn(js)
        js.evaluateScript("vsync(60)")
        #expect(drawn(js) == before)
    }

    @Test func frameRateChangesLive() throws {
        let js = try context(frameRate: 60, paused: false)
        js.evaluateScript(WebPageScript.setFrameRate(30))
        js.evaluateScript("vsync(120)")
        #expect((59...62).contains(drawn(js)))
    }

    @Test func pointerEventsReachThePage() throws {
        let js = try context(frameRate: 30, paused: false)
        js.evaluateScript(WebPageScript.pointer(.down, x: 10, y: 20))
        js.evaluateScript(WebPageScript.pointer(.up, x: 10, y: 20))
        let events = js.evaluateScript("dispatched.join(' ')").toString() ?? ""
        #expect(events == "pointerdown@10,20 mousedown@10,20 pointerup@10,20 mouseup@10,20 click@10,20")
    }
}
