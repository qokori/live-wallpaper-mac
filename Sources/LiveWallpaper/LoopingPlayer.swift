import AVFoundation

enum VideoError: LocalizedError {
    case noVideoTrack

    var errorDescription: String? { "В файле нет видеодорожки" }
}

/// One muted, endlessly looping video. AVPlayerLooper keeps the next copy of the item queued, so there is no gap.
@MainActor
final class LoopingPlayer {
    let player = AVQueuePlayer()
    private(set) var looper: AVPlayerLooper?
    private(set) var duration: Double = 0

    init() {
        player.isMuted = true
        // The wallpaper must never keep the display awake.
        player.preventsDisplaySleepDuringVideoPlayback = false
    }

    /// Loops the video track only. An audio track that runs longer than the picture (encoder priming, AAC padding)
    /// would otherwise hold the last frame at every loop point; dropping it also skips audio decoding.
    func load(_ url: URL) async throws {
        let asset = AVURLAsset(url: url)
        guard let source = try await asset.loadTracks(withMediaType: .video).first else { throw VideoError.noVideoTrack }
        let (timeRange, transform) = try await source.load(.timeRange, .preferredTransform)
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw VideoError.noVideoTrack }
        try track.insertTimeRange(timeRange, of: source, at: .zero)
        track.preferredTransform = transform
        duration = timeRange.duration.seconds
        looper = AVPlayerLooper(
            player: player,
            templateItem: AVPlayerItem(asset: composition),
            timeRange: CMTimeRange(start: .zero, duration: timeRange.duration)
        )
    }

    func setPlaying(_ playing: Bool) {
        if playing {
            if player.rate == 0 { player.play() }
        } else if player.rate != 0 {
            player.pause()
        }
    }

    func stop() {
        looper?.disableLooping()
        player.pause()
        player.removeAllItems()
        looper = nil
    }
}
