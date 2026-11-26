import Foundation

// MARK: - Podcasts

extension YTMusicClient {
    /// Discovery page (`FEmusic_podcasts`). Answers HTTP 404 in regions without podcasts.
    func getPodcasts(forceRefresh: Bool = false) async throws -> PodcastParser.DiscoveryPage {
        let data = try await self.request(
            "browse", body: ["browseId": Self.podcastsBrowseId], ttl: APICache.TTL.home, bypassCache: forceRefresh
        )
        return PodcastParser.parseDiscovery(data)
    }

    func getPodcastsContinuation(token: String) async throws -> PodcastParser.DiscoveryPage {
        let data = try await self.request("browse", body: ["continuation": token], ttl: APICache.TTL.home)
        return PodcastParser.parseDiscoveryContinuation(data)
    }

    /// A show's page: header and first episodes, newest first.
    func getPodcastShow(browseId: String) async throws -> PodcastShowDetail {
        let data = try await self.request("browse", body: ["browseId": browseId], ttl: APICache.TTL.playlist)
        return PodcastParser.parseShowDetail(data, showId: browseId)
    }

    func getPodcastEpisodesContinuation(token: String) async throws -> PodcastEpisodesContinuation {
        let data = try await self.request("browse", body: ["continuation": token], ttl: APICache.TTL.playlist)
        return PodcastParser.parseEpisodesContinuation(data)
    }

    /// "Save to library" on a show page: the show's playlist is added to (or removed from) the library.
    func setPodcastSaved(_ saved: Bool, showId: String) async throws {
        guard let playlistId = PodcastParser.playlistId(forShow: showId) else { return }
        if saved {
            try await self.addPlaylistToLibrary(id: playlistId)
        } else {
            try await self.removePlaylistFromLibrary(id: playlistId)
        }
    }

    nonisolated static let podcastsBrowseId = "FEmusic_podcasts"
    /// The library's podcasts list (saved shows).
    nonisolated static let libraryPodcastsBrowseId = "FEmusic_library_non_music_audio_list"
}
