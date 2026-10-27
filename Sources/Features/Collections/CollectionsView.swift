import Observation
import SwiftUI

/// Library · Liked music · History. Signed-out users get a prompt instead of empty lists.
struct CollectionsView: View {
    enum Segment: String, CaseIterable, Identifiable {
        case library = "Library"
        case liked = "Liked music"
        case history = "History"
        case recap = "Recap"

        var id: String { self.rawValue }
    }

    @Environment(AppEnvironment.self) private var environment
    @State private var selection: Segment = .library
    @State private var history: BrowsePageModel?
    @State private var isCreatingPlaylist = false
    @State private var newPlaylistTitle = ""

    var body: some View {
        NavigationStack {
            Group {
                if self.environment.auth.state == .signedIn {
                    VStack(spacing: 0) {
                        Picker("Section", selection: self.$selection) {
                            ForEach(Segment.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal)
                        .padding(.bottom, 8)

                        switch self.selection {
                        case .library: LibraryContentView().id(self.environment.libraryRevision)
                        case .liked: LikedMusicView()
                        case .history:
                            if let history = self.history {
                                HistoryView(model: history)
                            } else {
                                ProgressView()
                            }
                        case .recap: RecapView()
                        }
                    }
                } else {
                    ContentUnavailableView {
                        Label("Your music", systemImage: "square.stack")
                    } description: {
                        Text("Sign in to see your library, liked songs and history.")
                    } actions: {
                        Button("Sign in") { self.environment.isLoginPresented = true }
                    }
                }
            }
            .navigationTitle("Collections")
            .entityDestinations()
            .toolbar {
                if self.environment.auth.state == .signedIn, self.selection == .library {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("New Playlist", systemImage: "plus") { self.isCreatingPlaylist = true }
                    }
                }
                SettingsToolbarButton()
            }
            .alert("New Playlist", isPresented: self.$isCreatingPlaylist) {
                TextField("Title", text: self.$newPlaylistTitle)
                Button("Create") {
                    let title = self.newPlaylistTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.newPlaylistTitle = ""
                    guard !title.isEmpty else { return }
                    Task {
                        _ = try? await self.environment.client.createPlaylist(title: title)
                        self.environment.libraryRevision += 1
                    }
                }
                Button("Cancel", role: .cancel) { self.newPlaylistTitle = "" }
            }
        }
        .task(id: self.selection) {
            guard self.selection == .history, self.environment.auth.state == .signedIn else { return }
            let model = self.history ?? BrowsePageModel(type: .history, client: self.environment.client)
            self.history = model
            await model.load(force: true)
        }
    }
}

// MARK: - History

/// Recently played, one section per period as YouTube Music groups them (Today, Yesterday,
/// This week, …). Songs play with their radio, like everywhere else outside a playlist.
struct HistoryView: View {
    @Environment(AppEnvironment.self) private var environment

    let model: BrowsePageModel

    var body: some View {
        switch self.model.phase {
        case .idle, .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .failed(message):
            LoadFailureView(message: message) { Task { await self.model.load(force: true) } }
        case .loaded:
            if self.model.sections.isEmpty {
                ContentUnavailableView("Nothing played yet.", systemImage: "clock")
            } else {
                List {
                    ForEach(self.model.sections) { section in
                        Section(section.title) {
                            // The same song can appear twice in a period.
                            ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
                                self.row(item)
                            }
                        }
                        .task { await self.model.loadMoreIfNeeded(after: section) }
                    }
                    if self.model.isLoadingMore {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                }
                .listStyle(.plain)
                .refreshable { await self.model.load(force: true) }
            }
        }
    }

    @ViewBuilder
    private func row(_ item: HomeSectionItem) -> some View {
        if case let .song(song) = item {
            TrackRow(song: song) { self.environment.player.startRadio(videoId: song.videoId) }
        } else {
            let entity = MediaEntity(item)
            MediaActions(entity: entity) { MediaRow(entity: entity) }
        }
    }
}

// MARK: - Library

