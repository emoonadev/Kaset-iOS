import MediaPlayer

/// Publishes the mirrored `PlaybackState` to `MPNowPlayingInfoCenter`.
///
/// `MPNowPlayingInfoCenter.playbackState` is ignored on iOS without an entitlement, so the
/// info dictionary (rate + elapsed time) is the only signal that matters.
@MainActor
final class NowPlayingPublisher {
    private var artworkURL: URL?
    private var artwork: MPMediaItemArtwork?
    private var artworkTask: Task<Void, Never>?

    func update(from state: PlaybackState) {
        guard state.hasMedia, state.title != nil else {
            self.clear()
            return
        }
        if state.artworkURL != self.artworkURL {
            self.artworkURL = state.artworkURL
            self.artwork = nil
            self.loadArtwork(state.artworkURL)
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: state.title ?? "",
            MPMediaItemPropertyArtist: state.artist ?? "",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: state.isChangingTrack ? 0 : state.position,
            MPNowPlayingInfoPropertyPlaybackRate: state.isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
        ]
        if let album = state.album { info[MPMediaItemPropertyAlbumTitle] = album }
        if state.duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = state.duration }
        if let artwork = self.artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        #if os(macOS)
        // macOS reads the explicit state for the menu bar / Control Center Now Playing widget.
        MPNowPlayingInfoCenter.default().playbackState = state.isPlaying ? .playing : .paused
        #endif
    }

    func clear() {
        self.artworkTask?.cancel()
        self.artworkURL = nil
        self.artwork = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        #if os(macOS)
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        #endif
    }

    /// Must be `nonisolated`: MediaPlayer calls the image handler on its own queue, and a closure
    /// created in this `@MainActor` class would inherit main-actor isolation and trap there.
    nonisolated private static func makeArtwork(_ image: PlatformImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    private func loadArtwork(_ url: URL?) {
        self.artworkTask?.cancel()
        guard let url else { return }
        self.artworkTask = Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  !Task.isCancelled,
                  let image = PlatformImage(data: data)
            else { return }
            let artwork = Self.makeArtwork(image)
            guard let self, self.artworkURL == url else { return }
            self.artwork = artwork
            var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            info[MPMediaItemPropertyArtwork] = artwork
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
    }
}
