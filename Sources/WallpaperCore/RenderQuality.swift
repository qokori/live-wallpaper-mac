/// How much a scene may spend: its frame rate and how large its canvas and pictures are. The settings offer three
/// levels; `maximum` is how scenes were drawn before the setting existed. Video layers are not reduced at any level:
/// measured, shrinking them in the page costs more processor time than it saves.
public enum RenderQuality: String, CaseIterable, Sendable {
    /// One canvas pixel per point (half the pixels on a Retina screen), pictures at half size and no larger than the canvas.
    case economy
    /// A canvas pixel per screen pixel, pictures no larger than the canvas.
    case screen
    /// Everything at its own size.
    case maximum

    public static let standard = RenderQuality.screen

    /// Frame rates the settings offer for scenes and web pages.
    public static let frameRates = [15, 30, 60]
    public static let standardFrameRate = 30

    /// A stored or typed frame rate, or the standard one when it is not on offer.
    public static func frameRate(_ value: Int) -> Int {
        frameRates.contains(value) ? value : standardFrameRate
    }

    public init(stored: String?) {
        self = stored.flatMap(RenderQuality.init(rawValue:)) ?? .standard
    }

    /// Canvas pixels per point, at most; `devicePixelRatio` is the screen's own.
    public func canvasRatio(devicePixelRatio: Double) -> Double {
        switch self {
        case .economy: 1
        case .screen, .maximum: min(devicePixelRatio, 2)
        }
    }

    /// Pictures of this many pixels or fewer on a side, and any picture on a canvas smaller than `floor`, are not reduced.
    public static let smallestPicture = 64.0
    public static let canvasFloor = 512.0

    /// The factor a picture's sides are multiplied by before it goes to the graphics card (1 keeps it). The page
    /// does the same sum (`reducedSize` in `SceneRendererPage`).
    public func pictureScale(side: Double, canvasSide: Double) -> Double {
        guard self != .maximum, side > Self.smallestPicture else { return 1 }
        let limit = max(Self.canvasFloor, canvasSide)
        return min(self == .economy ? 0.5 : 1, limit / side)
    }
}
