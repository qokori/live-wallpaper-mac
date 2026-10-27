import Foundation
import Testing
@testable import WallpaperCore

@Suite struct PausePolicyTests {
    @Test func playsWhenNothingStandsInTheWay() {
        #expect(PausePolicy.shouldPlay(SystemConditions(), screenVisible: true))
    }

    @Test func pausesWhenCovered() {
        #expect(PausePolicy.reasons(SystemConditions(), screenVisible: false) == [.occluded])
    }

    @Test func batteryPausesOnlyWithTheOption() {
        let onBattery = SystemConditions(onBattery: true)
        #expect(PausePolicy.shouldPlay(onBattery, screenVisible: true))
        var withOption = onBattery
        withOption.pauseOnBattery = true
        #expect(PausePolicy.reasons(withOption, screenVisible: true) == [.onBattery])
    }

    @Test func lowPowerLockAndSleepPause() {
        #expect(PausePolicy.reasons(SystemConditions(lowPowerMode: true), screenVisible: true) == [.lowPowerMode])
        #expect(PausePolicy.reasons(SystemConditions(screenLocked: true), screenVisible: true) == [.screenLocked])
        #expect(PausePolicy.reasons(SystemConditions(screensAsleep: true), screenVisible: true) == [.screensAsleep])
        #expect(PausePolicy.reasons(SystemConditions(sessionActive: false), screenVisible: true) == [.sessionInactive])
    }

    @Test func reasonsComeInPriorityOrder() {
        let all = SystemConditions(
            userPaused: true, systemSleeping: true, screensAsleep: true, screenLocked: true,
            sessionActive: false, lowPowerMode: true, onBattery: true, pauseOnBattery: true
        )
        #expect(PausePolicy.reasons(all, screenVisible: false) == PauseReason.allCases)
    }
}

@Suite struct AssignmentTests {
    let a = VideoRef(path: "/v/a.mov")
    let b = VideoRef(path: "/v/b.mp4")

    @Test func sameForAllIgnoresPerScreenChoices() {
        let assignments = WallpaperAssignments(mode: .sameForAll, shared: a, perScreen: ["X": b])
        #expect(assignments.video(forDisplay: "X") == a)
        #expect(assignments.video(forDisplay: "Y") == a)
    }

    @Test func perScreenFallsBackToShared() {
        let assignments = WallpaperAssignments(mode: .perScreen, shared: a, perScreen: ["X": b])
        #expect(assignments.video(forDisplay: "X") == b)
        #expect(assignments.video(forDisplay: "new-monitor") == a)
    }

    @Test func nothingChosenMeansNoVideo() {
        let assignments = WallpaperAssignments(mode: .perScreen, perScreen: ["X": b])
        #expect(assignments.video(forDisplay: "Y") == nil)
        #expect(WallpaperAssignments().isEmpty)
    }

    @Test func survivesEncoding() throws {
        let assignments = WallpaperAssignments(mode: .perScreen, shared: a, perScreen: ["X": VideoRef(path: "/v/c.mov", bookmark: Data([1, 2]))])
        let decoded = try JSONDecoder().decode(WallpaperAssignments.self, from: JSONEncoder().encode(assignments))
        #expect(decoded == assignments)
        #expect(b.fileName == "b.mp4")
    }
}

@Suite struct LoopSeamMeterTests {
    @Test func seamlessLoopHasNoError() throws {
        var meter = LoopSeamMeter(duration: 10)
        #expect(meter.observe(media: 9.98, wall: 100.00) == nil)
        let seam = meter.observe(media: 0.0, wall: 100.02)
        let error = try #require(seam)
        #expect(abs(error) < 0.000_1)
        #expect(meter.loops == 1)
    }

    @Test func heldFrameShowsAsNegativeError() throws {
        var meter = LoopSeamMeter(duration: 10)
        _ = meter.observe(media: 9.98, wall: 100.00)
        let seam = meter.observe(media: 0.0, wall: 100.22)
        let error = try #require(seam)
        #expect(abs(error + 0.2) < 0.000_1)
        #expect(abs(meter.worstError - 0.2) < 0.000_1)
    }

    @Test func resetSkipsTheGapAfterPause() {
        var meter = LoopSeamMeter(duration: 10)
        _ = meter.observe(media: 9.9, wall: 100)
        meter.reset()
        #expect(meter.observe(media: 0.1, wall: 500) == nil)
        #expect(meter.loops == 0)
    }
}
