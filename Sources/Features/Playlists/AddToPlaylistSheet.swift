import Observation
import SwiftUI

/// What is being added: one song, or the songs of a playlist/album cover.
enum AddToPlaylistSource: Equatable {
    case song(videoId: String, title: String?)
    case collection(id: String, title: String)

    var displayTitle: String? {
        switch self {
        case let .song(_, title): title
        case let .collection(_, title): title
        }
    }
}

@MainActor
@Observable
final class AddToPlaylistModel {
    enum Phase: Equatable {
        case loading, loaded, failed(String)
    }

    let source: AddToPlaylistSource
    private let client: YTMusicClient

    private(set) var menu: AddToPlaylistMenu?
    private(set) var options: [AddToPlaylistOption] = []
    private(set) var phase: Phase = .loading
    /// Playlists that now contain the song(s) (already did, or added in this sheet).
    private(set) var added: Set<String> = []
    private(set) var busyId: String?
    private var videoIds: [String] = []
    var message: String?

    init(source: AddToPlaylistSource, client: YTMusicClient) {
        self.source = source
        self.client = client
    }

    /// Songs to add. A cover is resolved to its tracks first.
    private func resolveVideoIds() async throws -> [String] {
        if !self.videoIds.isEmpty { return self.videoIds }
        switch self.source {
        case let .song(videoId, _):
            self.videoIds = [videoId]
        case let .collection(id, _):
            let detail = try await self.client.getPlaylist(id: id).detail
            self.videoIds = detail.tracks.filter(\.isPlayable).map(\.videoId)
        }
        return self.videoIds
    }

    func load() async {
        if self.options.isEmpty { self.phase = .loading }
        do {
            let ids = try await self.resolveVideoIds()
            guard let first = ids.first else {
                self.phase = .failed("This has no songs to add.")
                return
            }
            let menu = try await self.client.getAddToPlaylistOptions(videoId: first)
            self.menu = menu
            self.options = menu.options
            if ids.count == 1 { self.added = Set(menu.options.filter(\.isSelected).map(\.playlistId)) }
            self.phase = .loaded
        } catch is CancellationError {
        } catch {
            self.phase = .failed(error.localizedDescription)
        }
    }

    func add(to option: AddToPlaylistOption) async {
        guard !self.added.contains(option.playlistId), self.busyId == nil else { return }
        self.busyId = option.playlistId
        defer { self.busyId = nil }
        do {
            let ids = try await self.resolveVideoIds()
            try await self.client.addSongsToPlaylist(videoIds: ids, playlistId: option.playlistId)
            self.added.insert(option.playlistId)
            self.message = "Added to \(option.title)"
        } catch {
            self.message = "Couldn't add: \(error.localizedDescription)"
        }
    }

    /// Creates a playlist that starts with the songs, shows it straight away, then reloads the
    /// list from the server once it has had time to catch up.
    func create(title: String, privacy: PlaylistPrivacyStatus) async -> Bool {
        do {
            let ids = try await self.resolveVideoIds()
            let id = try await self.client.createPlaylist(title: title, privacyStatus: privacy, videoIds: ids)
            let option = AddToPlaylistOption(
                playlistId: id, title: title, subtitle: nil, thumbnailURL: nil,
                isSelected: true, privacyStatus: privacy
            )
            self.options.insert(option, at: 0)
            self.added.insert(id)
            self.message = "Created \(title)"
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                await self?.reloadKeepingLocal(newId: id)
            }
            return true
        } catch {
            self.message = "Couldn't create the playlist: \(error.localizedDescription)"
            return false
        }
    }

    /// Merges the server's list with the playlist we just created, which the server may not
    /// list yet.
    private func reloadKeepingLocal(newId: String) async {
        guard let first = self.videoIds.first,
              let menu = try? await self.client.getAddToPlaylistOptions(videoId: first)
        else { return }
        var options = menu.options
        if !options.contains(where: { $0.playlistId == newId }),
           let local = self.options.first(where: { $0.playlistId == newId })
        {
            options.insert(local, at: 0)
        }
        self.menu = menu
        self.options = options
        if self.videoIds.count == 1 {
            self.added.formUnion(menu.options.filter(\.isSelected).map(\.playlistId))
        }
    }
}

