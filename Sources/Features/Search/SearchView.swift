import Observation
import SwiftUI

@MainActor
@Observable
final class SearchViewModel {
    enum Phase: Equatable {
        case idle, loading, loaded, failed(String)
    }

    /// Results for one kind: the first page plus where the next one starts.
    struct Bucket {
        var items: [SearchResultItem] = []
        var token: String?
        var phase: Phase = .idle
    }

    var query = ""
    var scope: SearchFilter = .all
    private(set) var suggestions: [SearchSuggestion] = []
    private(set) var submittedQuery = ""
    private(set) var buckets: [SearchFilter: Bucket] = [:]
    private(set) var recents: [String]
    private(set) var isLoadingMore = false

    private let client: YTMusicClient
    private static let recentsKey = "search.recents"

    init(client: YTMusicClient) {
        self.client = client
        self.recents = UserDefaults.standard.stringArray(forKey: Self.recentsKey) ?? []
    }

    var hasSubmitted: Bool { !self.submittedQuery.isEmpty }
    var current: Bucket { self.buckets[self.scope] ?? Bucket() }

    /// Kinds worth offering: "All" always, the others once the all-results contain them.
    var availableScopes: [SearchFilter] {
        let all = self.buckets[.all]?.items ?? []
        let present = Set(all.compactMap(Self.filter(for:)))
        return SearchFilter.allCases.filter { $0 == .all || present.contains($0) || $0 == self.scope }
    }

    // MARK: Suggestions and recents

    func updateSuggestions() async {
        let text = self.query.trimmingCharacters(in: .whitespaces)
        // The text of the search on screen needs no suggestions: they would cover its results.
        guard !text.isEmpty, text != self.submittedQuery else {
            self.suggestions = []
            return
        }
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        let fetched = (try? await self.client.getSearchSuggestions(query: text)) ?? []
        // A search submitted while this request was in flight owns the screen now.
        guard !Task.isCancelled, text != self.submittedQuery else { return }
        self.suggestions = fetched
    }

    func removeRecent(_ text: String) {
        self.recents.removeAll { $0 == text }
        UserDefaults.standard.set(self.recents, forKey: Self.recentsKey)
    }

    func clearRecents() {
        self.recents = []
        UserDefaults.standard.removeObject(forKey: Self.recentsKey)
    }

    private func remember(_ text: String) {
        self.recents.removeAll { $0.caseInsensitiveCompare(text) == .orderedSame }
        self.recents.insert(text, at: 0)
        self.recents = Array(self.recents.prefix(10))
        UserDefaults.standard.set(self.recents, forKey: Self.recentsKey)
    }

    // MARK: Searching

    func submit(_ text: String? = nil) async {
        let text = (text ?? self.query).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        self.query = text
        self.submittedQuery = text
        self.suggestions = []
        self.buckets = [:]
        self.scope = .all
        self.remember(text)
        await self.load(.all)
    }

    func clearResults() {
        self.submittedQuery = ""
        self.buckets = [:]
        self.scope = .all
    }

    func select(_ scope: SearchFilter) async {
        self.scope = scope
        if self.buckets[scope] == nil { await self.load(scope) }
    }

    private func load(_ scope: SearchFilter) async {
        let text = self.submittedQuery
        self.buckets[scope] = Bucket(items: [], token: nil, phase: .loading)
        do {
            let response = try await self.client.search(query: text, filter: scope)
            guard text == self.submittedQuery else { return }
            self.buckets[scope] = Bucket(items: response.allItems, token: response.continuationToken, phase: .loaded)
        } catch is CancellationError {
            if self.buckets[scope]?.phase == .loading { self.buckets[scope] = nil }
        } catch {
            guard text == self.submittedQuery else { return }
            self.buckets[scope] = Bucket(items: [], token: nil, phase: .failed(error.localizedDescription))
        }
    }

    func retry() async {
        await self.load(self.scope)
    }

    /// Next page of a filtered list when its last row appears.
    func loadMoreIfNeeded(after item: SearchResultItem) async {
        let scope = self.scope
        guard scope != .all, !self.isLoadingMore,
              let bucket = self.buckets[scope], bucket.items.last?.id == item.id,
              let token = bucket.token
        else { return }
        self.isLoadingMore = true
        defer { self.isLoadingMore = false }
        guard let page = try? await self.client.getSearchContinuation(token: token) else {
            self.buckets[scope]?.token = nil
            return
        }
        let known = Set(bucket.items.map(\.id))
        self.buckets[scope]?.items += page.allItems.filter { !known.contains($0.id) }
        self.buckets[scope]?.token = page.continuationToken
    }

    // MARK: Grouping

    static func filter(for item: SearchResultItem) -> SearchFilter? {
        switch item {
        case .song: .songs
        case .video: .videos
        case .album, .audiobook: .albums
        case .artist, .profile: .artists
        case .playlist: .playlists
        case .podcastShow, .podcastEpisode: nil
        }
    }

    /// The "All" tab: results grouped by kind, server order kept inside each group.
    var groupedAll: [(filter: SearchFilter, items: [SearchResultItem])] {
        let items = self.buckets[.all]?.items ?? []
        return [SearchFilter.songs, .artists, .albums, .playlists, .videos].compactMap { filter in
            let matching = items.filter { Self.filter(for: $0) == filter }
            return matching.isEmpty ? nil : (filter, matching)
        }
    }
}

