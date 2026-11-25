import SwiftUI

/// Creates or edits an artist mix: picked artists, suggestions (followed artists and the
/// history), artist search, and the options. Saving creates (or updates) the mix's private
/// YouTube Music playlist; "Play" saves and starts it.
///
/// iOS shows a navigation form with a bottom "Play" button; macOS shows a two-pane sheet
/// (`MacMixEditorView`) with the actions at the bottom trailing edge.
struct MixEditorView: View {
    @State private var model: MixEditorModel

    init(mix: ArtistMix? = nil) {
        self._model = State(initialValue: MixEditorModel(mix: mix))
    }

    var body: some View {
        #if os(macOS)
        MacMixEditorView(model: self.model)
        #else
        IOSMixEditorView(model: self.model)
        #endif
    }
}

#if os(iOS)
private struct IOSMixEditorView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: MixEditorModel

    var body: some View {
        NavigationStack {
            List {
                if self.model.query.isEmpty {
                    self.nameSection
                    self.optionsSection
                    self.artistsSection
                    self.suggestionsSection
                    if !self.model.isNew {
                        Section {
                            Button("Delete Mix", role: .destructive) { self.model.isConfirmingDelete = true }
                        }
                    }
                } else {
                    self.resultsSection
                }
            }
            .searchable(text: self.$model.query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search artists")
            .navigationTitle(self.model.isNew ? "New Mix" : "Edit Mix")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { self.dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if self.model.isSaving {
                        ProgressView()
                    } else {
                        Button("Save") { Task { await self.save(thenPlay: false) } }
                            .disabled(self.model.mix.artists.isEmpty)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if self.model.query.isEmpty {
                    Button {
                        Task { await self.save(thenPlay: true) }
                    } label: {
                        if self.model.isSaving {
                            ProgressView().tint(.white)
                        } else {
                            Label(self.model.isNew ? "Create and Play" : "Save and Play", systemImage: "play.fill")
                        }
                    }
                    .buttonStyle(PrimaryActionButtonStyle())
                    .disabled(!self.model.canSave)
                    .opacity(self.model.mix.artists.isEmpty ? 0.5 : 1)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(.bar)
                }
            }
            .mixEditorDialogs(model: self.model) { self.dismiss() }
            .interactiveDismissDisabled(self.model.isSaving)
            .task {
                await self.model.loadArtistPhotos(environment: self.environment)
                await self.model.loadSuggestions(environment: self.environment)
            }
            .task(id: self.model.query) { await self.model.search(environment: self.environment) }
        }
    }

    private func save(thenPlay: Bool) async {
        guard let saved = await self.model.save(environment: self.environment) else { return }
        self.dismiss()
        if thenPlay { self.environment.mixes.play(saved, environment: self.environment) }
    }

    // MARK: - Sections

    private var nameSection: some View {
        Section("Name") {
            TextField(self.model.namePlaceholder, text: self.$model.mix.name)
        }
    }

    @ViewBuilder
    private var artistsSection: some View {
        Section {
            if self.model.mix.artists.isEmpty {
                Text("Add artists from the suggestions or search for them.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(self.model.mix.artists) { artist in
                MixArtistRow(artist: artist, isSelected: true) { self.model.toggle(artist) }
            }
            .onDelete { self.model.removeArtists(atOffsets: $0) }
        } header: {
            Text("Artists (\(self.model.mix.artists.count))")
        }
    }

    @ViewBuilder
    private var suggestionsSection: some View {
        // Picked artists stay in place with a checkmark (the selection is the section above).
        if !self.model.suggestions.isEmpty {
            Section {
                ForEach(self.model.suggestions) { artist in
                    MixArtistRow(artist: artist, isSelected: self.model.isSelected(artist)) {
                        self.model.toggle(artist)
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
            Picker("Length", selection: self.$model.mix.length) {
                ForEach(ArtistMix.Length.allCases) { length in
                    Text("\(length.trackCount) songs").tag(length)
                }
            }
            Toggle("Include similar artists", isOn: self.$model.mix.includesSimilarArtists)
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("Discoveries") {
                    Text(self.model.mix.discoveryPercent, format: .percent)
                        .monospacedDigit()
                }
                Slider(value: self.$model.discoveryShare, in: 0 ... 1, step: 0.1) {
                    Text("Discoveries")
                } minimumValueLabel: {
                    Text(0, format: .percent)
                } maximumValueLabel: {
                    Text(100, format: .percent)
                }
                .tint(Color.brand)
                .accessibilityValue(Text(self.model.mix.discoveryPercent, format: .percent))
            }
            Toggle("Skip recently played", isOn: self.$model.mix.skipsRecentlyPlayed)
        } header: {
            Text("Options")
        } footer: {
            Text("Discoveries are lesser-known songs by these artists; the slider sets how much of the mix they make up. The mix is a private playlist in your YouTube Music account; regenerate it any time for a new pick.")
        }
    }

    @ViewBuilder
    private var resultsSection: some View {
        if self.model.isSearching, self.model.results.isEmpty {
            ProgressView().frame(maxWidth: .infinity)
        } else if self.model.results.isEmpty {
            ContentUnavailableView.search(text: self.model.query)
        } else {
            Section("Artists") {
                ForEach(self.model.results) { artist in
                    let mixArtist = MixArtist(artist)
                    MixArtistRow(artist: mixArtist, isSelected: self.model.isSelected(mixArtist)) {
                        self.model.toggle(mixArtist)
                    }
                }
            }
        }
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
#endif

extension View {
    /// The delete confirmation and the failure alert, shared by both editor layouts.
    func mixEditorDialogs(model: MixEditorModel, onDeleted: @escaping () -> Void) -> some View {
        self.modifier(MixEditorDialogs(model: model, onDeleted: onDeleted))
    }
}

private struct MixEditorDialogs: ViewModifier {
    @Environment(AppEnvironment.self) private var environment
    @Bindable var model: MixEditorModel
    let onDeleted: () -> Void

    func body(content: Content) -> some View {
        content
            .confirmationDialog("Delete this mix?", isPresented: self.$model.isConfirmingDelete, titleVisibility: .visible) {
                Button("Delete Mix", role: .destructive) {
                    Task {
                        if await self.model.delete(environment: self.environment) { self.onDeleted() }
                    }
                }
            } message: {
                Text("The playlist is deleted from your YouTube Music account.")
            }
            .alert("Mix", isPresented: Binding(
                get: { self.model.failureMessage != nil },
                set: { if !$0 { self.model.failureMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(self.model.failureMessage ?? "")
            }
    }
}