/// "Add to playlist": the user's playlists with a checkmark where the song already is, and a
/// way to create a new playlist that starts with this song.
struct AddToPlaylistSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    let source: AddToPlaylistSource

    @State private var model: AddToPlaylistModel?
    @State private var isCreating = false
    @State private var newTitle = ""
    @State private var newPrivacy: PlaylistPrivacyStatus = .private

    var body: some View {
        self.chrome
            .overlay(alignment: .bottom) {
                if let message = self.model?.message {
                    Text(message)
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .glassEffect(.regular, in: .capsule)
                        .padding(.bottom, Platform.isMac ? 64 : 16)
                        .task {
                            try? await Task.sleep(for: .seconds(2.5))
                            self.model?.message = nil
                        }
                }
            }
        .adaptiveSheetSize()
        .task {
            let model = self.model ?? AddToPlaylistModel(source: self.source, client: self.environment.client)
            self.model = model
            await model.load()
        }
        .alert("New Playlist", isPresented: self.$isCreating) {
            TextField("Title", text: self.$newTitle)
            Button("Create") {
                let title = self.newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                self.newTitle = ""
                guard !title.isEmpty, let model else { return }
                Task {
                    if await model.create(title: title, privacy: self.newPrivacy) {
                        self.environment.libraryRevision += 1
                    }
                }
            }
            Button("Cancel", role: .cancel) { self.newTitle = "" }
        } message: {
            Text("The playlist starts with \(self.source.displayTitle ?? "this song").")
        }
    }

    /// iOS: a navigation sheet with the close button. macOS: a sheet with its title in the
    /// content and the actions at the bottom, New Playlist… on the leading side, Done (Return)
    /// on the trailing side.
    @ViewBuilder
    private var chrome: some View {
        #if os(iOS)
        NavigationStack {
            self.loadedContent
                .navigationTitle("Add to Playlist")
                .inlineNavigationTitle()
                .toolbar { SheetCloseButton { self.dismiss() } }
        }
        #else
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Add to Playlist").font(.headline)
                if let title = self.source.displayTitle {
                    Text(title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            Divider()
            self.loadedContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack(spacing: 12) {
                Button("New Playlist…") { self.isCreating = true }
                    .disabled(self.model?.phase != .loaded)
                self.privacyPicker
                    .fixedSize()
                Spacer()
                Button("Done") { self.dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        #endif
    }

    @ViewBuilder
    private var loadedContent: some View {
        if let model {
            self.content(model)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var privacyPicker: some View {
        Picker("Privacy", selection: self.$newPrivacy) {
            Text("Private").tag(PlaylistPrivacyStatus.private)
            Text("Unlisted").tag(PlaylistPrivacyStatus.unlisted)
            Text("Public").tag(PlaylistPrivacyStatus.public)
        }
        .pickerStyle(.menu)
    }

    @ViewBuilder
    private func content(_ model: AddToPlaylistModel) -> some View {
        switch model.phase {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .failed(message):
            LoadFailureView(message: message) { Task { await model.load() } }
        case .loaded:
            List {
                // macOS has these in the sheet's bottom bar.
                if !Platform.isMac {
                    Section {
                        Button {
                            self.isCreating = true
                        } label: {
                            Label("New Playlist", systemImage: "plus.circle.fill")
                        }
                        self.privacyPicker
                    }
                }
                Section("Your playlists") {
                    ForEach(model.options) { option in
                        Button {
                            Task { await model.add(to: option) }
                        } label: {
                            HStack(spacing: 12) {
                                ArtworkView(url: option.thumbnailURL)
                                    .frame(width: 44, height: 44)
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.title).foregroundStyle(.primary).lineLimit(1)
                                    if let subtitle = option.subtitle {
                                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                Spacer()
                                if model.busyId == option.playlistId {
                                    ProgressView().controlSize(.small)
                                } else if model.added.contains(option.playlistId) {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.brand)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(model.added.contains(option.playlistId))
                    }
                }
            }
            #if os(macOS)
            .listStyle(.inset)
            #endif
        }
    }
}

extension View {
    /// Presents the add-to-playlist sheet for a song.
    func addToPlaylistSheet(isPresented: Binding<Bool>, videoId: String, title: String?) -> some View {
        self.sheet(isPresented: isPresented) {
            AddToPlaylistSheet(source: .song(videoId: videoId, title: title))
        }
    }

    /// Presents the add-to-playlist sheet for every song of a playlist or album.
    func addToPlaylistSheet(isPresented: Binding<Bool>, collectionId: String, title: String) -> some View {
        self.sheet(isPresented: isPresented) {
            AddToPlaylistSheet(source: .collection(id: collectionId, title: title))
        }
    }
}
