import AppKit
import AVFoundation
import Foundation
import Testing
@testable import WallpaperCore

@Suite struct ScalingTests {
    let video = WallpaperSource(kind: .video, location: "/v/a.mov")
    let page = WallpaperSource(kind: .web, location: "/pages/waves")

    @Test func fillIsTheDefault() {
        let choices = ScalingChoices()
        #expect(choices.scaling(forDisplay: "X", mode: .sameForAll) == .fill)
        #expect(choices.scaling(forDisplay: "X", mode: .perScreen) == .fill)
    }

    @Test func sameForAllIgnoresPerScreenChoices() {
        let choices = ScalingChoices(shared: .fit, perScreen: ["X": .stretch])
        #expect(choices.scaling(forDisplay: "X", mode: .sameForAll) == .fit)
    }

    @Test func perScreenFallsBackToShared() {
        let choices = ScalingChoices(shared: .fit, perScreen: ["X": .stretch])
        #expect(choices.scaling(forDisplay: "X", mode: .perScreen) == .stretch)
        #expect(choices.scaling(forDisplay: "new-monitor", mode: .perScreen) == .fit)
    }

    @Test func survivesEncoding() throws {
        let choices = ScalingChoices(shared: .stretch, perScreen: ["X": .fit])
        let decoded = try JSONDecoder().decode(ScalingChoices.self, from: JSONEncoder().encode(choices))
        #expect(decoded == choices)
    }

    @Test func videoGravityMatchesAVFoundation() {
        #expect(AVLayerVideoGravity(rawValue: WallpaperScaling.fill.videoGravity) == .resizeAspectFill)
        #expect(AVLayerVideoGravity(rawValue: WallpaperScaling.fit.videoGravity) == .resizeAspect)
        #expect(AVLayerVideoGravity(rawValue: WallpaperScaling.stretch.videoGravity) == .resize)
    }

    @Test func desktopPictureOptionsMatchAppKit() {
        let proportional = Int(NSImageScaling.scaleProportionallyUpOrDown.rawValue)
        #expect(WallpaperScaling.fill.desktopImageScaling == proportional && WallpaperScaling.fill.desktopImageAllowsClipping)
        #expect(WallpaperScaling.fit.desktopImageScaling == proportional && !WallpaperScaling.fit.desktopImageAllowsClipping)
        #expect(WallpaperScaling.stretch.desktopImageScaling == Int(NSImageScaling.scaleAxesIndependently.rawValue))
    }

    @Test func greyedOutForWebPages() {
        let assignments = WallpaperAssignments(mode: .perScreen, shared: page, perScreen: ["X": video])
        #expect(!assignments.scalingApplies(forDisplay: nil))
        #expect(assignments.scalingApplies(forDisplay: "X"))
        #expect(!assignments.scalingApplies(forDisplay: "new-monitor"))
    }

    @Test func availableBeforeAnythingIsChosen() {
        #expect(WallpaperAssignments().scalingApplies(forDisplay: nil))
        #expect(WallpaperAssignments(mode: .perScreen, perScreen: ["X": page]).scalingApplies(forDisplay: "Y"))
    }
}