@MainActor
@Observable
final class LibraryModel {
    enum Phase: Equatable {
        case loading, loaded, failed(String)
    }

    private(set) var content: PlaylistParser.LibraryContent?
    private(set) var phase: Phase = .loading
    private let client: YTMusicClient

    init(client: YTMusicClient) {
        self.client = client
    }

    func load() async {
        if self.content == nil { self.phase = .loading }
        do {
            self.content = try await self.client.getLibraryContent()
            self.phase = .loaded
        } catch is CancellationError {
        } catch {
            self.phase = self.content == nil ? .failed(error.localizedDescription) : .loaded
        }
    }
}

struct LibraryContentView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var model: LibraryModel?

    var body: some View {
        Group {
            if let model {
                switch model.phase {
                case .loading:
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                case let .failed(message):
                    LoadFailureView(message: message) { Task { await model.load() } }
                case .loaded:
                    if let content = model.content {
                        if content.playlists.isEmpty, content.albums.isEmpty, content.artists.isEmpty {
                            ContentUnavailableView("Your library is empty", systemImage: "music.note.list")
                        } else {
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 24) {
                                    if !content.playlists.isEmpty {
                                        ShelfView(title: "Playlists", entities: content.playlists.map(MediaEntity.init))
                                    }
                                    if !content.albums.isEmpty {
                                        ShelfView(title: "Albums", entities: content.albums.map(MediaEntity.init))
                                    }
                                    if !content.artists.isEmpty {
                                        ShelfView(title: "Artists", entities: content.artists.map(MediaEntity.init))
                                    }
                                }
                                .padding(.vertical)
                            }
                            .refreshable { await model.load() }
                        }
                    }
                }
            } else {
                ProgressView()
            }
        }
        .task {
            let model = self.model ?? LibraryModel(client: self.environment.client)
            self.model = model
            await model.load()
        }
    }
}

// MARK: - Liked music

@MainActor
@Observable
final class LikedMusicModel {
    enum Phase: Equatable {
        case loading, loaded, failed(String)
    }

    private(set) var songs: [Song] = []
    private(set) var phase: Phase = .loading
    private var token: String?
    private var isLoadingMore = false
    private let client: YTMusicClient

    init(client: YTMusicClient) {
        self.client = client
    }

    func load() async {
        if self.songs.isEmpty { self.phase = .loading }
        do {
            let response = try await self.client.getLikedSongs()
            self.songs = response.songs
            self.token = response.continuationToken
            self.phase = .loaded
        } catch is CancellationError {
        } catch {
            self.phase = self.songs.isEmpty ? .failed(error.localizedDescription) : .loaded
        }
    }

    func loadMoreIfNeeded(after song: Song) async {
        guard self.songs.last?.id == song.id, let token = self.token, !self.isLoadingMore else { return }
        self.isLoadingMore = true
        defer { self.isLoadingMore = false }
        guard let more = try? await self.client.getLikedSongsContinuation(token: token) else {
            self.token = nil
            return
        }
        self.songs += more.songs
        self.token = more.continuationToken
    }
}

struct LikedMusicView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var model: LikedMusicModel?

    var body: some View {
        Group {
            if let model {
                switch model.phase {
                case .loading:
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                case let .failed(message):
                    LoadFailureView(message: message) { Task { await model.load() } }
                case .loaded:
                    if model.songs.isEmpty {
                        ContentUnavailableView("No liked songs yet", systemImage: "heart")
                    } else {
                        List(model.songs) { song in
                            TrackRow(song: song) {
                                self.environment.player.play(videoId: song.videoId, playlistId: LikedMusicPlaylist.id)
                            }
                            .task { await model.loadMoreIfNeeded(after: song) }
                        }
                        .listStyle(.plain)
                        .refreshable { await model.load() }
                    }
                }
            } else {
                ProgressView()
            }
        }
        .task {
            let model = self.model ?? LikedMusicModel(client: self.environment.client)
            self.model = model
            await model.load()
        }
    }
}
