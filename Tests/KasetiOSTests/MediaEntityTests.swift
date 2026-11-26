import Foundation
import Testing

@testable import KasetiOS

struct MediaEntityTests {
    @Test func stripsBrowsePrefixFromPlaylistIds() {
        #expect(MediaEntity.watchPlaylistId("VLPLabc") == "PLabc")
        #expect(MediaEntity.watchPlaylistId("RDCLAK5uy_x") == "RDCLAK5uy_x")
    }

    @Test func searchSongMapsToPlayableSong() throws {
        let data: [String: Any] = try JSONSerialization.jsonObject(
            with: Data(contentsOf: #require(Bundle(for: FixtureBundleToken.self).url(forResource: "search_response", withExtension: "json")))
        ) as? [String: Any] ?? [:]
        let response = SearchResponseParser.parse(data)
        let song = try #require(response.songs.first)
        let entity = MediaEntity(SearchResultItem.song(song))
        #expect(entity.videoId == song.videoId)
        #expect(entity.title == song.title)
        #expect(!entity.isCircular)
    }

    @Test func artistsAreCircularAndNavigable() {
        let artist = Artist(id: "UC123", name: "Someone")
        let entity = MediaEntity(HomeSectionItem.artist(artist))
        #expect(entity.isCircular)
        #expect(entity.target == .artist(id: "UC123"))
    }
}

@MainActor
struct PodcastEntityTests {
    private let show = PodcastShow(
        id: "MPSPPLshow", title: "Show", author: "Network", description: nil, thumbnailURL: nil, episodeCount: nil
    )
    private let episode = PodcastEpisode(
        id: "ep1", title: "Episode", showTitle: "Show", showBrowseId: "MPSPPLshow", description: nil,
        thumbnailURL: nil, publishedDate: "2d ago", duration: "36 min", durationSeconds: 2160,
        playbackProgress: 0, isPlayed: false
    )

    @Test func showsOpenTheirPage() {
        let entity = MediaEntity(SearchResultItem.podcastShow(self.show))
        #expect(entity.target == .podcast(id: "MPSPPLshow"))
        #expect(!entity.isPlayableItem)
        #expect(entity.videoId == nil)
    }

    @Test func showsWithoutABrowseIdStayUnsupported() {
        let show = PodcastShow(id: "UCchannel", title: "Show", author: nil, description: nil, thumbnailURL: nil, episodeCount: nil)
        #expect(MediaEntity(SearchResultItem.podcastShow(show)).target == .unsupported)
    }

    @Test func episodesPlayOnTheirOwn() {
        let entity = MediaEntity(PodcastSectionItem.episode(self.episode))
        #expect(entity.target == .episode(videoId: "ep1"))
        #expect(entity.isPlayableItem)
        #expect(entity.videoId == "ep1")
        #expect(entity.subtitle == "Show · 2d ago")
        let identity = PlaybackIdentity(videoId: "ep1", listId: nil, album: nil, isPlaying: true)
        #expect(entity.isCurrent(in: identity))
    }

    @Test func homeEpisodesBecomeEpisodes() {
        let song = Song(
            id: "ep2", title: "Episode", artists: [], album: nil, duration: nil, thumbnailURL: nil,
            videoId: "ep2", musicVideoType: .podcastEpisode
        )
        #expect(MediaEntity(HomeSectionItem.song(song)).target == .episode(videoId: "ep2"))
    }

    @Test func searchFiltersCoverPodcasts() {
        #expect(SearchViewModel.filter(for: .podcastShow(self.show)) == .podcasts)
        #expect(SearchViewModel.filter(for: .podcastEpisode(self.episode)) == .episodes)
        #expect(SearchFilter.podcasts.params != nil)
        #expect(SearchFilter.episodes.params != nil)
    }

    @Test func intentIdentifiersRoundTrip() {
        for target in [MediaEntity.Target.podcast(id: "MPSPPLshow"), .episode(videoId: "ep1")] {
            let id = MusicItemEntity.identifier(for: target)
            #expect(id.flatMap(MusicItemEntity.target(for:)) == target)
        }
    }

