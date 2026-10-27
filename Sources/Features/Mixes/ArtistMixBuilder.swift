import Foundation

/// Builds the queue for an `ArtistMix`: every artist's songs, shuffled and interleaved.
@MainActor
struct ArtistMixBuilder {
    let client: YTMusicClient

    /// Songs considered per artist: their most popular ones, so a mix sounds like the artist.
    static let poolSize = 40
    /// Similar artists added per picked artist when the option is on.
    static let similarPerArtist = 2
    struct Result {
        let songs: [Song]
        let artistCount: Int
    }

    func build(_ mix: ArtistMix) async -> Result {
        // Each artist's page gives their songs and related artists; fetched in parallel.
        let details = await self.fetchSongs(for: mix.artists.map(\.id))
        var similar: [[Song]] = []
        if mix.includesSimilarArtists {
            let picked = Set(mix.artists.map(\.id))
            var seen = picked
            var relatedIds: [String] = []
            for detail in details {
                for artist in detail.related.prefix(Self.similarPerArtist) where seen.insert(artist).inserted {
                    relatedIds.append(artist)
                }
            }
            similar = await self.fetchSongs(for: relatedIds).map(\.songs)
        }
        let recent = mix.skipsRecentlyPlayed ? await self.recentlyPlayedVideoIds() : []
        var generator = SystemRandomNumberGenerator()
        let songs = Self.pickSongs(
            main: details.map(\.songs), similar: similar, excluding: recent,
            count: mix.length.trackCount, discoveryShare: Double(mix.discoveryPercent) / 100, using: &generator
        )
        return Result(songs: songs, artistCount: details.filter { !$0.songs.isEmpty }.count + similar.filter { !$0.isEmpty }.count)
    }

    // MARK: - Selection

    /// Interleaves the artists' songs round by round (a new random artist order each round),
    /// so the same artist never plays twice in a row while others still have songs. Similar
    /// artists take part in every other round only. Recently played songs go to the end of
    /// each artist's pool, used only when nothing else is left.
    ///
    /// `discoveryShare` (0–1) of the songs come from beyond each artist's most
    /// popular ones, spread evenly through the queue; the rest stays the popular pick.
    static func pickSongs(
        main: [[Song]], similar: [[Song]], excluding recent: Set<String>, count: Int,
        discoveryShare: Double = 0, using generator: inout some RandomNumberGenerator
    ) -> [Song] {
        func unique(_ songs: [Song]) -> [Song] {
            var ids = Set<String>()
            return songs.filter { $0.isPlayable && ids.insert($0.videoId).inserted }
        }
        func shuffledPool(_ songs: [Song]) -> [Song] {
            let fresh = songs.filter { !recent.contains($0.videoId) }.shuffled(using: &generator)
            let played = songs.filter { recent.contains($0.videoId) }.shuffled(using: &generator)
            return fresh + played
        }

        let artistSongs = main.map(unique)
        let popular = artistSongs.map { shuffledPool(Array($0.prefix(self.poolSize))) }
        let deepCuts = artistSongs.map { shuffledPool(Array($0.dropFirst(self.poolSize))) }
        let similarPools = similar.map { shuffledPool(Array(unique($0).prefix(self.poolSize))) }

        var pickedIds = Set<String>()
        let discoveryCount = Int((Double(count) * min(max(discoveryShare, 0), 1)).rounded())
        // Discoveries first so the share holds; artists without deep cuts leave it to the others,
        // and whatever is missing is made up from the popular songs.
        let discovered = self.roundRobin(
            main: deepCuts, similar: [], count: discoveryCount, pickedIds: &pickedIds, using: &generator
        )
        let regular = self.roundRobin(
            main: popular, similar: similarPools, count: count - discovered.count, pickedIds: &pickedIds, using: &generator
        )
        // Rounds can end on the artist that starts the next one; split such neighbours.
        return Self.separatingRepeats(Self.spreading(discovered, into: regular))
    }

