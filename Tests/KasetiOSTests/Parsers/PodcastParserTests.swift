import Foundation
import Testing
@testable import KasetiOS

// MARK: - PodcastParserTests

/// Fixtures follow the shapes of live responses (show page checked 2026-11) with placeholder
/// values only.
@Suite(.tags(.parser))
struct PodcastParserTests {
    // MARK: Show page

    @Test("Show header reads the strapline author, wrapped description and saved state")
    func showHeader() throws {
        let detail = try PodcastParser.parseShowDetail(Self.fixture("podcast_show"), showId: "MPSPPLfixture-show")

        #expect(detail.show.id == "MPSPPLfixture-show")
        #expect(detail.show.title == "Fixture Show")
        #expect(detail.show.author == "Fixture Network")
        #expect(detail.show.description == "A show used by the tests.")
        #expect(detail.show.thumbnailURL?.absoluteString.contains("fixture-show") == true)
        // The strapline links the publishing channel.
        #expect(detail.show.authorId == "UCfixture-channel")
        #expect(detail.isSubscribed)
        #expect(detail.continuationToken == "fixture-episodes-token")
    }

    @Test("Show episodes read date, nested duration and progress, credited to the show")
    func showEpisodes() throws {
        let detail = try PodcastParser.parseShowDetail(Self.fixture("podcast_show"), showId: "MPSPPLfixture-show")

        #expect(detail.episodes.map(\.id) == ["fixture-episode-1", "fixture-episode-2", "fixture-episode-3"])

        let newest = try #require(detail.episodes.first)
        #expect(newest.title == "Newest Episode")
        // "22K views • 17h ago": the date, not the view count.
        #expect(newest.publishedDate == "17h ago")
        #expect(newest.duration == "27 min")
        #expect(newest.durationSeconds == 27 * 60)
        #expect(newest.playbackProgress == 0)
        // Every episode carries a "Played" label; it is not a played flag.
        #expect(!newest.isPlayed)
        #expect(newest.description == "Description of Newest Episode.")
        #expect(newest.showTitle == "Fixture Show")
        #expect(newest.showBrowseId == "MPSPPLfixture-show")
        #expect(newest.thumbnailURL != nil)

        let half = detail.episodes[1]
        #expect(half.playbackProgress == 0.4)
        #expect(!half.isPlayed)
        #expect(half.durationSeconds == 3723)

        let played = detail.episodes[2]
        #expect(played.isPlayed)
        #expect(played.publishedDate == "Nov 2, 2026")
    }

    @Test("Empty show response keeps the requested id")
    func emptyShow() {
        let detail = PodcastParser.parseShowDetail([:], showId: "MPSPPLempty")
        #expect(detail.show.id == "MPSPPLempty")
        #expect(detail.show.title.isEmpty)
        #expect(detail.episodes.isEmpty)
        #expect(detail.continuationToken == nil)
        #expect(!detail.isSubscribed)
    }

    // MARK: Continuations

    @Test("Episode continuation parses playable episodes and ends without a token")
    func episodesContinuation() throws {
        let page = try PodcastParser.parseEpisodesContinuation(Self.fixture("podcast_episodes_continuation"))
        #expect(page.episodes.map(\.id) == ["fixture-episode-4"])
        #expect(page.episodes.first?.durationSeconds == 3900)
        #expect(page.continuationToken == nil)
        #expect(!page.hasMore)
    }

    @Test("Response-action continuations append episodes and carry the next token")
    func responseActionContinuation() throws {
        let show = try Self.fixture("podcast_show")
        let shelf = try #require(Self.episodeShelf(in: show))
        let firstEpisode = try #require((shelf["contents"] as? [[String: Any]])?.first)
        let data: [String: Any] = [
            "onResponseReceivedActions": [[
                "appendContinuationItemsAction": [
                    "continuationItems": [
                        firstEpisode,
                        ["continuationItemRenderer": ["continuationEndpoint": ["continuationCommand": ["token": "next-token"]]]],
                    ],
                ],
            ]],
        ]
        let page = PodcastParser.parseEpisodesContinuation(data)
        #expect(page.episodes.map(\.id) == ["fixture-episode-1"])
        #expect(page.continuationToken == "next-token")
    }

