import Foundation

/// A tappable thing in a shelf or a result list, reduced to what the UI needs.
/// The native UI never plays anything itself: `MediaActions` turns taps into web view commands.
struct MediaEntity: Identifiable, Hashable {
    enum Target: Hashable {
        case song(videoId: String)
        case playlist(id: String)
        case album(id: String)
        case artist(id: String)
        case mood(browseId: String, params: String?)
        /// A podcast show (`MPSPP…`): opens its page.
        case podcast(id: String)
        /// A podcast episode: plays on its own, without a radio queue.
        case episode(videoId: String)
        case unsupported

        /// Playlists and albums: playing one from a cover starts a queue worth showing.
        var isPlayableCollection: Bool {
            switch self {
            case .playlist, .album: true
            default: false
            }
        }
    }

    /// Who made it, when that has a page: a song's or album's artist, a playlist's owner, a
    /// show's channel, an episode's show. The subtitle opens it.
    struct Author: Hashable {
        let name: String
        let target: Target
    }

    let id: String
    let title: String
    let subtitle: String?
    let thumbnailURL: URL?
    let target: Target
    let isCircular: Bool
    var author: Author?

    /// The author's page, as an entity to open.
    var authorEntity: MediaEntity? {
        guard let author else { return nil }
        var isArtist = false
        if case .artist = author.target { isArtist = true }
        return MediaEntity(
            id: "author-\(author.name)-\(author.target)", title: author.name, subtitle: nil,
            thumbnailURL: nil, target: author.target, isCircular: isArtist
        )
    }

    var videoId: String? {
        switch self.target {
        case let .song(videoId), let .episode(videoId): videoId
        default: nil
        }
    }

    /// Songs and episodes play on tap; everything else opens a page.
    var isPlayableItem: Bool {
        switch self.target {
        case .song, .episode: true
        default: false
        }
    }

    var kindLabel: String {
        switch self.target {
        case .song: "Song"
        case .playlist: "Playlist"
        case .album: "Album"
        case .artist: "Artist"
        case .mood: "Mood"
        case .podcast: "Podcast"
        case .episode: "Episode"
        case .unsupported: ""
        }
    }
}

extension MediaEntity {
    init(_ song: Song, id: String? = nil) {
        self.init(
            id: id ?? "song-\(song.id)",
            title: song.title,
            subtitle: song.artistsDisplay.isEmpty ? nil : song.artistsDisplay,
            thumbnailURL: song.thumbnailURL,
            // Episodes listed in Home shelves arrive as songs.
            target: song.musicVideoType == .podcastEpisode ? .episode(videoId: song.videoId) : .song(videoId: song.videoId),
            isCircular: false,
            author: .first(of: song.artists)
        )
    }

    init(_ show: PodcastShow, id: String? = nil) {
        self.init(
            id: id ?? "podcast-\(show.id)", title: show.title, subtitle: show.author,
            thumbnailURL: show.thumbnailURL, target: .podcast(id: show.id), isCircular: false,
            author: .channel(of: show)
        )
    }

    init(_ episode: PodcastEpisode, id: String? = nil) {
        self.init(
            id: id ?? "episode-\(episode.id)", title: episode.title,
            subtitle: [episode.showTitle, episode.publishedDate].compactMap(\.self).joined(separator: " · ").nilIfEmpty,
            thumbnailURL: episode.thumbnailURL, target: .episode(videoId: episode.id), isCircular: false,
            author: .show(of: episode)
        )
    }

    init(_ item: PodcastSectionItem) {
        switch item {
        case let .show(show): self.init(show)
        case let .episode(episode): self.init(episode)
        }
    }

    init(_ item: HomeSectionItem) {
        switch item {
        case let .song(song):
            self.init(song, id: item.id)
        case let .album(album):
            self.init(
                id: item.id, title: album.title, subtitle: album.artistsDisplay.isEmpty ? nil : album.artistsDisplay,
                thumbnailURL: album.thumbnailURL, target: .album(id: album.id), isCircular: false,
                author: .first(of: album.artists ?? [])
            )
        case let .playlist(playlist):
            if let mood = playlist.resolvedMoodCategoryEndpoint {
                self.init(
                    id: item.id, title: playlist.title, subtitle: nil, thumbnailURL: nil,
                    target: .mood(browseId: mood.browseId, params: mood.params), isCircular: false
                )
            } else {
                self.init(
                    id: item.id, title: playlist.title, subtitle: playlist.author?.name,
                    thumbnailURL: playlist.thumbnailURL, target: .playlist(id: playlist.id), isCircular: false,
                    author: .first(of: playlist.author.map { [$0] } ?? [])
                )
            }
        case let .artist(artist):
            self.init(
                id: item.id, title: artist.name, subtitle: artist.subtitle,
                thumbnailURL: artist.thumbnailURL, target: .artist(id: artist.id), isCircular: true
            )
        }
    }

