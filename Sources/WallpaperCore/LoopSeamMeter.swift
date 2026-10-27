/// Measures how smoothly media time continues across a loop boundary (used by the LW_DIAG=1 check).
///
/// Feed it (media time, wall-clock time) samples while the video plays at rate 1. When media time jumps back by
/// more than half the clip, a loop happened: the error is where the media time is minus where it should be had the
/// clip continued without a break. Negative = the picture held (a visible stall), positive = frames were skipped.
public struct LoopSeamMeter: Sendable {
    public let duration: Double
    public private(set) var loops = 0
    public private(set) var worstError = 0.0
    private var last: (media: Double, wall: Double)?

    public init(duration: Double) {
        self.duration = duration
    }

    /// Returns the seam error in seconds when this sample crossed a loop boundary, otherwise nil.
    public mutating func observe(media: Double, wall: Double) -> Double? {
        defer { last = (media, wall) }
        guard let last, duration > 0, media < last.media - duration / 2 else { return nil }
        let expected = last.media + (wall - last.wall) - duration
        let error = media - expected
        loops += 1
        worstError = max(worstError, abs(error))
        return error
    }

    /// Forget the previous sample (after a pause or seek the wall clock no longer matches media time).
    public mutating func reset() {
        last = nil
    }
}
