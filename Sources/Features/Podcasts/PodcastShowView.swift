import Observation
import SwiftUI

@MainActor
@Observable
final class PodcastShowModel {
    enum Phase: Equatable {
        case loading, loaded, failed(String)
    }

    let id: String
    private(set) var show: PodcastShow?
    private(set) var episodes: [PodcastEpisode] = []
    private(set) var isSaved = false
    private(set) var phase: Phase = .loading
    private(set) var isLoadingMore = false
    private(set) var isSaving = false
    private var continuationToken: String?
    private let client: YTMusicClient

    init(id: String, client: YTMusicClient) {
        self.id = id
        self.client = client
    }

    func load() async {
        if self.show == nil { self.phase = .loading }
        do {
            let detail = try await self.client.getPodcastShow(browseId: self.id)
            self.show = detail.show
            self.episodes = detail.episodes
            self.isSaved = detail.isSubscribed
            self.continuationToken = detail.continuationToken
            self.phase = .loaded
        } catch is CancellationError {
        } catch {
            self.phase = self.show == nil ? .failed(error.localizedDescription) : .loaded
        }
    }

    func loadMoreIfNeeded(after episode: PodcastEpisode) async {
        guard self.episodes.last?.id == episode.id, let token = self.continuationToken, !self.isLoadingMore else { return }
        self.isLoadingMore = true
        defer { self.isLoadingMore = false }
        guard let more = try? await self.client.getPodcastEpisodesContinuation(token: token) else {
            self.continuationToken = nil
            return
        }
        let known = Set(self.episodes.map(\.id))
        let title = self.show?.title
        self.episodes += more.episodes
            .filter { !known.contains($0.id) }
            .map { $0.withShow(title: title, browseId: self.id) }
        self.continuationToken = more.continuationToken
    }

    /// Saves or removes the show from the library; `false` when YouTube Music refused.
    func toggleSaved() async -> Bool {
        let target = !self.isSaved
        self.isSaving = true
        defer { self.isSaving = false }
        do {
            try await self.client.setPodcastSaved(target, showId: self.id)
            self.isSaved = target
            return true
        } catch {
            return false
        }
    }
}

