import Observation
import SwiftUI

@MainActor
@Observable
final class ArtistDetailModel {
    enum Phase: Equatable {
        case loading, loaded, failed(String)
    }

    let id: String
    private let client: YTMusicClient
    private(set) var detail: ArtistDetail?
    private(set) var phase: Phase = .loading
    var isSubscribed = false

    init(id: String, client: YTMusicClient) {
        self.id = id
        self.client = client
    }

    func load() async {
        self.phase = .loading
        do {
            let detail = try await self.client.getArtist(id: self.id)
            self.detail = detail
            self.isSubscribed = detail.isSubscribed
            self.phase = .loaded
        } catch is CancellationError {
        } catch {
            self.phase = .failed(error.localizedDescription)
        }
    }

    func toggleSubscription() async {
        guard let channelId = self.detail?.channelId else { return }
        let target = !self.isSubscribed
        self.isSubscribed = target
        do {
            if target {
                try await self.client.subscribeToArtist(channelId: channelId)
            } else {
                try await self.client.unsubscribeFromArtist(channelId: channelId)
            }
        } catch {
            self.isSubscribed = !target
        }
    }
}

struct ArtistDetailView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var model: ArtistDetailModel?
    @State private var isAboutExpanded = false

    let id: String
    var fallbackName: String = ""

    var body: some View {
        Group {
            if let model {
                self.content(model)
            } else {
                ProgressView()
            }
        }
        .navigationTitle(self.model?.detail?.artist.name ?? self.fallbackName)
        .inlineNavigationTitle()
        .toolbar { self.artistToolbar }
        .task {
            if self.model == nil { self.model = ArtistDetailModel(id: self.id, client: self.environment.client) }
            if self.model?.detail == nil { await self.model?.load() }
        }
    }

    @ViewBuilder
    private func content(_ model: ArtistDetailModel) -> some View {
        switch model.phase {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .failed(message):
            LoadFailureView(message: message) { Task { await model.load() } }
        case .loaded:
            if let detail = model.detail {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 32) {
                        if Platform.isMac {
                            self.macHeader(detail, model: model)
                        } else {
                            self.header(detail, model: model)
                        }
                        self.topSongs(detail)
                        if detail.orderedSections.isEmpty {
                            // Same fallback as kaset: when the page has no ordered sections the
                            // typed collections are shown in a fixed order.
                            self.shelf("Albums", detail.albums.map(MediaEntity.init))
                            self.shelf("Singles & EPs", detail.singles.map(MediaEntity.init))
                            self.shelf("Playlists", detail.playlistsByArtist.map(MediaEntity.init))
                            self.shelf("Fans might also like", detail.relatedArtists.map(MediaEntity.init))
                        } else {
                            ForEach(detail.orderedSections) { section in
                                self.shelf(
                                    section.title, Self.entities(of: section),
                                    seeAll: section.moreEndpoint.map { SeeAllDestination(title: section.title, endpoint: $0) }
                                )
                            }
                        }
                        self.about(detail)
                    }
                    .padding(.vertical)
                }
            }
        }
    }

    @ViewBuilder
    private func shelf(_ title: String, _ entities: [MediaEntity], seeAll: SeeAllDestination? = nil) -> some View {
        if !entities.isEmpty { ShelfView(title: title, entities: entities, seeAll: seeAll) }
    }

    private func header(_ detail: ArtistDetail, model: ArtistDetailModel) -> some View {
        VStack(spacing: 14) {
            ArtworkView(url: detail.thumbnailURL ?? detail.artist.thumbnailURL)
                .frame(width: 200, height: 200)
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
                .padding(.top, 8)

            // The name lives in the navigation bar only; this is the secondary line.
            Text([detail.profileKind == .profile ? "Profile" : "Artist", detail.monthlyAudience]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                if detail.profileKind == .artist,
                   let seed = detail.mixPlaylistId ?? detail.songs.first.map({ "RDAMVM\($0.videoId)" })
                {
                    Button {
                        self.environment.player.playShuffled(videoId: nil, playlistId: seed)
                    } label: {
                        Label("Shuffle", systemImage: "shuffle")
                    }
                    .buttonStyle(PrimaryActionButtonStyle())
                }
                if let mix = detail.mixPlaylistId {
                    Button {
                        self.environment.player.play(videoId: detail.mixVideoId, playlistId: mix)
                    } label: {
                        Label("Mix", systemImage: "play.circle")
                    }
                    .buttonStyle(SecondaryActionButtonStyle())
                }
            }
        }
        .padding(.horizontal, 20)
    }

    /// macOS: round portrait on the left, the name big next to it, actions underneath.
    private func macHeader(_ detail: ArtistDetail, model: ArtistDetailModel) -> some View {
        HStack(alignment: .center, spacing: 28) {
            ArtworkView(url: detail.thumbnailURL ?? detail.artist.thumbnailURL)
                .frame(width: 190, height: 190)
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
            VStack(alignment: .leading, spacing: 8) {
                Text(detail.artist.name)
                    .font(.system(size: 34, weight: .bold))
                    .lineLimit(2)
                Text([detail.profileKind == .profile ? "Profile" : "Artist", detail.monthlyAudience]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    if detail.profileKind == .artist,
                       let seed = detail.mixPlaylistId ?? detail.songs.first.map({ "RDAMVM\($0.videoId)" })
                    {
                        Button {
                            self.environment.player.playShuffled(videoId: nil, playlistId: seed)
                        } label: {
                            Label("Shuffle", systemImage: "shuffle")
                        }
                        .buttonStyle(PrimaryActionButtonStyle())
                    }
                    if let mix = detail.mixPlaylistId {
                        Button {
                            self.environment.player.play(videoId: detail.mixVideoId, playlistId: mix)
                        } label: {
                            Label("Mix", systemImage: "play.circle")
                        }
                        .buttonStyle(SecondaryActionButtonStyle())
                    }
                }
                .frame(maxWidth: 300)
                .padding(.top, 6)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AdaptiveLayout.horizontalPadding)
        .padding(.top, 8)
    }

    /// Follow lives in the navigation bar.
    @ToolbarContentBuilder
    private var artistToolbar: some ToolbarContent {
        if let model = self.model, let detail = model.detail,
           detail.channelId != nil, self.environment.auth.state == .signedIn
        {
            ToolbarItem(placement: .trailingBar) {
                Button {
                    Task { await model.toggleSubscription() }
                } label: {
                    Text(model.isSubscribed
                        ? (detail.subscribedButtonText ?? "Following")
                        : (detail.unsubscribedButtonText ?? "Follow"))
                }
            }
        }
    }

    @ViewBuilder
    private func topSongs(_ detail: ArtistDetail) -> some View {
        if !detail.songs.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(detail.songsSectionTitle ?? "Top songs")
                        .font(.title2.weight(.bold))
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    if detail.hasMoreSongs, let browseId = detail.songsBrowseId {
                        NavigationLink("See all") {
                            ArtistSongsView(
                                browseId: browseId, params: detail.songsParams,
                                title: detail.songsSectionTitle ?? "Top songs"
                            )
                        }
                        .font(.subheadline)
                    }
                }
                .padding(.horizontal, AdaptiveLayout.horizontalPadding)
                // Two columns on the Mac window, one on the phone.
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 24, alignment: .top), count: Platform.isMac ? 2 : 1),
                    spacing: Platform.isMac ? 2 : 4
                ) {
                    ForEach(detail.songs.prefix(Platform.isMac ? 6 : 5)) { song in
                        TrackRow(song: song) {
                            self.environment.player.play(videoId: song.videoId, playlistId: "RDAMVM\(song.videoId)")
                        }
                    }
                }
                .padding(.horizontal, AdaptiveLayout.horizontalPadding)
            }
        }
    }

    @ViewBuilder
    private func about(_ detail: ArtistDetail) -> some View {
        if let description = detail.description, !description.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("About").font(.title2.weight(.bold)).accessibilityAddTraits(.isHeader)
                Text(description)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(self.isAboutExpanded ? nil : 4)
                Button(self.isAboutExpanded ? "Less" : "More") {
                    withAnimation { self.isAboutExpanded.toggle() }
                }
                .font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: Platform.isMac ? 760 : .infinity, alignment: .leading)
            .padding(.horizontal, AdaptiveLayout.horizontalPadding)
        }
    }

    private static func entities(of section: ArtistDetailSection) -> [MediaEntity] {
        switch section.content {
        case let .albums(albums): albums.map(MediaEntity.init)
        case let .playlists(playlists): playlists.map(MediaEntity.init)
        case let .artists(artists): artists.map(MediaEntity.init)
        }
    }
}

/// Everything by an artist, behind "See all" on the top songs shelf.
struct ArtistSongsView: View {
    @Environment(AppEnvironment.self) private var environment

    let browseId: String
    let params: String?
    let title: String

    @State private var songs: [Song] = []
    @State private var phase: Phase = .loading

    private enum Phase: Equatable {
        case loading, loaded, failed(String)
    }

    var body: some View {
        Group {
            switch self.phase {
            case .loading:
                ProgressView()
            case let .failed(message):
                LoadFailureView(message: message) { Task { await self.load() } }
            case .loaded:
                List(self.songs) { song in
                    TrackRow(song: song) {
                        self.environment.player.play(videoId: song.videoId, playlistId: "RDAMVM\(song.videoId)")
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(self.title)
        .inlineNavigationTitle()
        .task { await self.load() }
    }

    private func load() async {
        self.phase = .loading
        do {
            self.songs = try await self.environment.client.getArtistSongs(browseId: self.browseId, params: self.params)
            self.phase = .loaded
        } catch is CancellationError {
        } catch {
            self.phase = .failed(error.localizedDescription)
        }
    }
}
