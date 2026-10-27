import Foundation
import Observation

/// The user's artist mixes. Each one is a private YouTube Music playlist. The mapping
/// playlist id → settings is kept on the device (that is what Home lists and what tells a
/// playlist screen it is a mix); the settings are also written to the playlist description
/// so another device can pick the mix up.
@MainActor
@Observable
final class ArtistMixLibrary {
    private static let cacheKey = "mixes.cache"
    /// v2: v1 could record mix playlists as non-mixes (their description was not read).
    private static let nonMixKey = "mixes.nonMixPlaylists.v2"

    private(set) var mixes: [ArtistMix]
    /// The playlist being created or regenerated, for progress indicators.
    private(set) var busyPlaylistId: String?
    private(set) var isCreating = false

    private let defaults: UserDefaults
    /// Library playlists already read and found not to be mixes (their description is not
    /// fetched again).
    private var nonMixIds: Set<String>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.mixes = defaults.data(forKey: Self.cacheKey)
            .flatMap { try? JSONDecoder().decode([ArtistMix].self, from: $0) } ?? []
        self.nonMixIds = Set(defaults.stringArray(forKey: Self.nonMixKey) ?? [])
    }

    func mix(forPlaylistId id: String) -> ArtistMix? {
        let clean = MediaEntity.watchPlaylistId(id)
        return self.mixes.first { $0.playlistId.map(MediaEntity.watchPlaylistId) == clean }
    }

    // MARK: - Reading the account

    /// Updates the known mixes from the library: covers and titles, drops mixes whose playlist
    /// is gone, and adds mixes created on another device (found by their description).
    func refresh(client: YTMusicClient) async {
        guard let content = try? await client.getLibraryContent(), !content.playlists.isEmpty else { return }
        let library = Dictionary(
            content.playlists.map { (MediaEntity.watchPlaylistId($0.id), $0) }, uniquingKeysWith: { first, _ in first }
        )

        var mixes: [ArtistMix] = []
        for mix in self.mixes {
            guard let id = mix.playlistId else { continue }
            if let playlist = library[id] {
                var updated = mix
                updated.name = playlist.title
                updated.thumbnailURL = playlist.thumbnailURL ?? mix.thumbnailURL
                mixes.append(updated)
            } else if (try? await client.getPlaylist(id: id)) != nil {
                // Not listed yet (a new playlist takes a moment to show up) but still there.
                mixes.append(mix)
            }
        }

        let known = Set(mixes.compactMap(\.playlistId))
        let unknown = library.values.filter { playlist in
            let id = MediaEntity.watchPlaylistId(playlist.id)
            return id.hasPrefix("PL") && !known.contains(id) && !self.nonMixIds.contains(id)
        }
        var notMixes: [String] = []
        await withTaskGroup(of: (String, ArtistMix?).self) { group in
            for playlist in unknown.prefix(60) {
                group.addTask {
                    let id = MediaEntity.watchPlaylistId(playlist.id)
                    guard let detail = try? await client.getPlaylist(id: id).detail else { return (id, nil) }
                    return (id, ArtistMixMarker.mix(
                        from: detail.description, playlistId: id, title: playlist.title,
                        thumbnailURL: playlist.thumbnailURL ?? detail.thumbnailURL
                    ))
                }
            }
            for await (id, mix) in group {
                if let mix { mixes.append(mix) } else { notMixes.append(id) }
            }
        }
        self.mixes = mixes
        self.nonMixIds.formUnion(notMixes)
        self.persist()
    }

    // MARK: - Changes

    /// Builds the songs and creates the playlist. Returns the created mix.
    func create(_ mix: ArtistMix, environment: AppEnvironment) async throws -> ArtistMix {
        self.isCreating = true
        defer { self.isCreating = false }
        let songs = try await self.buildSongs(for: mix, environment: environment)
        let id = try await environment.client.createPlaylist(
            title: mix.displayName, description: ArtistMixMarker.description(for: mix),
            videoIds: songs.map(\.videoId)
        )
        var created = mix
        created.playlistId = MediaEntity.watchPlaylistId(id)
        created.name = mix.displayName
        created.thumbnailURL = songs.first?.thumbnailURL
        self.mixes.insert(created, at: 0)
        self.persist()
        environment.libraryRevision += 1
        SpikeLog.shared.log("mix", "created \(created.displayName) (\(songs.count) songs) → \(id)")
        return created
    }

    /// Saves edited settings: rename, new description, and new songs if the selection changed.
    func update(_ mix: ArtistMix, from previous: ArtistMix, environment: AppEnvironment) async throws {
        guard let id = mix.playlistId else { return }
        self.busyPlaylistId = id
        defer { self.busyPlaylistId = nil }
        let client = environment.client
        if mix.displayName != previous.displayName {
            try await client.renamePlaylist(id: id, title: mix.displayName)
        }
        try await client.setPlaylistDescription(id: id, description: ArtistMixMarker.description(for: mix))
        var saved = mix
        saved.name = mix.displayName
        if !mix.hasSameSelection(as: previous) {
            let songs = try await self.buildSongs(for: mix, environment: environment)
            try await client.replacePlaylistSongs(id: id, with: songs.map(\.videoId))
            saved.thumbnailURL = songs.first?.thumbnailURL ?? saved.thumbnailURL
        }
        self.replace(saved)
        environment.libraryRevision += 1
    }

    /// Replaces the playlist's songs with a new pick.
    func regenerate(_ mix: ArtistMix, environment: AppEnvironment) async throws {
        guard let id = mix.playlistId else { return }
        self.busyPlaylistId = id
        defer { self.busyPlaylistId = nil }
        let songs = try await self.buildSongs(for: mix, environment: environment)
        try await environment.client.replacePlaylistSongs(id: id, with: songs.map(\.videoId))
        var updated = mix
        updated.thumbnailURL = songs.first?.thumbnailURL ?? mix.thumbnailURL
        self.replace(updated)
        environment.libraryRevision += 1
        SpikeLog.shared.log("mix", "regenerated \(mix.displayName) (\(songs.count) songs)")
    }

    func delete(_ mix: ArtistMix, environment: AppEnvironment) async throws {
        guard let id = mix.playlistId else { return }
        try await environment.client.deletePlaylist(id: id)
        self.forget(playlistId: id)
        environment.libraryRevision += 1
    }

    /// Drops the mix backed by a playlist deleted elsewhere (e.g. from the playlist screen).
    func forget(playlistId id: String) {
        let clean = MediaEntity.watchPlaylistId(id)
        self.mixes.removeAll { $0.playlistId.map(MediaEntity.watchPlaylistId) == clean }
        self.persist()
    }

    /// Plays the mix's playlist from the top.
    func play(_ mix: ArtistMix, environment: AppEnvironment) {
        guard let id = mix.playlistId else { return }
        environment.player.play(videoId: nil, playlistId: id)
        environment.isNowPlayingPresented = true
    }

    // MARK: - Helpers

    private func buildSongs(for mix: ArtistMix, environment: AppEnvironment) async throws -> [Song] {
        let songs = await ArtistMixBuilder(client: environment.client).build(mix).songs
        guard !songs.isEmpty else { throw MixError.noSongs }
        return songs
    }

    private func replace(_ mix: ArtistMix) {
        if let index = self.mixes.firstIndex(where: { $0.playlistId == mix.playlistId }) {
            self.mixes[index] = mix
        }
        self.persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(self.mixes) {
            self.defaults.set(data, forKey: Self.cacheKey)
        }
        self.defaults.set(Array(self.nonMixIds), forKey: Self.nonMixKey)
    }

    enum MixError: LocalizedError {
        case noSongs

        var errorDescription: String? {
            String(localized: "Couldn't find songs for this mix")
        }
    }
}
