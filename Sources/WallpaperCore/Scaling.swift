import Foundation

/// How a video fills its screen. A web page lays itself out in the window and ignores it.
public enum WallpaperScaling: String, Codable, CaseIterable, Sendable {
    /// Keeps proportions and covers the whole screen; what does not fit is cropped. The default.
    case fill
    /// Keeps proportions and shows the whole picture; black bars fill the rest.
    case fit
    /// Covers the screen exactly; proportions are not kept.
    case stretch

    /// `AVLayerVideoGravity` raw value for the video layer.
    public var videoGravity: String {
        switch self {
        case .fill: "AVLayerVideoGravityResizeAspectFill"
        case .fit: "AVLayerVideoGravityResizeAspect"
        case .stretch: "AVLayerVideoGravityResize"
        }
    }

    /// `NSImageScaling` raw value for the desktop picture: proportional for fill and fit, both axes on their own for stretch.
    public var desktopImageScaling: Int {
        switch self {
        case .fill, .fit: 3 // scaleProportionallyUpOrDown
        case .stretch: 1 // scaleAxesIndependently
        }
    }

    /// `allowClipping` for the desktop picture: only fill crops; fit leaves bars, a stretched picture has nothing to crop.
    public var desktopImageAllowsClipping: Bool { self == .fill }
}

/// Scaling per display, shaped like `WallpaperAssignments`: one choice for all screens, and in per-screen mode a
/// screen's own choice. Kept apart from the sources, so «Убрать обои» and a new video keep it.
public struct ScalingChoices: Codable, Equatable, Sendable {
    /// For all screens; in per-screen mode, the fallback for screens without their own.
    public var shared: WallpaperScaling
    public var perScreen: [String: WallpaperScaling]

    public init(shared: WallpaperScaling = .fill, perScreen: [String: WallpaperScaling] = [:]) {
        self.shared = shared
        self.perScreen = perScreen
    }

    public func scaling(forDisplay uuid: String, mode: AssignmentMode) -> WallpaperScaling {
        switch mode {
        case .sameForAll: shared
        case .perScreen: perScreen[uuid] ?? shared
        }
    }
}

extension WallpaperAssignments {
    /// Whether the scaling choice for a display (nil: the shared one) does anything. Not for a web page, which lays
    /// itself out in the window; with nothing chosen yet it does: the choice waits for a video.
    public func scalingApplies(forDisplay uuid: String?) -> Bool {
        let source = uuid.map { source(forDisplay: $0) } ?? shared
        return source?.kind != .web
    }
}
