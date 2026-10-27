import SwiftUI

/// Creates or edits an artist mix: picked artists, suggestions (followed artists and the
/// history), artist search, and the options. Saving creates (or updates) the mix's private
/// YouTube Music playlist; "Play" saves and starts it.
struct MixEditorView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    private let isNew: Bool
    private let original: ArtistMix?
    @State private var mix: ArtistMix
    @State private var isSaving = false
    @State private var failureMessage: String?
    @State private var query = ""
    @State private var results: [Artist] = []
    @State private var isSearching = false
    @State private var suggestions: [MixArtist] = []
    @State private var isConfirmingDelete = false

    init(mix: ArtistMix? = nil) {
        self.isNew = mix == nil
        self.original = mix
        self._mix = State(initialValue: mix ?? ArtistMix(name: "", artists: []))
    }

    var body: some View {
        NavigationStack {
            List {
                if self.query.isEmpty {
                    self.nameSection
                    self.optionsSection
                    self.artistsSection
                    self.suggestionsSection
                    if !self.isNew {
                        Section {
                            Button("Delete Mix", role: .destructive) { self.isConfirmingDelete = true }
                        }
                    }
                } else {
                    self.resultsSection
                }
            }
            .searchable(text: self.$query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search artists")
            .navigationTitle(self.isNew ? "New Mix" : "Edit Mix")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { self.dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if self.isSaving {
                        ProgressView()
                    } else {
                        Button("Save") { Task { await self.save(thenPlay: false) } }
                            .disabled(self.mix.artists.isEmpty)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if self.query.isEmpty {
                    Button {
                        Task { await self.save(thenPlay: true) }
                    } label: {
                        if self.isSaving {
                            ProgressView().tint(.white)
                        } else {
                            Label(self.isNew ? "Create and Play" : "Save and Play", systemImage: "play.fill")
                        }
                    }
                    .buttonStyle(PrimaryActionButtonStyle())
                    .disabled(self.mix.artists.isEmpty || self.isSaving)
                    .opacity(self.mix.artists.isEmpty ? 0.5 : 1)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(.bar)
                }
            }
            .confirmationDialog("Delete this mix?", isPresented: self.$isConfirmingDelete, titleVisibility: .visible) {
                Button("Delete Mix", role: .destructive) {
                    Task {
                        do {
                            try await self.environment.mixes.delete(self.mix, environment: self.environment)
                            self.dismiss()
                        } catch {
                            self.failureMessage = error.localizedDescription
                        }
                    }
                }
            } message: {
                Text("The playlist is deleted from your YouTube Music account.")
            }
            .alert("Mix", isPresented: Binding(
                get: { self.failureMessage != nil },
                set: { if !$0 { self.failureMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(self.failureMessage ?? "")
            }
            .interactiveDismissDisabled(self.isSaving)
            .task {
                await self.loadArtistPhotos()
                await self.loadSuggestions()
            }
            .task(id: self.query) { await self.search() }
        }
    }

    // MARK: - Sections

    private var nameSection: some View {
        Section("Name") {
            TextField(
                ArtistMix.defaultName(for: self.mix.artists).isEmpty ? String(localized: "My mix") : ArtistMix.defaultName(for: self.mix.artists),
                text: self.$mix.name
            )
        }
    }

    @ViewBuilder
    private var artistsSection: some View {
        Section {
            if self.mix.artists.isEmpty {
                Text("Add artists from the suggestions or search for them.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(self.mix.artists) { artist in
                MixArtistRow(artist: artist, isSelected: true) { self.toggle(artist) }
            }
            .onDelete { self.mix.artists.remove(atOffsets: $0) }
        } header: {
            Text("Artists (\(self.mix.artists.count))")
        }
    }

    @ViewBuilder
    private var suggestionsSection: some View {
        // Picked artists stay in place with a checkmark (the selection is the section above).
        if !self.suggestions.isEmpty {
            Section {
                ForEach(self.suggestions) { artist in
                    MixArtistRow(artist: artist, isSelected: self.mix.artists.contains { $0.id == artist.id }) {
                        self.toggle(artist)
                    }
                }
            } header: {
                Text("Suggestions")
            } footer: {
                Text("From the artists you follow and your recent history.")
            }
        }
    }

    private var optionsSection: some View {
        Section {
            Picker("Length", selection: self.$mix.length) {
                ForEach(ArtistMix.Length.allCases) { length in
                    Text("\(length.trackCount) songs").tag(length)
                }
            }
            Toggle("Include similar artists", isOn: self.$mix.includesSimilarArtists)
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("Discoveries") {
                    Text(self.mix.discoveryPercent, format: .percent)
                        .monospacedDigit()
                }
                Slider(value: self.discoveryShare, in: 0 ... 1, step: 0.1) {
                    Text("Discoveries")
                } minimumValueLabel: {
                    Text(0, format: .percent)
                } maximumValueLabel: {
                    Text(100, format: .percent)
                }
                .tint(Color.brand)
                .accessibilityValue(Text(self.mix.discoveryPercent, format: .percent))
            }
            Toggle("Skip recently played", isOn: self.$mix.skipsRecentlyPlayed)
        } header: {
            Text("Options")
        } footer: {
            Text("Discoveries are lesser-known songs by these artists; the slider sets how much of the mix they make up. The mix is a private playlist in your YouTube Music account; regenerate it any time for a new pick.")
        }
    }

    /// The slider works in 0–1; the mix stores whole percents.
    private var discoveryShare: Binding<Double> {
        Binding(
            get: { Double(self.mix.discoveryPercent) / 100 },
            set: { self.mix.discoveryPercent = Int(($0 * 100).rounded()) }
        )
    }

    @ViewBuilder
    private var resultsSection: some View {
        if self.isSearching, self.results.isEmpty {
            ProgressView().frame(maxWidth: .infinity)
        } else if self.results.isEmpty {
            ContentUnavailableView.search(text: self.query)
        } else {
            Section("Artists") {
                ForEach(self.results) { artist in
                    let mixArtist = MixArtist(artist)
                    MixArtistRow(artist: mixArtist, isSelected: self.mix.artists.contains { $0.id == mixArtist.id }) {
                        self.toggle(mixArtist)
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func toggle(_ artist: MixArtist) {
        Haptics.tap()
        if let index = self.mix.artists.firstIndex(where: { $0.id == artist.id }) {
            self.mix.artists.remove(at: index)
        } else {
            self.mix.artists.append(artist)
        }
    }

    /// Creates the playlist (new mix) or applies the changes, then optionally plays it.
    private func save(thenPlay: Bool) async {
        self.isSaving = true
        defer { self.isSaving = false }
        let library = self.environment.mixes
        do {
            var saved = self.mix
            if let original = self.original {
                try await library.update(self.mix, from: original, environment: self.environment)
            } else {
                saved = try await library.create(self.mix, environment: self.environment)
            }
            self.dismiss()
            if thenPlay { library.play(saved, environment: self.environment) }
        } catch {
            self.failureMessage = error.localizedDescription
        }
    }

    /// Mixes read back from a playlist description have names but no photos.
    private func loadArtistPhotos() async {
        for (index, artist) in self.mix.artists.enumerated() where artist.thumbnailURL == nil {
            guard let detail = try? await self.environment.client.getArtist(id: artist.id),
                  let url = detail.thumbnailURL ?? detail.artist.thumbnailURL,
                  self.mix.artists.indices.contains(index), self.mix.artists[index].id == artist.id
            else { continue }
            self.mix.artists[index] = MixArtist(id: artist.id, name: artist.name, thumbnailURL: url)
        }
    }

    private func search() async {
        let text = self.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            self.results = []
            return
        }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        self.isSearching = true
        defer { self.isSearching = false }
        let response = try? await self.environment.client.search(query: text, filter: .artists)
        guard !Task.isCancelled else { return }
        self.results = (response?.artists ?? []).filter(\.hasNavigableId)
    }

    /// Most frequent artists of the recent history first, then followed artists.
    private func loadSuggestions() async {
        guard self.environment.auth.state == .signedIn else { return }
        let history = await ArtistMixBuilder(client: self.environment.client).recentHistorySongs()
        var counts: [String: (artist: MixArtist, count: Int)] = [:]
        for song in history {
            for artist in song.artists where artist.hasNavigableId {
                let mixArtist = MixArtist(artist)
                counts[mixArtist.id, default: (mixArtist, 0)].count += 1
            }
        }
        let fromHistory = counts.values.sorted { $0.count > $1.count }.map(\.artist)
        let followed = ((try? await self.environment.client.getLibraryContent())?.artists ?? [])
            .filter(\.hasNavigableId).map(MixArtist.init)

        var seen = Set<String>()
        var merged: [MixArtist] = []
        for artist in fromHistory + followed where seen.insert(artist.id).inserted {
            // History entries often lack a photo; prefer the followed artist's.
            let photo = artist.thumbnailURL ?? followed.first { $0.id == artist.id }?.thumbnailURL
            merged.append(MixArtist(id: artist.id, name: artist.name, thumbnailURL: photo))
        }
        self.suggestions = Array(merged.prefix(30))
    }
}

/// Circular photo, name and a select / deselect control.
private struct MixArtistRow: View {
    let artist: MixArtist
    let isSelected: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: self.toggle) {
            HStack(spacing: 12) {
                ArtworkView(url: self.artist.thumbnailURL)
                    .frame(width: 44, height: 44)
                    .clipShape(Circle())
                Text(self.artist.name)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: self.isSelected ? "checkmark.circle.fill" : "plus.circle")
                    .font(.title3)
                    .foregroundStyle(self.isSelected ? AnyShapeStyle(Color.brand) : AnyShapeStyle(.secondary))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(self.isSelected ? .isSelected : [])
        .accessibilityHint(self.isSelected ? "Removes the artist from the mix" : "Adds the artist to the mix")
    }
}
