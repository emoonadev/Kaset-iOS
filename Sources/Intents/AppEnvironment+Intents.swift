import Foundation

/// What the intents ask of the app. They can run right after a launch the user did not see,
/// so each one first puts the saved session back.
extension AppEnvironment {
    /// Playlists that can be started from outside the app, Liked Music first.
    func intentPlaylists() async throws -> [PlaylistEntity] {
        await self.restoreSession()
        guard self.auth.state == .signedIn else { return [] }
        let library = try await self.client.getLibraryContent().playlists
        return Self.playableIntentPlaylists(library).map {
            PlaylistEntity(
                id: $0.id, title: $0.title, subtitle: $0.author?.name, thumbnailURL: $0.thumbnailURL
            )
        }
    }

    /// Moods and uploads are not playlists a `watch?list=` can start; Liked Music is always there.
    static func playableIntentPlaylists(_ library: [Playlist]) -> [Playlist] {
        let playable = library.filter {
            $0.moodCategoryEndpoint == nil
                && $0.id != Playlist.uploadedSongsBrowseID
                && !LikedMusicPlaylist.matches(id: $0.id)
        }
        return [LikedMusicPlaylist.playlist] + playable
    }

    func playPlaylist(id: String, shuffled: Bool) async {
        await self.restoreSession()
        SpikeLog.shared.log("intents", "play playlist \(id) shuffled=\(shuffled)")
        let target = MediaEntity.watchPlaylistId(id)
        if shuffled {
            self.player.playShuffled(videoId: nil, playlistId: target)
        } else {
            self.player.play(videoId: nil, playlistId: target)
        }
        self.isNowPlayingPresented = true
    }

    /// The song a text most likely means: YouTube Music's first song result.
    func firstSong(matching query: String) async throws -> MediaEntity? {
        await self.restoreSession()
        guard let song = try await self.client.search(query: query, filter: .songs).songs.first else {
            SpikeLog.shared.log("intents", "no song for \"\(query)\"")
            return nil
        }
        SpikeLog.shared.log("intents", "\"\(query)\" → \(song.videoId)")
        return MediaEntity(song)
    }

    /// The song really playing. The last session shown in the mini player does not count:
    /// nothing is loaded in the page yet.
    var playingVideoId: String? {
        self.player.state.hasMedia ? self.player.state.videoId : nil
    }

    /// Plays a song followed by its radio and shows it.
    func playSong(_ song: MediaEntity) {
        guard let videoId = song.videoId else { return }
        self.player.startRadio(videoId: videoId)
        self.isNowPlayingPresented = true
    }

    /// Likes the song playing and returns its title; `nil` when nothing is playing.
    func likePlayingSong() async throws -> String? {
        await self.restoreSession()
        guard let videoId = self.playingVideoId else { return nil }
        guard self.auth.state == .signedIn else { throw MusicIntentError.notSignedIn }
        try await self.client.rateSong(videoId: videoId, rating: .like)
        self.likedFromOutside = videoId
        SpikeLog.shared.log("intents", "liked \(videoId)")
        return self.player.state.title ?? ""
    }

    /// Opens an item the way a notification does: a song plays, the rest opens on Home.
    func openFromOutside(_ entity: MediaEntity) async {
        await self.restoreSession()
        SpikeLog.shared.log("intents", "open \(entity.id)")
        if entity.videoId == nil { self.isNowPlayingPresented = false }
        NotificationRouter.shared.open(entity)
    }

    /// Results for the text read in an image, best query first and without duplicates.
    func musicItems(forImageLines lines: [MusicIntentText.ImageLine]) async -> [MusicItemEntity] {
        await self.restoreSession()
        let queries = MusicIntentText.imageQueries(from: lines)
        SpikeLog.shared.log("intents", "image text \(lines.map(\.text)) → searches \(queries)")
        var items: [MusicItemEntity] = []
        for query in queries {
            guard let response = try? await self.client.search(query: query) else { continue }
            for item in response.allItems {
                guard let entity = MusicItemEntity(MediaEntity(item)),
                      !items.contains(where: { $0.id == entity.id })
                else { continue }
                items.append(entity)
            }
        }
        return Array(items.prefix(Self.maxImageResults))
    }

    private static var maxImageResults: Int { 10 }
}
