import Foundation
import Testing

@testable import KasetiOS

/// Seeded generator so the shuffles are reproducible.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        self.state &+= 0x9E37_79B9_7F4A_7C15
        var z = self.state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@MainActor
struct ArtistMixTests {
    private static func songs(_ artist: String, _ count: Int) -> [Song] {
        (0 ..< count).map { index in
            Song(
                id: "\(artist)-\(index)", title: "\(artist) \(index)",
                artists: [Artist(id: "UC\(artist)", name: artist)],
                album: nil, duration: 200, thumbnailURL: nil, videoId: "\(artist)-\(index)"
            )
        }
    }

    @Test func picksTheRequestedCountWithoutDuplicatesOrBackToBackArtists() {
        var generator = SeededGenerator(state: 1)
        let picked = ArtistMixBuilder.pickSongs(
            main: [Self.songs("A", 30), Self.songs("B", 30), Self.songs("C", 30)],
            similar: [], excluding: [], count: 25, using: &generator
        )
        #expect(picked.count == 25)
        #expect(Set(picked.map(\.videoId)).count == 25)
        for index in 1 ..< picked.count {
            #expect(picked[index].artists.first?.name != picked[index - 1].artists.first?.name)
        }
        // Every artist gets a fair share.
        let perArtist = Dictionary(grouping: picked) { $0.artists.first?.name ?? "" }.mapValues(\.count)
        #expect(perArtist.values.allSatisfy { (8 ... 9).contains($0) })
    }

    @Test func artistsWithFewSongsLeaveRoomToTheOthers() {
        var generator = SeededGenerator(state: 2)
        let picked = ArtistMixBuilder.pickSongs(
            main: [Self.songs("A", 3), Self.songs("B", 40)], similar: [], excluding: [], count: 20, using: &generator
        )
        #expect(picked.count == 20)
        #expect(picked.filter { $0.artists.first?.name == "A" }.count == 3)
    }

    @Test func recentlyPlayedSongsComeLastAndSimilarArtistsGetLess() {
        var generator = SeededGenerator(state: 3)
        let main = Self.songs("A", 10)
        let recent = Set(main.prefix(5).map(\.videoId))
        let picked = ArtistMixBuilder.pickSongs(
            main: [main], similar: [], excluding: recent, count: 5, using: &generator
        )
        #expect(picked.allSatisfy { !recent.contains($0.videoId) })

        var other = SeededGenerator(state: 4)
        let mixed = ArtistMixBuilder.pickSongs(
            main: [Self.songs("A", 40), Self.songs("B", 40)], similar: [Self.songs("S", 40)],
            excluding: [], count: 50, using: &other
        )
        let similarCount = mixed.filter { $0.artists.first?.name == "S" }.count
        #expect(similarCount > 0 && similarCount < mixed.count / 3)
    }

    @Test func settingsRoundTripThroughThePlaylistDescription() throws {
        let mix = ArtistMix(
            name: "Route",
            artists: [
                MixArtist(id: "MPLAUCabc", name: "עומר אדם", thumbnailURL: nil),
                MixArtist(id: "UCdef", name: "Eyal Golan, Jr.", thumbnailURL: nil),
            ],
            length: .short, includesSimilarArtists: true, skipsRecentlyPlayed: false
        )
        #expect(mix.artists[0].id == "UCabc")
        let description = ArtistMixMarker.description(for: mix)
        #expect(description.hasPrefix("Mix: עומר אדם, Eyal Golan, Jr. · Made with Kaset\n#kaset-mix "))

        let read = try #require(ArtistMixMarker.mix(from: description, playlistId: "PL1", title: "Route", thumbnailURL: nil))
        #expect(read.playlistId == "PL1")
        #expect(read.artists.map(\.id) == ["UCabc", "UCdef"])
        #expect(read.artists.map(\.name) == ["עומר אדם", "Eyal Golan, Jr."])
        #expect(read.length == .short && read.includesSimilarArtists && !read.skipsRecentlyPlayed)
        #expect(read.hasSameSelection(as: mix))
    }

    @Test func ordinaryPlaylistsAreNotMixes() {
        #expect(ArtistMixMarker.mix(from: nil, playlistId: "PL1", title: "x", thumbnailURL: nil) == nil)
        #expect(ArtistMixMarker.mix(from: "My road trip songs", playlistId: "PL1", title: "x", thumbnailURL: nil) == nil)
        #expect(ArtistMixMarker.mix(from: "#kaset-mix {broken", playlistId: "PL1", title: "x", thumbnailURL: nil) == nil)
        #expect(ArtistMixMarker.mix(from: "#kaset-mix {\"v\":1,\"a\":[],\"n\":50,\"s\":false,\"r\":true}", playlistId: "PL1", title: "x", thumbnailURL: nil) == nil)
    }

    @Test func renamingKeepsTheSelectionButNewArtistsChangeIt() {
        let base = ArtistMix(name: "A", artists: [MixArtist(id: "UC1", name: "One", thumbnailURL: nil)])
        var renamed = base
        renamed.name = "B"
        #expect(renamed.hasSameSelection(as: base))
        var more = base
        more.artists.append(MixArtist(id: "UC2", name: "Two", thumbnailURL: nil))
        #expect(!more.hasSameSelection(as: base))
        #expect(more.displayName == "B" || more.displayName == "A")
        #expect(ArtistMix(name: " ", artists: more.artists).displayName == "One & Two")
    }

