import Foundation
import Observation

/// State and actions of the mix editor, shared by the iOS form and the macOS sheet: the mix
/// being edited, artist search, suggestions, saving and deleting.
@MainActor
@Observable
final class MixEditorModel {
    let isNew: Bool
    private let original: ArtistMix?

    var mix: ArtistMix
    var query = ""
    private(set) var results: [Artist] = []
    private(set) var isSearching = false
    private(set) var suggestions: [MixArtist] = []
    private(set) var isLoadingSuggestions = false
    private(set) var isSaving = false
    var failureMessage: String?
    var isConfirmingDelete = false

    init(mix: ArtistMix? = nil) {
        self.isNew = mix == nil
        self.original = mix
        self.mix = mix ?? ArtistMix(name: "", artists: [])
    }

    var canSave: Bool { !self.mix.artists.isEmpty && !self.isSaving }

    var isSearchActive: Bool {
        !self.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Shown in the empty name field: the name the mix gets if the field stays empty.
    var namePlaceholder: String {
        let name = ArtistMix.defaultName(for: self.mix.artists)
        return name.isEmpty ? String(localized: "My mix") : name
    }

    /// The slider works in 0–1; the mix stores whole percents.
    var discoveryShare: Double {
        get { Double(self.mix.discoveryPercent) / 100 }
        set { self.mix.discoveryPercent = Int((newValue * 100).rounded()) }
    }

    func isSelected(_ artist: MixArtist) -> Bool {
        self.mix.artists.contains { $0.id == artist.id }
    }

    // MARK: - Actions

    func toggle(_ artist: MixArtist) {
        Haptics.tap()
        if let index = self.mix.artists.firstIndex(where: { $0.id == artist.id }) {
            self.mix.artists.remove(at: index)
        } else {
            self.mix.artists.append(artist)
        }
    }

    func removeArtists(atOffsets offsets: IndexSet) {
        self.mix.artists.remove(atOffsets: offsets)
    }

    /// Creates the playlist (new mix) or applies the changes. Returns the saved mix, or `nil`
    /// (with `failureMessage` set) when it failed.
    func save(environment: AppEnvironment) async -> ArtistMix? {
        self.isSaving = true
        defer { self.isSaving = false }
        let library = environment.mixes
        do {
            if let original = self.original {
                try await library.update(self.mix, from: original, environment: environment)
                return self.mix
            }
            return try await library.create(self.mix, environment: environment)
        } catch {
            self.failureMessage = error.localizedDescription
            return nil
        }
    }

    /// Deletes the mix and its playlist. Returns `true` on success.
    func delete(environment: AppEnvironment) async -> Bool {
        do {
            try await environment.mixes.delete(self.mix, environment: environment)
            return true
        } catch {
            self.failureMessage = error.localizedDescription
            return false
        }
    }

    // MARK: - Loading

    /// Mixes read back from a playlist description have names but no photos.
    func loadArtistPhotos(environment: AppEnvironment) async {
        for (index, artist) in self.mix.artists.enumerated() where artist.thumbnailURL == nil {
            guard let detail = try? await environment.client.getArtist(id: artist.id),
                  let url = detail.thumbnailURL ?? detail.artist.thumbnailURL,
                  self.mix.artists.indices.contains(index), self.mix.artists[index].id == artist.id
            else { continue }
            self.mix.artists[index] = MixArtist(id: artist.id, name: artist.name, thumbnailURL: url)
        }
    }

    func search(environment: AppEnvironment) async {
        let text = self.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            self.results = []
            return
        }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        self.isSearching = true
        defer { self.isSearching = false }
        let response = try? await environment.client.search(query: text, filter: .artists)
        guard !Task.isCancelled else { return }
        self.results = (response?.artists ?? []).filter(\.hasNavigableId)
    }

    /// Most frequent artists of the recent history first, then followed artists.
    func loadSuggestions(environment: AppEnvironment) async {
        guard environment.auth.state == .signedIn else { return }
        self.isLoadingSuggestions = true
        defer { self.isLoadingSuggestions = false }
        let history = await ArtistMixBuilder(client: environment.client).recentHistorySongs()
        var counts: [String: (artist: MixArtist, count: Int)] = [:]
        for song in history {
            for artist in song.artists where artist.hasNavigableId {
                let mixArtist = MixArtist(artist)
                counts[mixArtist.id, default: (mixArtist, 0)].count += 1
            }
        }
        let fromHistory = counts.values.sorted { $0.count > $1.count }.map(\.artist)
        let followed = ((try? await environment.client.getLibraryContent())?.artists ?? [])
            .filter(\.hasNavigableId).map(MixArtist.init)
        self.suggestions = Self.mergeSuggestions(history: fromHistory, followed: followed)
    }

    /// Deduplicates history and followed artists (history first), preferring the followed
    /// artist's photo since history entries often lack one. Keeps the first 30.
    static func mergeSuggestions(history: [MixArtist], followed: [MixArtist], limit: Int = 30) -> [MixArtist] {
        var seen = Set<String>()
        var merged: [MixArtist] = []
        for artist in history + followed where seen.insert(artist.id).inserted {
            let photo = artist.thumbnailURL ?? followed.first { $0.id == artist.id }?.thumbnailURL
            merged.append(MixArtist(id: artist.id, name: artist.name, thumbnailURL: photo))
        }
        return Array(merged.prefix(limit))
    }
}
