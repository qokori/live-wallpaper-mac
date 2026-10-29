/// How much a scene may spend: its frame rate and how large its canvas and pictures are. The sizes are worked out
/// by the scene page (`reducedSize` and `layout` in `SceneRendererPage`), which gets the level with its address. The settings offer three
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
}
