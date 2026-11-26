import Observation
import SwiftUI

/// The Podcasts page. YouTube Music's own podcasts page is not offered on every account
/// (it answers 404 and the web client redirects `/podcasts` to Home), so the page is put
/// together from what answers:
///
/// 1. the shows saved to the library (signed in),
/// 2. YouTube Music's podcasts page, when it exists for this account, or else
/// 3. the podcast shelves of Home (personal suggestions) and Explore (popular episodes).
///
/// A shelf with nothing in it is never shown.
@MainActor
@Observable
final class PodcastsModel {
    enum Phase: Equatable {
        case idle, loading, loaded, failed(String)
    }

    private(set) var sections: [PodcastSection] = []
    private(set) var phase: Phase = .idle
    private(set) var isLoadingMore = false
    /// Next batch of YouTube Music's podcasts page, when that page is the source.
    private var continuationToken: String?
    private var generation = 0
    private let client: YTMusicClient
    private let isSignedIn: @MainActor () -> Bool

    init(client: YTMusicClient, isSignedIn: @escaping @MainActor () -> Bool) {
        self.client = client
        self.isSignedIn = isSignedIn
    }

    func load(force: Bool = false) async {
        if !force, self.phase == .loaded || self.phase == .loading { return }
        self.generation &+= 1
        let generation = self.generation
        if self.sections.isEmpty { self.phase = .loading }

        async let savedShows = self.savedShows(force: force)
        async let officialPage = self.officialPage(force: force)
        let saved = await savedShows
        let (official, failure) = await officialPage

        var composed: [PodcastSection] = []
        if !saved.isEmpty {
            composed.append(PodcastSection(
                id: "saved-podcasts", title: String(localized: "Your podcasts"), items: saved.map(PodcastSectionItem.show)
            ))
        }
        var token: String?
        if let official, !official.sections.isEmpty {
            composed += official.sections
            token = official.continuationToken
        } else {
            // Personal suggestions first, then what is popular.
            async let home = try? self.client.podcastShelves(of: .home, forceRefresh: force)
            async let explore = try? self.client.podcastShelves(of: .explore, forceRefresh: force)
            composed += (await home ?? []) + (await explore ?? [])
        }

        guard generation == self.generation, !Task.isCancelled else {
            if self.phase == .loading { self.phase = .idle }
            return
        }
        self.sections = Self.withoutEmptyOrDuplicate(composed)
        self.continuationToken = token
        if self.sections.isEmpty, let failure {
            self.phase = .failed(failure.localizedDescription)
        } else {
            self.phase = .loaded
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
        self.sections = Self.withoutEmptyOrDuplicate(self.sections + page.sections)
        self.continuationToken = page.continuationToken
    }

    private func savedShows(force: Bool) async -> [PodcastShow] {
        guard self.isSignedIn() else { return [] }
        return (try? await self.client.getSavedPodcasts(forceRefresh: force)) ?? []
    }

    /// YouTube Music's podcasts page, `nil` where it does not exist (404). Another failure is
    /// returned too, to be shown if nothing else loads.
    private func officialPage(force: Bool) async -> (PodcastParser.DiscoveryPage?, Error?) {
        do {
            return (try await self.client.getPodcasts(forceRefresh: force), nil)
        } catch {
            let isExpected = Self.isNotFound(error) || error is CancellationError
            return (nil, isExpected ? nil : error)
        }
    }

    nonisolated static func isNotFound(_ error: Error) -> Bool {
        if case let .apiError(_, code) = error as? YTMusicError { return code == 404 }
        return false
    }

    /// Drops shelves with no items, and shelves that repeat one already shown (same title).
    nonisolated static func withoutEmptyOrDuplicate(_ sections: [PodcastSection]) -> [PodcastSection] {
        var seenIds = Set<String>()
        var seenTitles = Set<String>()
        return sections.filter { section in
            guard !section.items.isEmpty, seenIds.insert(section.id).inserted else { return false }
            let title = section.title.lowercased()
            return title.isEmpty || seenTitles.insert(title).inserted
        }
    }
}

/// Shelves of shows and episodes. Shows open their page; episodes play.
struct PodcastsView: View {
    @Environment(AppEnvironment.self) private var environment

    let model: PodcastsModel

    var body: some View {
        Group {
            switch self.model.phase {
            case .idle, .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .failed(message):
                LoadFailureView(message: message) { Task { await self.model.load(force: true) } }
            case .loaded:
                if self.model.sections.isEmpty {
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
        // A show saved or removed on its page: "Your podcasts" follows.
        .onChange(of: self.environment.libraryRevision) {
            Task { await self.model.load(force: true) }
        }
    }
}