    /// Owned playlists wrap the header in `musicEditablePlaylistDetailHeaderRenderer`, and
    /// YouTube turns `#kaset-mix` into a separate (hashtag) run.
    @Test(.tags(.parser)) func theMixIsReadBackFromAnOwnedPlaylistPage() throws {
        let mix = ArtistMix(name: "Route", artists: [MixArtist(id: "UC1", name: "One", thumbnailURL: nil)])
        let description = ArtistMixMarker.description(for: mix)
        let parts = description.components(separatedBy: ArtistMixMarker.tag)
        let runs: [[String: Any]] = [
            ["text": parts[0]],
            ["text": "#kaset-mix", "navigationEndpoint": ["browseEndpoint": ["browseId": "FEhashtag"]]],
            ["text": " " + parts[1]],
        ]
        let header: [String: Any] = [
            "musicEditablePlaylistDetailHeaderRenderer": [
                "header": [
                    "musicResponsiveHeaderRenderer": [
                        "title": ["runs": [["text": "Route"]]],
                        "description": ["musicDescriptionShelfRenderer": ["description": ["runs": runs]]],
                    ],
                ],
            ],
        ]
        let data: [String: Any] = [
            "contents": [
                "twoColumnBrowseResultsRenderer": [
                    "tabs": [["tabRenderer": ["content": ["sectionListRenderer": ["contents": [header]]]]]],
                ],
            ],
        ]
        let detail = PlaylistParser.parsePlaylistWithContinuation(data, playlistId: "PL1").detail
        let read = try #require(ArtistMixMarker.mix(from: detail.description, playlistId: "PL1", title: detail.title, thumbnailURL: nil))
        #expect(read.artists.map(\.id) == ["UC1"])
    }

    @Test func discoveriesAreThirtyPercentFromBeyondThePopularSongs() {
        var generator = SeededGenerator(state: 5)
        // Songs come ranked by popularity: index 40 and later are the lesser-known ones.
        let artists = [Self.songs("A", 70), Self.songs("B", 70)]
        let deep = Set(artists.flatMap { $0.dropFirst(ArtistMixBuilder.poolSize) }.map(\.videoId))
        let picked = ArtistMixBuilder.pickSongs(
            main: artists, similar: [], excluding: [], count: 50, discoveryShare: 0.3, using: &generator
        )
        #expect(picked.count == 50)
        #expect(Set(picked.map(\.videoId)).count == 50)
        #expect(picked.filter { deep.contains($0.videoId) }.count == 15)
        // Spread out, not bunched at one end.
        let firstHalf = picked.prefix(25).filter { deep.contains($0.videoId) }.count
        #expect((5 ... 10).contains(firstHalf))

        var other = SeededGenerator(state: 6)
        let off = ArtistMixBuilder.pickSongs(main: artists, similar: [], excluding: [], count: 50, using: &other)
        #expect(off.allSatisfy { !deep.contains($0.videoId) })
    }

    @Test func withoutDeepCutsTheMixIsFilledWithPopularSongs() {
        var generator = SeededGenerator(state: 7)
        let picked = ArtistMixBuilder.pickSongs(
            main: [Self.songs("A", 30), Self.songs("B", 30)], similar: [], excluding: [], count: 25,
            discoveryShare: 1, using: &generator
        )
        #expect(picked.count == 25)
    }

    @Test func discoveryPercentSurvivesTheDescriptionAndOldDescriptionsStillRead() throws {
        let mix = ArtistMix(name: "D", artists: [MixArtist(id: "UC1", name: "One", thumbnailURL: nil)], discoveryPercent: 70)
        let read = try #require(ArtistMixMarker.mix(from: ArtistMixMarker.description(for: mix), playlistId: "PL1", title: "D", thumbnailURL: nil))
        #expect(read.discoveryPercent == 70)
        let old = "#kaset-mix {\"a\":[[\"UC1\",\"One\"]],\"n\":50,\"r\":true,\"s\":false,\"v\":1}"
        let legacy = try #require(ArtistMixMarker.mix(from: old, playlistId: "PL1", title: "D", thumbnailURL: nil))
        #expect(legacy.discoveryPercent == 0)
        // The former on/off toggle reads as 30 %.
        let toggled = "#kaset-mix {\"a\":[[\"UC1\",\"One\"]],\"d\":true,\"n\":50,\"r\":true,\"s\":false,\"v\":1}"
        #expect(ArtistMixMarker.mix(from: toggled, playlistId: "PL1", title: "D", thumbnailURL: nil)?.discoveryPercent == 30)
        // Copies saved before the option existed, or with the toggle, still load.
        let cached = #"[{"name":"D","artists":[{"id":"UC1","name":"One"}],"length":"long","includesSimilarArtists":false,"skipsRecentlyPlayed":true}]"#
        let decoded = try JSONDecoder().decode([ArtistMix].self, from: Data(cached.utf8))
        #expect(decoded.first?.discoveryPercent == 0)
        let cachedToggle = #"[{"name":"D","artists":[{"id":"UC1","name":"One"}],"includesDiscoveries":true}]"#
        #expect(try JSONDecoder().decode([ArtistMix].self, from: Data(cachedToggle.utf8)).first?.discoveryPercent == 30)
    }

    @Test func fullDiscoveriesTakeOnlyLesserKnownSongs() {
        var generator = SeededGenerator(state: 8)
        let artists = [Self.songs("A", 70), Self.songs("B", 70)]
        let deep = Set(artists.flatMap { $0.dropFirst(ArtistMixBuilder.poolSize) }.map(\.videoId))
        let picked = ArtistMixBuilder.pickSongs(
            main: artists, similar: [], excluding: [], count: 50, discoveryShare: 1, using: &generator
        )
        #expect(picked.count == 50)
        #expect(picked.filter { deep.contains($0.videoId) }.count == 50)
    }
}