    // MARK: Discovery

    @Test("Discovery keeps shows and episodes, drops non-podcast items and empty shelves")
    func discovery() throws {
        let page = try PodcastParser.parseDiscovery(Self.fixture("podcast_discovery"))

        #expect(page.sections.map(\.title) == ["Popular shows", "Latest episodes"])
        #expect(page.continuationToken == "fixture-discovery-token")

        let shows = page.sections[0].items.compactMap { item -> PodcastShow? in
            if case let .show(show) = item { return show }
            return nil
        }
        #expect(shows.map(\.id) == ["MPSPPLfixture-show", "MPSPPLother-show"])
        #expect(shows.first?.author == "Fixture Network")

        guard case let .episode(episode) = page.sections[1].items.first else {
            Issue.record("Expected an episode")
            return
        }
        // On mixed lists the show is a linked run of the subtitle.
        #expect(episode.showTitle == "Fixture Show")
        #expect(episode.showBrowseId == "MPSPPLfixture-show")
        #expect(episode.publishedDate == "2d ago")
        #expect(episode.durationSeconds == 36 * 60)
    }

    @Test("Section ids are stable across parses")
    func stableSectionIds() throws {
        let first = try PodcastParser.parseDiscovery(Self.fixture("podcast_discovery"))
        let second = try PodcastParser.parseDiscovery(Self.fixture("podcast_discovery"))
        #expect(first.sections.map(\.id) == second.sections.map(\.id))
        #expect(Set(first.sections.map(\.id)).count == first.sections.count)
    }

    @Test("Empty and unknown discovery responses give no sections")
    func emptyDiscovery() {
        #expect(PodcastParser.parseDiscovery([:]).sections.isEmpty)
        #expect(PodcastParser.parseDiscoveryContinuation([:]).sections.isEmpty)
    }

    // MARK: Podcast shelves of Home and Explore

    @Test("Home and Explore keep only podcast shelves, with only podcast items")
    func mixedPageShelves() throws {
        let sections = try PodcastParser.parsePodcastShelves(Self.fixture("podcast_mixed_shelves"))

        // Music shelves (Trending, New music videos) and the shortcut grid are dropped.
        #expect(sections.map(\.title) == ["Popular episodes", "Podcasts to get you started", "Mixed picks"])

        guard case let .episode(popular) = sections[0].items.first else {
            Issue.record("Expected an episode")
            return
        }
        // Explore names the show in secondTitle; the subtitle is "views • date".
        #expect(popular.showTitle == "Fixture Show")
        #expect(popular.showBrowseId == "MPSPPLfixture-show")
        #expect(popular.publishedDate == "1d ago")
        #expect(popular.durationSeconds == 21 * 60)

        // The album in the podcasts shelf is not kept.
        #expect(sections[1].items.map(\.id) == ["MPSPPLfixture-show"])
        if case let .show(show) = sections[1].items.first {
            #expect(show.author == "Fixture Network")
            #expect(show.authorId == "UCfixture-channel")
        } else {
            Issue.record("Expected a show")
        }
        // A music video next to an episode card: only the episode stays.
        #expect(sections[2].items.map(\.id) == ["fixture-episode-in-shelf"])
    }

    @Test("Podcast items are recognised; music items never are")
    func podcastItemDetection() throws {
        let sections = try PodcastParser.parsePodcastShelves(Self.fixture("podcast_mixed_shelves"))
        let ids = sections.flatMap(\.items).map(\.id)
        #expect(!ids.contains("fixture-song"))
        #expect(!ids.contains("fixture-video"))
        #expect(!ids.contains("fixture-video-2"))
        #expect(!ids.contains("MPREfixture-album"))
        #expect(PodcastParser.parsePodcastShelves([:]).isEmpty)
    }

    // MARK: Where the discovery page is