    init(_ item: SearchResultItem) {
        switch item {
        case let .song(song), let .video(song):
            self.init(song, id: item.id)
        case let .album(album), let .audiobook(album):
            self.init(
                id: item.id, title: album.title, subtitle: item.subtitle,
                thumbnailURL: album.thumbnailURL, target: .album(id: album.id), isCircular: false,
                author: .first(of: album.artists ?? [])
            )
        case let .artist(artist), let .profile(artist):
            self.init(
                id: item.id, title: artist.name, subtitle: item.subtitle,
                thumbnailURL: artist.thumbnailURL, target: .artist(id: artist.id), isCircular: true
            )
        case let .playlist(playlist):
            self.init(
                id: item.id, title: playlist.title, subtitle: item.subtitle,
                thumbnailURL: playlist.thumbnailURL, target: .playlist(id: playlist.id), isCircular: false,
                author: .first(of: playlist.author.map { [$0] } ?? [])
            )
        case let .podcastShow(show):
            self.init(
                id: item.id, title: show.title, subtitle: item.subtitle,
                thumbnailURL: show.thumbnailURL,
                target: show.hasNavigableId ? .podcast(id: show.id) : .unsupported, isCircular: false,
                author: .channel(of: show)
            )
        case let .podcastEpisode(episode):
            self.init(
                id: item.id, title: episode.title, subtitle: item.subtitle,
                thumbnailURL: episode.thumbnailURL, target: .episode(videoId: episode.id), isCircular: false,
                author: .show(of: episode)
            )
        }
    }

    /// Playlist ids from browse carry a `VL` prefix that `watch?list=` does not accept.
    static func watchPlaylistId(_ id: String) -> String {
        id.hasPrefix("VL") ? String(id.dropFirst(2)) : id
    }
}

extension MediaEntity {
    init(_ playlist: Playlist) {
        self.init(
            id: "playlist-\(playlist.id)", title: playlist.title, subtitle: playlist.author?.name,
            thumbnailURL: playlist.thumbnailURL, target: .playlist(id: playlist.id), isCircular: false,
            author: .first(of: playlist.author.map { [$0] } ?? [])
        )
    }

    init(_ album: Album) {
        self.init(
            id: "album-\(album.id)", title: album.title,
            subtitle: album.artistsDisplay.isEmpty ? nil : album.artistsDisplay,
            thumbnailURL: album.thumbnailURL, target: .album(id: album.id), isCircular: false,
            author: .first(of: album.artists ?? [])
        )
    }

    init(_ artist: Artist) {
        self.init(
            id: "artist-\(artist.id)", title: artist.name, subtitle: artist.subtitle,
            thumbnailURL: artist.thumbnailURL, target: .artist(id: artist.id), isCircular: true
        )
    }
}

extension MediaEntity {
    /// Whether the player is currently on this entity (a song, or a playlist/album queue).
    func isCurrent(in identity: PlaybackIdentity) -> Bool {
        switch self.target {
        case let .song(videoId), let .episode(videoId):
            return identity.videoId == videoId
        case let .playlist(id):
            guard let list = identity.listId else { return false }
            return list == Self.watchPlaylistId(id)
        case .album:
            // Album cards only know the browse id, not the playable `OLAK…` list, so the
            // album name the page reports is the available signal.
            guard let album = identity.album, identity.videoId != nil else { return false }
            return album.caseInsensitiveCompare(self.title) == .orderedSame
        default:
            return false
        }
    }
}

extension MediaEntity.Author {
    /// The first artist (or podcast show) that has a page.
    static func first(of artists: [Artist]) -> Self? {
        for artist in artists {
            if artist.hasNavigableId { return Self(name: artist.name, target: .artist(id: artist.id)) }
            if PodcastParser.isPodcastShow(artist.id) { return Self(name: artist.name, target: .podcast(id: artist.id)) }
        }
        return nil
    }

    static func channel(of show: PodcastShow) -> Self? {
        guard let id = show.authorId, let name = show.author else { return nil }
        return Self(name: name, target: .artist(id: id))
    }

    static func show(of episode: PodcastEpisode) -> Self? {
        guard let id = episode.showBrowseId, let name = episode.showTitle else { return nil }
        return Self(name: name, target: .podcast(id: id))
    }
}

private extension String {
    var nilIfEmpty: String? { self.isEmpty ? nil : self }
}