/// A podcast show: header, play latest / save, then its episodes, newest first.
struct PodcastShowView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var model: PodcastShowModel?
    @State private var failureMessage: String?
    @State private var isDescriptionExpanded = false

    let id: String
    var fallbackTitle: String = ""
    var thumbnailURL: URL?

    private var isSignedIn: Bool { self.environment.auth.state == .signedIn }

    var body: some View {
        Group {
            if let model {
                self.content(model)
            } else {
                ProgressView()
            }
        }
        .navigationTitle(self.model?.show?.title.nilIfEmpty ?? self.fallbackTitle)
        .inlineNavigationTitle()
        .toolbar { self.toolbar }
        .alert("Podcast", isPresented: Binding(
            get: { self.failureMessage != nil },
            set: { if !$0 { self.failureMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(self.failureMessage ?? "")
        }
        .task {
            if self.model == nil { self.model = PodcastShowModel(id: self.id, client: self.environment.client) }
            if self.model?.show == nil { await self.model?.load() }
        }
    }

    @ViewBuilder
    private func content(_ model: PodcastShowModel) -> some View {
        switch model.phase {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .failed(message):
            LoadFailureView(message: message) { Task { await model.load() } }
        case .loaded:
            List {
                if let show = model.show {
                    Section {
                        if Platform.isMac {
                            self.macHeader(show, model: model)
                        } else {
                            self.header(show, model: model)
                        }
                    }
                    .listRowSeparator(.hidden)
                }
                Section {
                    if model.episodes.isEmpty {
                        Text("No episodes yet.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                    ForEach(model.episodes) { episode in
                        EpisodeRow(episode: episode)
                            .task { await model.loadMoreIfNeeded(after: episode) }
                    }
                    if model.isLoadingMore { ProgressView().frame(maxWidth: .infinity) }
                } header: {
                    if !model.episodes.isEmpty {
                        Text("Episodes")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.primary)
                            .textCase(nil)
                    }
                }
            }
            .listStyle(.plain)
            .contentMargins(.bottom, 24, for: .scrollContent)
            .refreshable { await model.load() }
        }
    }

    private func header(_ show: PodcastShow, model: PodcastShowModel) -> some View {
        VStack(spacing: 14) {
            ArtworkView(url: show.thumbnailURL ?? self.thumbnailURL)
                .frame(width: 220, height: 220)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: 18, y: 10)
                .padding(.top, 8)

            // The title lives in the navigation bar; this is the byline.
            if let author = show.author {
                Text(author)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            self.actions(model: model)

            if let description = show.description {
                self.descriptionText(description)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// macOS: artwork on the left, title and actions next to it, like playlists.
    private func macHeader(_ show: PodcastShow, model: PodcastShowModel) -> some View {
        HStack(alignment: .top, spacing: 24) {
            ArtworkView(url: show.thumbnailURL ?? self.thumbnailURL)
                .frame(width: 200, height: 200)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: 18, y: 10)

            VStack(alignment: .leading, spacing: 8) {
                Text("Podcast")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(show.title.nilIfEmpty ?? self.fallbackTitle)
                    .font(.system(size: 30, weight: .bold))
                    .lineLimit(2)
                    .textSelection(.enabled)
                if let author = show.author {
                    Text(author)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if let description = show.description {
                    self.descriptionText(description)
                        .frame(maxWidth: 560, alignment: .leading)
                }
                self.actions(model: model)
                    .frame(maxWidth: 320)
                    .padding(.top, 6)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 16)
    }

    private func actions(model: PodcastShowModel) -> some View {
        HStack(spacing: Platform.isMac ? 10 : 12) {
            Button {
                Haptics.tap()
                if let first = model.episodes.first { self.environment.player.play(videoId: first.id) }
            } label: {
                Label("Play Latest", systemImage: "play.fill")
            }
            .buttonStyle(PrimaryActionButtonStyle())
            .disabled(model.episodes.isEmpty)

            if self.isSignedIn {
                Button {
                    Task {
                        if await model.toggleSaved() {
                            self.environment.libraryRevision += 1
                        } else {
                            self.failureMessage = String(localized: "Couldn't update your library.")
                        }
                    }
                } label: {
                    if model.isSaving {
                        ProgressView()
                    } else if model.isSaved {
                        Label("Saved", systemImage: "bookmark.fill")
                    } else {
                        Label("Save", systemImage: "bookmark")
                    }
                }
                .buttonStyle(SecondaryActionButtonStyle())
                .disabled(model.isSaving)
                .accessibilityHint(model.isSaved ? Text("Removes the podcast from your library") : Text("Adds the podcast to your library"))
            }
        }
    }

    /// Long descriptions start folded to three lines; a tap unfolds them.
    private func descriptionText(_ description: String) -> some View {
        Text(description)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(self.isDescriptionExpanded ? nil : 3)
            .multilineTextAlignment(Platform.isMac ? .leading : .center)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { self.isDescriptionExpanded.toggle() } }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(self.isDescriptionExpanded ? Text("Shows less") : Text("Shows the full description"))
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if let playlistId = PodcastParser.playlistId(forShow: self.id),
           let url = URL(string: "https://music.youtube.com/playlist?list=\(playlistId)")
        {
            ToolbarItem(placement: .trailingBar) {
                ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
            }
        }
    }
}

// MARK: - Episode row

/// One episode: artwork, title, date · duration, a short description and how far it was played.
/// A tap plays it on its own (no radio queue for podcasts).
struct EpisodeRow: View {
    @Environment(AppEnvironment.self) private var environment

    let episode: PodcastEpisode
    /// Show name in the details line, for lists that mix shows (search, discovery).
    var showsShowTitle = false

    @State private var isHovering = false

    private var isCurrent: Bool { self.environment.player.identity.videoId == self.episode.id }
    private var isPlaying: Bool { self.isCurrent && self.environment.player.identity.isPlaying }

    var body: some View {
        Button {
            self.environment.player.play(videoId: self.episode.id)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                ArtworkView(url: self.episode.thumbnailURL)
                    .frame(width: Platform.isMac ? 56 : 64, height: Platform.isMac ? 56 : 64)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        if self.isCurrent {
                            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.black.opacity(0.45))
                            EqualizerView(isAnimating: self.isPlaying, color: .white).frame(width: 18, height: 16)
                        }
                    }
                VStack(alignment: .leading, spacing: 4) {
                    if let details = self.details {
                        Text(details)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text(self.episode.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(self.isCurrent ? Color.brand : Color.primary)
                        .lineLimit(2)
                    if let description = self.episode.description {
                        Text(description)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    self.progress
                }
                Spacer(minLength: 0)
                Menu {
                    self.menuItems
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: Platform.isMac ? 28 : 44)
                        .contentShape(Rectangle())
                }
                .menuIndicator(.hidden)
                .neutralMenuTint()
                .opacity(Platform.isMac && !self.isHovering ? 0 : 1)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, Platform.isMac ? 6 : 0)
            .background {
                if Platform.isMac, self.isHovering {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.primary.opacity(0.06))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { self.isHovering = $0 }
        .neutralMenuTint()
        .contextMenu { self.menuItems }
        .accessibilityElement(children: .combine)
        .accessibilityValue(self.progressDescription ?? "")
    }

    /// "Show · 3d ago · 36 min".
    private var details: String? {
        let parts = [self.showsShowTitle ? self.episode.showTitle : nil, self.episode.publishedDate, self.episode.formattedDuration]
        let text = parts.compactMap(\.self).filter { !$0.isEmpty }.joined(separator: " · ")
        return text.isEmpty ? nil : text
    }

    @ViewBuilder
    private var progress: some View {
        if self.episode.isPlayed {
            Label("Played", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
        } else if self.episode.playbackProgress > 0 {
            ProgressView(value: self.episode.playbackProgress)
                .tint(Color.brand)
                .frame(maxWidth: 160)
                .padding(.top, 2)
        }
    }

    private var progressDescription: String? {
        if self.episode.isPlayed { return String(localized: "Played") }
        guard self.episode.playbackProgress > 0 else { return nil }
        return self.episode.playbackProgress.formatted(.percent.precision(.fractionLength(0)))
    }

    @ViewBuilder
    private var menuItems: some View {
        Button("Play", systemImage: "play.fill") { self.environment.player.play(videoId: self.episode.id) }
        Button("Play Next", systemImage: "text.insert") { self.environment.player.playNext(videoId: self.episode.id) }
        Button("Add to Queue", systemImage: "text.append") { self.environment.player.addToQueue(videoId: self.episode.id) }
        if let url = URL(string: "https://music.youtube.com/watch?v=\(self.episode.id)") {
            ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
        }
    }
}

private extension String {
    var nilIfEmpty: String? { self.isEmpty ? nil : self }
}