    @Test func authorsOpenTheirPage() {
        // An episode's author is its show.
        #expect(MediaEntity(self.episode).authorEntity?.target == .podcast(id: "MPSPPLshow"))
        // A show's author is its channel, when the response linked it.
        var show = self.show
        #expect(MediaEntity(show).authorEntity == nil)
        show.authorId = "UCnetwork"
        let channel = MediaEntity(show).authorEntity
        #expect(channel?.target == .artist(id: "UCnetwork"))
        #expect(channel?.title == "Network")
        #expect(channel?.isCircular == true)
        // A song's author is its first artist with a page; names without one are not links.
        let song = Song(
            id: "s", title: "Song",
            artists: [Artist(id: "nolink", name: "Guest"), Artist(id: "UCartist", name: "Singer")],
            videoId: "s"
        )
        #expect(MediaEntity(song).authorEntity?.target == .artist(id: "UCartist"))
        let unlinked = Song(id: "u", title: "Song", artists: [Artist(id: "nolink", name: "Guest")], videoId: "u")
        #expect(MediaEntity(unlinked).authorEntity == nil)
    }

    @Test func onlyA404MeansNoPodcastsPage() {
        #expect(PodcastsModel.isNotFound(YTMusicError.apiError(message: "HTTP 404", code: 404)))
        #expect(!PodcastsModel.isNotFound(YTMusicError.apiError(message: "HTTP 500", code: 500)))
        #expect(!PodcastsModel.isNotFound(YTMusicError.notAuthenticated))
        #expect(!PodcastsModel.isNotFound(CancellationError()))
    }

    @Test func emptyAndRepeatedShelvesAreDropped() {
        let show = PodcastSectionItem.show(self.show)
        let sections = PodcastsModel.withoutEmptyOrDuplicate([
            PodcastSection(id: "a", title: "Shows", items: [show]),
            PodcastSection(id: "b", title: "Empty", items: []),
            PodcastSection(id: "c", title: "shows", items: [show]),
            PodcastSection(id: "a", title: "Other", items: [show]),
            PodcastSection(id: "d", title: "Episodes", items: [.episode(self.episode)]),
        ])
        #expect(sections.map(\.id) == ["a", "d"])
    }
}

struct NowPlayingIndicatorTests {
    private func entity(_ target: MediaEntity.Target, title: String = "T") -> MediaEntity {
        MediaEntity(id: "x", title: title, subtitle: nil, thumbnailURL: nil, target: target, isCircular: false)
    }

    @Test func songMatchesByVideoId() {
        let identity = PlaybackIdentity(videoId: "abc", listId: nil, album: nil, isPlaying: true)
        #expect(self.entity(.song(videoId: "abc")).isCurrent(in: identity))
        #expect(!self.entity(.song(videoId: "zzz")).isCurrent(in: identity))
    }

    @Test func playlistMatchesByListWithoutBrowsePrefix() {
        let identity = PlaybackIdentity(videoId: "abc", listId: "PLxyz", album: nil, isPlaying: false)
        #expect(self.entity(.playlist(id: "VLPLxyz")).isCurrent(in: identity))
        #expect(!self.entity(.playlist(id: "VLPLother")).isCurrent(in: identity))
    }

    @Test func albumMatchesByNameIgnoringCase() {
        let identity = PlaybackIdentity(videoId: "abc", listId: nil, album: "Some Album", isPlaying: true)
        #expect(self.entity(.album(id: "MPREb_1"), title: "some album").isCurrent(in: identity))
        #expect(!self.entity(.album(id: "MPREb_1"), title: "Other").isCurrent(in: identity))
    }

    @Test func nothingMatchesWhenNothingPlays() {
        let identity = PlaybackIdentity()
        #expect(!self.entity(.song(videoId: "abc")).isCurrent(in: identity))
        #expect(!self.entity(.album(id: "MPREb_1")).isCurrent(in: identity))
    }

    @Test func searchFiltersCarryTheirParams() {
        #expect(SearchFilter.all.params == nil)
        #expect(SearchFilter.songs.params == "EgWKAQIIAWoMEA4QChADEAQQCRAF")
        #expect(Set(SearchFilter.allCases.compactMap(\.params)).count == 5)
    }
}
