import Observation
import SwiftUI

/// The podcasts discovery page (`FEmusic_podcasts`), with its continuation.
@MainActor
@Observable
final class PodcastsModel {
    enum Phase: Equatable {
        case idle, loading, loaded, failed(String)
    }

    private(set) var sections: [PodcastSection] = []
    private(set) var phase: Phase = .idle
    private(set) var isLoadingMore = false
    private var continuationToken: String?
    private var generation = 0
    private let client: YTMusicClient
    private let availability: PodcastsAvailability

    init(client: YTMusicClient, availability: PodcastsAvailability) {
        self.client = client
        self.availability = availability
    }

    func load(force: Bool = false) async {
        if !force, self.phase == .loaded || self.phase == .loading { return }
        self.generation &+= 1
        let generation = self.generation
        if self.sections.isEmpty { self.phase = .loading }
        do {
            let page = try await self.client.getPodcasts(forceRefresh: force)
            guard generation == self.generation else { return }
            self.sections = page.sections
            self.continuationToken = page.continuationToken
            self.phase = .loaded
        } catch is CancellationError {
            if self.phase == .loading { self.phase = .idle }
        } catch {
            guard generation == self.generation else { return }
            self.availability.record(error)
            if PodcastsAvailability.isRegionUnavailable(error) {
                // The entry disappears; a clean empty page is a softer landing than an error.
                self.sections = []
                self.phase = .loaded
            } else {
                self.phase = self.sections.isEmpty ? .failed(error.localizedDescription) : .loaded
            }
        }
    }

    func loadMoreIfNeeded(after section: PodcastSection) async {
        guard self.sections.last?.id == section.id, let token = self.continuationToken, !self.isLoadingMore else { return }
        self.isLoadingMore = true
        defer { self.isLoadingMore = false }
        let generation = self.generation
        guard let page = try? await self.client.getPodcastsContinuation(token: token),
              generation == self.generation
        else {
            self.continuationToken = nil
            return
        }
        let known = Set(self.sections.map(\.id))
        self.sections += page.sections.filter { !known.contains($0.id) }
        self.continuationToken = page.continuationToken
    }
}

/// Shelves of shows and episodes. Shows open their page; episodes play.
struct PodcastsView: View {
    @Environment(AppEnvironment.self) private var environment

    let model: PodcastsModel

    var body: some View {
        switch self.model.phase {
        case .idle, .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .failed(message):
            LoadFailureView(message: message) { Task { await self.model.load(force: true) } }
        case .loaded:
            if self.model.sections.isEmpty, self.environment.podcastsAvailability.isHidden {
                ContentUnavailableView(
                    "No podcasts here",
                    systemImage: "mic.slash",
                    description: Text("YouTube Music doesn't offer podcasts in your region. Podcasts still appear in search.")
                )
            } else if self.model.sections.isEmpty {
                ContentUnavailableView {
                    Label("No podcasts to show", systemImage: "mic")
                } description: {
                    Text("Search for a show to find podcasts.")
                } actions: {
                    Button("Try Again") { Task { await self.model.load(force: true) } }
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 32) {
                        ForEach(self.model.sections) { section in
                            ShelfView(title: section.title, entities: section.items.map(MediaEntity.init))
                                .task { await self.model.loadMoreIfNeeded(after: section) }
                        }
                        if self.model.isLoadingMore {
                            ProgressView().frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.vertical)
                }
                .refreshable { await self.model.load(force: true) }
            }
        }
    }
}
