import Foundation

// MARK: - MixArtist

/// An artist picked for a mix. Library artist ids (`MPLAUC…`) are stored as the channel id.
struct MixArtist: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let thumbnailURL: URL?

    init(id: String, name: String, thumbnailURL: URL?) {
        self.id = id.hasPrefix("MPLAUC") ? String(id.dropFirst(4)) : id
        self.name = name
        self.thumbnailURL = thumbnailURL
    }

    init(_ artist: Artist) {
        self.init(id: artist.id, name: artist.name, thumbnailURL: artist.thumbnailURL)
    }
}

// MARK: - ArtistMix

/// A set of artists backed by a real (private) YouTube Music playlist. The settings live in
/// the playlist description (`ArtistMixMarker`), so the mix follows the account everywhere;
/// "Regenerate" replaces the playlist's songs with a new shuffled pick.
struct ArtistMix: Codable, Identifiable, Hashable {
    enum Length: String, Codable, CaseIterable, Identifiable {
        case short, long

        var id: String { self.rawValue }

        var trackCount: Int {
            switch self {
            case .short: 25
            case .long: 50
            }
        }

        init(trackCount: Int) {
            self = trackCount <= Length.short.trackCount ? .short : .long
        }
    }

    /// `nil` until the playlist exists.
    var playlistId: String?
    var name: String
    var artists: [MixArtist]
    var length: Length = .long
    var includesSimilarArtists = false
    var skipsRecentlyPlayed = true
    /// Percentage (0–100) of lesser-known songs (beyond each artist's most popular ones).
    var discoveryPercent = 0
    /// The playlist's cover, from the library listing.
    var thumbnailURL: URL?

    init(
        playlistId: String? = nil, name: String, artists: [MixArtist], length: Length = .long,
        includesSimilarArtists: Bool = false, skipsRecentlyPlayed: Bool = true,
        discoveryPercent: Int = 0, thumbnailURL: URL? = nil
    ) {
        self.playlistId = playlistId
        self.name = name
        self.artists = artists
        self.length = length
        self.includesSimilarArtists = includesSimilarArtists
        self.skipsRecentlyPlayed = skipsRecentlyPlayed
        self.discoveryPercent = discoveryPercent
        self.thumbnailURL = thumbnailURL
    }

    /// The discoveries option was a 30 % on/off toggle before it became a percentage.
    private enum LegacyKeys: String, CodingKey {
        case includesDiscoveries
    }

    /// Options added later default when reading an older saved copy.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.playlistId = try container.decodeIfPresent(String.self, forKey: .playlistId)
        self.name = try container.decode(String.self, forKey: .name)
        self.artists = try container.decode([MixArtist].self, forKey: .artists)
        self.length = try container.decodeIfPresent(Length.self, forKey: .length) ?? .long
        self.includesSimilarArtists = try container.decodeIfPresent(Bool.self, forKey: .includesSimilarArtists) ?? false
        self.skipsRecentlyPlayed = try container.decodeIfPresent(Bool.self, forKey: .skipsRecentlyPlayed) ?? true
        if let percent = try container.decodeIfPresent(Int.self, forKey: .discoveryPercent) {
            self.discoveryPercent = percent
        } else {
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            let included = try legacy.decodeIfPresent(Bool.self, forKey: .includesDiscoveries) ?? false
            self.discoveryPercent = included ? Self.legacyDiscoveryPercent : 0
        }
        self.thumbnailURL = try container.decodeIfPresent(URL.self, forKey: .thumbnailURL)
    }

    /// What the former "Include discoveries" toggle stood for.
    static let legacyDiscoveryPercent = 30

    var id: String { self.playlistId ?? "new" }

    /// The name, or the first artists when none was given.
    var displayName: String {
        let trimmed = self.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return Self.defaultName(for: self.artists)
    }

    var artistSummary: String {
        let names = self.artists.map(\.name)
        guard names.count > 3 else { return names.joined(separator: ", ") }
        return names.prefix(2).joined(separator: ", ") + " +\(names.count - 2)"
    }

    static func defaultName(for artists: [MixArtist]) -> String {
        switch artists.count {
        case 0: ""
        case 1: artists[0].name
        default: artists.prefix(2).map(\.name).joined(separator: " & ")
        }
    }

    /// Settings that change which songs are picked (a rename alone does not regenerate).
    func hasSameSelection(as other: ArtistMix) -> Bool {
        self.artists.map(\.id) == other.artists.map(\.id) && self.length == other.length
            && self.includesSimilarArtists == other.includesSimilarArtists
            && self.skipsRecentlyPlayed == other.skipsRecentlyPlayed
            && self.discoveryPercent == other.discoveryPercent
    }
}

// MARK: - ArtistMixMarker

/// Reads and writes a mix's settings in its playlist description: a readable sentence, then
/// one line `#kaset-mix {json}` the app parses back on any device.
enum ArtistMixMarker {
    static let tag = "#kaset-mix "

    private struct Payload: Codable {
        var v = 1
        /// `[channelId, name]` pairs.
        var a: [[String]]
        var n: Int
        var s: Bool
        var r: Bool
        /// Discoveries on/off, as read by versions before the percentage; absent in older descriptions.
        var d: Bool?
        /// Discovery percentage; absent in descriptions written before it existed.
        var p: Int?
    }

    static func description(for mix: ArtistMix) -> String {
        let payload = Payload(
            a: mix.artists.map { [$0.id, $0.name] }, n: mix.length.trackCount,
            s: mix.includesSimilarArtists, r: mix.skipsRecentlyPlayed,
            d: mix.discoveryPercent > 0, p: mix.discoveryPercent
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        let json = (try? encoder.encode(payload)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let names = mix.artists.map(\.name).joined(separator: ", ")
        return "Mix: \(names) · Made with Kaset\n\(self.tag)\(json)"
    }

    /// The mix described by a playlist description, or `nil` for any other playlist.
    static func mix(from description: String?, playlistId: String, title: String, thumbnailURL: URL?) -> ArtistMix? {
        guard let description,
              let line = description.split(whereSeparator: \.isNewline).last(where: { $0.hasPrefix(self.tag) }),
              let data = line.dropFirst(self.tag.count).data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else { return nil }
        let artists = payload.a.compactMap { pair -> MixArtist? in
            guard pair.count >= 2 else { return nil }
            return MixArtist(id: pair[0], name: pair[1], thumbnailURL: nil)
        }
        guard !artists.isEmpty else { return nil }
        return ArtistMix(
            playlistId: playlistId, name: title, artists: artists, length: .init(trackCount: payload.n),
            includesSimilarArtists: payload.s, skipsRecentlyPlayed: payload.r,
            discoveryPercent: payload.p ?? (payload.d == true ? ArtistMix.legacyDiscoveryPercent : 0),
            thumbnailURL: thumbnailURL
        )
    }
}