    private static func roundRobin(
        main: [[Song]], similar: [[Song]], count: Int, pickedIds: inout Set<String>,
        using generator: inout some RandomNumberGenerator
    ) -> [Song] {
        var mainPools = main.filter { !$0.isEmpty }
        var similarPools = similar.filter { !$0.isEmpty }
        var picked: [Song] = []
        var round = 0

        /// Takes the next song of a pool not already picked (a feature can sit in two pools).
        func take(from pool: inout [Song]) -> Song? {
            while !pool.isEmpty {
                let song = pool.removeFirst()
                if pickedIds.insert(song.videoId).inserted { return song }
            }
            return nil
        }

        while picked.count < count, !(mainPools.isEmpty && similarPools.isEmpty) {
            var order = mainPools.indices.map { (similar: false, index: $0) }
            if round.isMultiple(of: 2) || mainPools.isEmpty {
                order += similarPools.indices.map { (similar: true, index: $0) }
            }
            order.shuffle(using: &generator)
            for entry in order where picked.count < count {
                let song = entry.similar ? take(from: &similarPools[entry.index]) : take(from: &mainPools[entry.index])
                if let song { picked.append(song) }
            }
            mainPools.removeAll(where: \.isEmpty)
            similarPools.removeAll(where: \.isEmpty)
            round += 1
        }
        return picked
    }

    /// Inserts `extras` at evenly spaced positions of `base`.
    static func spreading(_ extras: [Song], into base: [Song]) -> [Song] {
        guard !extras.isEmpty else { return base }
        var result = base
        let total = base.count + extras.count
        for (index, song) in extras.enumerated() {
            let position = Int((Double(index) + 0.5) * Double(total) / Double(extras.count))
            result.insert(song, at: min(position, result.count))
        }
        return result
    }

    /// Swaps a song forward when it has the same first artist as the one before it.
    static func separatingRepeats(_ songs: [Song]) -> [Song] {
        var result = songs
        guard result.count > 2 else { return result }
        func artist(_ index: Int) -> String? { result[index].artists.first?.name }
        for index in 1 ..< result.count {
            guard let current = artist(index), current == artist(index - 1) else { continue }
            if let swap = (index + 1 ..< result.count).first(where: { artist($0) != current }) {
                result.swapAt(index, swap)
            }
        }
        return result
    }

    // MARK: - Fetching

    private struct ArtistSongs {
        let songs: [Song]
        let related: [String]
    }

    private func fetchSongs(for artistIds: [String]) async -> [ArtistSongs] {
        var results = [ArtistSongs](repeating: ArtistSongs(songs: [], related: []), count: artistIds.count)
        await withTaskGroup(of: (Int, ArtistSongs).self) { group in
            for (index, id) in artistIds.enumerated() {
                group.addTask { await (index, self.songs(ofArtist: id)) }
            }
            for await (index, songs) in group {
                results[index] = songs
            }
        }
        return results
    }

    /// The artist's full song list when the page links one ("See all"), else its top songs.
    private func songs(ofArtist id: String) async -> ArtistSongs {
        guard let detail = try? await self.client.getArtist(id: id) else { return ArtistSongs(songs: [], related: []) }
        var songs = detail.songs
        if let browseId = detail.songsBrowseId,
           let all = try? await self.client.getArtistSongs(browseId: browseId, params: detail.songsParams),
           !all.isEmpty
        {
            songs = all
        }
        return ArtistSongs(songs: songs, related: detail.relatedArtists.map { MixArtist($0).id })
    }

    /// Video ids on the first page of the account history (signed in only).
    func recentlyPlayedVideoIds() async -> Set<String> {
        Set(await self.recentHistorySongs().map(\.videoId))
    }

    /// The first page of the history without touching the History screen's pagination.
    func recentHistorySongs() async -> [Song] {
        guard let data = try? await self.client.request(
            "browse", body: ["browseId": PaginatedContentType.history.rawValue], authPolicy: .required
        ) else { return [] }
        return HomeResponseParser.parse(data).sections.flatMap(\.items).compactMap {
            if case let .song(song) = $0 { return song }
            return nil
        }
    }
}