struct SearchView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var model: SearchViewModel?

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    SearchContent(model: model)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Search")
            .entityDestinations()
            .toolbar { SettingsToolbarButton() }
        }
        .task {
            if self.model == nil { self.model = SearchViewModel(client: self.environment.client) }
        }
    }
}

private struct SearchContent: View {
    @Environment(AppEnvironment.self) private var environment
    @Bindable var model: SearchViewModel
    @FocusState private var isSearchFocused: Bool

    /// Runs a search and puts the keyboard away so the results are visible.
    private func search(_ text: String?) {
        self.isSearchFocused = false
        Task { await self.model.submit(text) }
    }

    var body: some View {
        Group {
            if !self.model.hasSubmitted {
                self.idle
            } else {
                self.results
            }
        }
        .searchable(text: self.$model.query, prompt: "Songs, albums, artists")
        .searchFocused(self.$isSearchFocused)
        .searchSuggestions {
            // A tap searches right away (as in Apple Music). `searchCompletion` would only
            // copy the text into the field and show the suggestions for it.
            ForEach(self.model.suggestions) { suggestion in
                Button {
                    self.search(suggestion.query)
                } label: {
                    Label(suggestion.query, systemImage: "magnifyingglass")
                }
            }
        }
        .onSubmit(of: .search) { self.search(nil) }
        .onChange(of: self.model.query) { _, text in
            if text.isEmpty { self.model.clearResults() }
        }
        .task(id: self.model.query) { await self.model.updateSuggestions() }
    }

    // MARK: Idle: recent searches

    @ViewBuilder
    private var idle: some View {
        if self.model.recents.isEmpty {
            ContentUnavailableView(
                "Search YouTube Music", systemImage: "magnifyingglass",
                description: Text("Songs, albums, artists, playlists and videos.")
            )
        } else {
            List {
                Section {
                    ForEach(self.model.recents, id: \.self) { recent in
                        Button {
                            Task { await self.model.submit(recent) }
                        } label: {
                            Label(recent, systemImage: "clock.arrow.circlepath")
                                .foregroundStyle(.primary)
                        }
                        .swipeActions {
                            Button("Remove", role: .destructive) { self.model.removeRecent(recent) }
                        }
                    }
                } header: {
                    HStack {
                        Text("Recent searches").font(.headline).textCase(nil)
                        Spacer()
                        Button("Clear") { self.model.clearRecents() }
                            .font(.subheadline)
                            .textCase(nil)
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    // MARK: Results

    private var results: some View {
        VStack(spacing: 0) {
            self.scopePicker
            if self.model.scope != .all {
                self.scopeTitle
            }
            switch self.model.current.phase {
            case .idle, .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .failed(message):
                LoadFailureView(message: message) { Task { await self.model.retry() } }
            case .loaded:
                if self.model.current.items.isEmpty {
                    ContentUnavailableView.search(text: self.model.submittedQuery)
                } else if self.model.scope == .all {
                    self.groupedList
                } else {
                    self.flatList
                }
            }
        }
    }

    /// Segmented control with symbols only: six titles would not fit one line. The selected
    /// kind's name is announced to VoiceOver and shown as the list's heading.
    private var scopePicker: some View {
        Picker("Kind", selection: Binding(
            get: { self.model.scope },
            set: { newValue in Task { await self.model.select(newValue) } }
        )) {
            ForEach(self.model.availableScopes) { filter in
                Image(systemName: filter.symbol)
                    .accessibilityLabel(filter.title)
                    .tag(filter)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    /// The picker is icon-only, so the selected kind is named right below it.
    private var scopeTitle: some View {
        Text(self.model.scope.title)
            .font(.title2.weight(.bold))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 6)
            .padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }

    private var groupedList: some View {
        List {
            ForEach(self.model.groupedAll, id: \.filter) { group in
                Section {
                    ForEach(group.items.prefix(5)) { item in self.row(item) }
                    if group.items.count > 5 {
                        Button {
                            Task { await self.model.select(group.filter) }
                        } label: {
                            HStack {
                                Text("See all")
                                Spacer()
                                Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                            }
                            .font(.subheadline.weight(.semibold))
                        }
                    }
                } header: {
                    Label(group.filter.title, systemImage: group.filter.symbol)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.primary)
                        .textCase(nil)
                }
            }
        }
        .listStyle(.plain)
    }

    private var flatList: some View {
        List {
            ForEach(self.model.current.items) { item in
                self.row(item)
                    .task { await self.model.loadMoreIfNeeded(after: item) }
            }
            if self.model.isLoadingMore {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .listStyle(.plain)
    }

    @ViewBuilder
    private func row(_ item: SearchResultItem) -> some View {
        switch item {
        case let .song(song), let .video(song):
            TrackRow(song: song) {
                self.environment.player.play(videoId: song.videoId, playlistId: "RDAMVM\(song.videoId)")
            }
        default:
            let entity = MediaEntity(item)
            MediaActions(entity: entity) { MediaRow(entity: entity) }
        }
    }
}