    @Test("Explore's Podcasts shortcut gives the discovery endpoint")
    func exploreShortcut() throws {
        let endpoint = try PodcastParser.discoveryEndpoint(inExplore: Self.fixture("podcast_explore_shortcuts"))
        #expect(endpoint == PodcastParser.Endpoint(browseId: "FEmusic_non_music_audio", params: nil))
        #expect(PodcastParser.discoveryEndpoint(inExplore: [:]) == nil)
    }

    @Test("A renamed page is found by the shortcut's icon")
    func exploreShortcutByIcon() {
        let explore: [String: Any] = ["items": [[
            "musicNavigationButtonRenderer": [
                "clickCommand": ["browseEndpoint": ["browseId": "FEmusic_renamed", "params": "p"]],
                "iconStyle": ["icon": ["iconType": "BROADCAST"]],
            ],
        ]]]
        #expect(PodcastParser.discoveryEndpoint(inExplore: explore) == .init(browseId: "FEmusic_renamed", params: "p"))
    }

    @Test("Candidates: the shortcut first, then every known id once")
    func discoveryCandidates() {
        #expect(PodcastParser.discoveryCandidates(shortcut: nil).map(\.browseId) == ["FEmusic_non_music_audio", "FEmusic_podcasts"])
        let renamed = PodcastParser.Endpoint(browseId: "FEmusic_renamed", params: nil)
        #expect(PodcastParser.discoveryCandidates(shortcut: renamed).map(\.browseId)
            == ["FEmusic_renamed", "FEmusic_non_music_audio", "FEmusic_podcasts"])
        let known = PodcastParser.Endpoint(browseId: "FEmusic_podcasts", params: nil)
        #expect(PodcastParser.discoveryCandidates(shortcut: known).map(\.browseId) == ["FEmusic_podcasts", "FEmusic_non_music_audio"])
    }

    // MARK: Helpers

    @Test("Show ids map to their library playlist")
    func showPlaylistId() {
        #expect(PodcastParser.playlistId(forShow: "MPSPPLabc123") == "PLabc123")
        #expect(PodcastParser.playlistId(forShow: "VLPLabc") == nil)
        #expect(PodcastParser.isPodcastShow("MPSPPLabc"))
        #expect(!PodcastParser.isPodcastShow("MPREabc"))
    }

    @Test("Durations in clock and spelled-out forms", arguments: [
        ("27 min", 1620), ("1:02:03", 3723), ("42:10", 2530), ("1 hr 5 min", 3900), ("2 hr", 7200), ("soon", -1),
    ])
    func durations(text: String, seconds: Int) {
        #expect(PodcastParser.parseDurationToSeconds(text) == (seconds < 0 ? nil : seconds))
    }

    @Test("Library podcasts merge dedicated and landing shows without duplicates")
    func mergedLibraryShows() {
        func show(_ id: String) -> PodcastShow {
            PodcastShow(id: id, title: id, author: nil, description: nil, thumbnailURL: nil, episodeCount: nil)
        }
        let merged = YTMusicClient.mergedPodcastShows([show("MPSPPLa"), show("MPSPPLb")], [show("MPSPPLb"), show("MPSPPLc")])
        #expect(merged.map(\.id) == ["MPSPPLa", "MPSPPLb", "MPSPPLc"])
    }

    // MARK: Fixtures

    static func fixture(_ name: String) throws -> [String: Any] {
        let url = try #require(Bundle(for: FixtureBundleToken.self).url(forResource: name, withExtension: "json"))
        return try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private static func episodeShelf(in show: [String: Any]) -> [String: Any]? {
        let contents = show["contents"] as? [String: Any]
        let twoColumn = contents?["twoColumnBrowseResultsRenderer"] as? [String: Any]
        let secondary = twoColumn?["secondaryContents"] as? [String: Any]
        let sections = (secondary?["sectionListRenderer"] as? [String: Any])?["contents"] as? [[String: Any]]
        return sections?.first?["musicShelfRenderer"] as? [String: Any]
    }
}
