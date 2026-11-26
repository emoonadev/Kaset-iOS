import Foundation

// MARK: - Podcasts

extension YTMusicClient {
    /// Where Explore's "Podcasts" shortcut points, if it has one. Shares Explore's cached response.
    func podcastsEndpoint(forceRefresh: Bool = false) async throws -> PodcastParser.Endpoint? {
        let data = try await self.request(
            "browse", body: ["browseId": PaginatedContentType.explore.rawValue],
            ttl: APICache.TTL.home, bypassCache: forceRefresh
        )
        return PodcastParser.discoveryEndpoint(inExplore: data)
    }

    /// The Podcasts discovery page. Each known id is tried in turn (Explore's shortcut first):
    /// YouTube Music moved the page once already. Throws the 404 when none exists, which is
    /// what happens where podcasts are not offered.
    func getPodcasts(forceRefresh: Bool = false) async throws -> PodcastParser.DiscoveryPage {
        let shortcut = try? await self.podcastsEndpoint()
        var lastNotFound: Error?
        for target in PodcastParser.discoveryCandidates(shortcut: shortcut) {
            var body: [String: Any] = ["browseId": target.browseId]
            if let params = target.params { body["params"] = params }
            do {
                let data = try await self.request("browse", body: body, ttl: APICache.TTL.home, bypassCache: forceRefresh)
                return PodcastParser.parseDiscovery(data)
            } catch let error as YTMusicError {
                guard case let .apiError(_, code) = error, code == 404 else { throw error }
                lastNotFound = error
            }
        }
        throw lastNotFound ?? YTMusicError.apiError(message: "HTTP 404", code: 404)
    }

    func getPodcastsContinuation(token: String) async throws -> PodcastParser.DiscoveryPage {
        let data = try await self.request("browse", body: ["continuation": token], ttl: APICache.TTL.home)
        return PodcastParser.parseDiscoveryContinuation(data)
    }

    /// The podcast shelves of Home or Explore (only shows and episodes, empty shelves dropped).
    /// Shares the page's cached response.
    func podcastShelves(of type: PaginatedContentType, forceRefresh: Bool = false) async throws -> [PodcastSection] {
        let data = try await self.request(
            "browse", body: ["browseId": type.rawValue], ttl: APICache.TTL.home, bypassCache: forceRefresh
        )
        return PodcastParser.parsePodcastShelves(data)
    }

    /// Shows saved to the library: the dedicated list, else the library landing preview.
    func getSavedPodcasts(forceRefresh: Bool = false) async throws -> [PodcastShow] {
        let dedicated = try? await self.request(
            "browse", body: ["browseId": Self.libraryPodcastsBrowseId], ttl: APICache.TTL.library,
            bypassCache: forceRefresh
        )
        let landing = try await self.request(
            "browse", body: ["browseId": "FEmusic_library_landing"], ttl: APICache.TTL.library,
            bypassCache: forceRefresh
        )
        return Self.mergedPodcastShows(
            dedicated.map { PlaylistParser.parseLibraryContent($0).podcastShows } ?? [],
            PlaylistParser.parseLibraryContent(landing).podcastShows
        )
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

    /// The library's podcasts list (saved shows).
    nonisolated static let libraryPodcastsBrowseId = "FEmusic_library_non_music_audio_list"
}
