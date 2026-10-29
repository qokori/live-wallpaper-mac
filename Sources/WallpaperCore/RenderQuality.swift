/// How much a scene may spend: its frame rate and how large its pictures and video are drawn. The settings offer
/// three levels; `maximum` is how scenes were drawn before the setting existed.
public enum RenderQuality: String, CaseIterable, Sendable {
    /// One canvas pixel per point (half the pixels on a Retina screen), pictures at half size, video no larger than the canvas.
    case economy
    /// A canvas pixel per screen pixel, pictures as they are, video no larger than the canvas.
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

    /// Scale a picture is reduced to before it goes to the graphics card (1 keeps it).
    public var pictureScale: Double { self == .economy ? 0.5 : 1 }

    /// Whether video larger than the canvas is reduced to the canvas size.
    public var shrinksVideo: Bool { self != .maximum }
}
