import AppKit
import SwiftUI

/// The mix editor as a macOS sheet: the mix (name, options, picked artists) in a grouped form
/// on the left, an artist browser (search field, suggestions, results) on the right, and the
/// sheet's buttons at the bottom trailing edge, the default one bound to Return and Cancel to
/// Escape.
struct MacMixEditorView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: MixEditorModel

    var body: some View {
        VStack(spacing: 0) {
            self.header
            Divider()
            HStack(spacing: 0) {
                self.mixForm
                    .frame(width: 360)
                Divider()
                self.artistBrowser
                    .frame(maxWidth: .infinity)
            }
            Divider()
            self.footer
        }
        .frame(minWidth: 780, idealWidth: 840, minHeight: 560, idealHeight: 640)
        .mixEditorDialogs(model: self.model) { self.dismiss() }
        .interactiveDismissDisabled(self.model.isSaving)
        .task {
            await self.model.loadArtistPhotos(environment: self.environment)
            await self.model.loadSuggestions(environment: self.environment)
        }
        .task(id: self.model.query) { await self.model.search(environment: self.environment) }
    }

    // MARK: - Header and footer

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(self.model.isNew ? "New Mix" : "Edit Mix")
                .font(.headline)
            Text("Pick artists on the right, then set the options. The mix is saved as a private playlist in your YouTube Music account.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if !self.model.isNew {
                Button("Delete Mix…", role: .destructive) { self.model.isConfirmingDelete = true }
                    .disabled(self.model.isSaving)
            }
            Spacer()
            if self.model.isSaving {
                ProgressView()
                    .controlSize(.small)
            }
            Button("Cancel", role: .cancel) { self.dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Save") { Task { await self.save(thenPlay: false) } }
                .disabled(!self.model.canSave)
            Button(self.model.isNew ? "Create and Play" : "Save and Play") {
                Task { await self.save(thenPlay: true) }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!self.model.canSave)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Mix form

    private var mixForm: some View {
        Form {
            // Grouped forms right-align a labelled text field; the name reads better as a
            // full-width, leading-aligned field under a section header.
            Section("Name") {
                TextField("Name", text: self.$model.mix.name, prompt: Text(self.model.namePlaceholder))
                    .labelsHidden()
                    .multilineTextAlignment(.leading)
            }

            Section {
                Picker("Length", selection: self.$model.mix.length) {
                    ForEach(ArtistMix.Length.allCases) { length in
                        Text("\(length.trackCount) songs").tag(length)
                    }
                }
                Toggle("Include similar artists", isOn: self.$model.mix.includesSimilarArtists)
                LabeledContent {
                    HStack(spacing: 8) {
                        Slider(value: self.$model.discoveryShare, in: 0 ... 1, step: 0.1) {
                            Text("Discoveries")
                        }
                        .labelsHidden()
                        .tint(Color.brand)
                        .accessibilityValue(Text(self.model.mix.discoveryPercent, format: .percent))
                        Text(self.model.mix.discoveryPercent, format: .percent)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                    .frame(maxWidth: 160)
                } label: {
                    Text("Discoveries")
                    Text("Lesser-known songs by these artists")
                }
                Toggle("Skip recently played", isOn: self.$model.mix.skipsRecentlyPlayed)
            } header: {
                Text("Options")
            }

            Section {
                if self.model.mix.artists.isEmpty {
                    Text("Add artists from the suggestions or search for them.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(self.model.mix.artists) { artist in
                        MacPickedArtistRow(artist: artist) { self.model.toggle(artist) }
                    }
                }
            } header: {
                Text("Artists (\(self.model.mix.artists.count))")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Artist browser

    private var artistBrowser: some View {
        VStack(spacing: 0) {
            MacSearchField(text: self.$model.query, prompt: String(localized: "Search artists"))
                .padding(12)
            Divider()
            Group {
                if self.model.isSearchActive {
                    self.searchResults
                } else {
                    self.suggestionList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        if self.model.results.isEmpty {
            if self.model.isSearching {
                ProgressView().controlSize(.small)
            } else {
                ContentUnavailableView.search(text: self.model.query)
            }
        } else {
            List {
                Section("Artists") {
                    ForEach(self.model.results) { artist in
                        self.browserRow(MixArtist(artist))
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    @ViewBuilder
    private var suggestionList: some View {
        if !self.model.suggestions.isEmpty {
            List {
                Section {
                    ForEach(self.model.suggestions) { self.browserRow($0) }
                } header: {
                    Text("Suggestions")
                } footer: {
                    Text("From the artists you follow and your recent history.")
                }
            }
            .listStyle(.inset)
        } else if self.model.isLoadingSuggestions {
            ProgressView().controlSize(.small)
        } else {
            ContentUnavailableView(
                "Find Artists",
                systemImage: "music.mic",
                description: Text("Search for the artists you want in this mix.")
            )
        }
    }

    private func browserRow(_ artist: MixArtist) -> some View {
        MacBrowserArtistRow(artist: artist, isSelected: self.model.isSelected(artist)) {
            self.model.toggle(artist)
        }
    }

    // MARK: - Actions

    private func save(thenPlay: Bool) async {
        guard let saved = await self.model.save(environment: self.environment) else { return }
        self.dismiss()
        if thenPlay { self.environment.mixes.play(saved, environment: self.environment) }
    }
}

// MARK: - Rows

/// An artist in the mix: photo, name and a remove button.
private struct MacPickedArtistRow: View {
    let artist: MixArtist
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ArtworkView(url: self.artist.thumbnailURL)
                .frame(width: 28, height: 28)
                .clipShape(Circle())
            Text(self.artist.name)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button(action: self.remove) {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Remove from Mix")
            .accessibilityLabel(Text("Remove \(self.artist.name) from the mix"))
        }
        .contextMenu {
            Button("Remove from Mix", systemImage: "minus.circle", action: self.remove)
        }
    }
}

/// A suggestion or search result: clicking the row adds or removes the artist.
private struct MacBrowserArtistRow: View {
    let artist: MixArtist
    let isSelected: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: self.toggle) {
            HStack(spacing: 10) {
                ArtworkView(url: self.artist.thumbnailURL)
                    .frame(width: 32, height: 32)
                    .clipShape(Circle())
                Text(self.artist.name)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: self.isSelected ? "checkmark.circle.fill" : "plus.circle")
                    .imageScale(.large)
                    .foregroundStyle(self.isSelected ? AnyShapeStyle(Color.brand) : AnyShapeStyle(.secondary))
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(self.isSelected ? "Remove from Mix" : "Add to Mix")
        .accessibilityAddTraits(self.isSelected ? .isSelected : [])
        .accessibilityHint(self.isSelected ? "Removes the artist from the mix" : "Adds the artist to the mix")
    }
}

// MARK: - Search field

/// A native `NSSearchField` (magnifying glass, clear button), which SwiftUI only offers inside
/// a window toolbar through `.searchable`.
private struct MacSearchField: NSViewRepresentable {
    @Binding var text: String
    let prompt: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = self.prompt
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.searchChanged(_:))
        field.sendsSearchStringImmediately = true
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.text = self.$text
        if field.stringValue != self.text { field.stringValue = self.text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: self.$text) }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) { self.text = text }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            self.text.wrappedValue = field.stringValue
        }

        @objc func searchChanged(_ sender: NSSearchField) {
            self.text.wrappedValue = sender.stringValue
        }
    }
}
