import Observation
import SwiftUI

/// One paginated browse surface (Home, Explore, Charts, Moods, New releases, History).
@MainActor
@Observable
final class BrowsePageModel {
    enum Phase: Equatable {
        case idle, loading, loaded, failed(String)
    }

    let type: PaginatedContentType
    private(set) var sections: [HomeSection] = []
    private(set) var phase: Phase = .idle
    private(set) var isLoadingMore = false

    private let client: YTMusicClient

    init(type: PaginatedContentType, client: YTMusicClient) {
        self.type = type
        self.client = client
    }

    var hasMore: Bool { self.client.hasMore(self.type) }

    /// Browse ids of the shortcut buttons YouTube Music puts on its Explore page. They point at
    /// surfaces that already are Discover segments (Podcasts included), so they are dropped here.
    private static let shortcutBrowseIds: Set<String> = [
        "FEmusic_moods_and_genres", "FEmusic_charts", "FEmusic_new_releases", "FEmusic_explore",
    ].union(PodcastParser.knownDiscoveryBrowseIds)

    /// Explore repeats the chart shelves that already have their own Discover segment.
    private func filtered(_ sections: [HomeSection]) -> [HomeSection] {
        Self.withoutShortcuts(sections, dropsCharts: self.type == .explore)
    }

    private static func withoutShortcuts(_ sections: [HomeSection], dropsCharts: Bool) -> [HomeSection] {
        sections.compactMap { section in
            if dropsCharts, section.isChart { return nil }
            let items = section.items.filter { item in
                guard case let .playlist(playlist) = item else { return true }
                let browseId = playlist.resolvedMoodCategoryEndpoint?.browseId ?? playlist.id
                return !Self.shortcutBrowseIds.contains(browseId)
            }
            guard !items.isEmpty else { return nil }
            return items.count == section.items.count
                ? section
                : HomeSection(
                    id: section.id, title: section.title, items: items,
                    isChart: section.isChart, moreEndpoint: section.moreEndpoint
                )
        }
    }

    func load(force: Bool = false) async {
        if self.phase == .loading { return }
        if !force, self.phase == .loaded { return }
        if self.sections.isEmpty { self.phase = .loading }
        do {
            let response = try await self.client.page(self.type, forceRefresh: force)
            self.sections = self.filtered(response.sections)
            self.phase = .loaded
        } catch is CancellationError {
            if self.sections.isEmpty { self.phase = .idle }
        } catch {
            self.phase = self.sections.isEmpty ? .failed(error.localizedDescription) : .loaded
        }
    }

    func loadMoreIfNeeded(after section: HomeSection) async {
        guard self.sections.last?.id == section.id, self.hasMore, !self.isLoadingMore else { return }
        self.isLoadingMore = true
        defer { self.isLoadingMore = false }
        guard let more = try? await self.client.continuation(for: self.type) else { return }
        let known = Set(self.sections.map(\.id))
        self.sections += self.filtered(more.filter { !known.contains($0.id) })
    }
}

/// Shelves for a `BrowsePageModel`; songs-only sections render as a list-like grid of cards.
/// `header` scrolls above the sections (Home puts the user's mixes there).
struct BrowsePageView<Header: View>: View {
    let model: BrowsePageModel
    var emptyMessage = "Nothing here yet."
    @ViewBuilder var header: Header

    var body: some View {
        switch self.model.phase {
        case .idle, .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .failed(message):
            LoadFailureView(message: message) { Task { await self.model.load(force: true) } }
        case .loaded:
            if self.model.sections.isEmpty {
                ContentUnavailableView(self.emptyMessage, systemImage: "tray")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 32) {
                        self.header
                        ForEach(self.model.sections) { section in
                            ShelfView(section: section)
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

extension BrowsePageView where Header == EmptyView {
    init(model: BrowsePageModel, emptyMessage: String = "Nothing here yet.") {
        self.init(model: model, emptyMessage: emptyMessage) { EmptyView() }
    }
}

/// Titled shelf. Mood / genre sections are a grid of chips (3 to 4 columns depending on the
/// width); everything else is a horizontally scrolling row of artwork cards.
struct ShelfView: View {
    let title: String
    let entities: [MediaEntity]
    /// Shown as a "See all" link next to the title.
    var seeAll: SeeAllDestination?

    private static let chipMinimumWidth: CGFloat = AdaptiveLayout.chipMinimumWidth
    private static let chipSpacing: CGFloat = 10
    private static let collapsedRows = 3

    @State private var isExpanded = false
    @State private var gridWidth: CGFloat = 0
    /// Card the row is scrolled to, and the row's width (macOS paging arrows).
    @State private var scrolledID: MediaEntity.ID?
    @State private var rowWidth: CGFloat = 0

    /// How many chips fit on a line, matching what the adaptive grid will lay out.
    private var columns: Int {
        guard self.gridWidth > 0 else { return 3 }
        let fit = Int((self.gridWidth + Self.chipSpacing) / (Self.chipMinimumWidth + Self.chipSpacing))
        return max(fit, 1)
    }

    private var collapsedLimit: Int { self.columns * Self.collapsedRows }

    private var isMoodGrid: Bool {
        !self.entities.isEmpty && self.entities.allSatisfy {
            if case .mood = $0.target { return true }
            return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !self.title.isEmpty {
                HStack(alignment: .firstTextBaseline) {
                    Text(self.title)
                        .font(.title2.weight(.bold))
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 8)
                    if let seeAll {
                        NavigationLink("See all", value: seeAll)
                            .font(.subheadline)
                    }
                    if Platform.isMac, !self.isMoodGrid, self.canPage {
                        self.pagingArrows
                    }
                }
                .padding(.horizontal, AdaptiveLayout.horizontalPadding)
            }
            if self.isMoodGrid {
                let canCollapse = self.entities.count > self.collapsedLimit
                let visible = (self.isExpanded || !canCollapse) ? self.entities : Array(self.entities.prefix(self.collapsedLimit))
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: Self.chipMinimumWidth), spacing: Self.chipSpacing)],
                    spacing: Self.chipSpacing
                ) {
                    ForEach(visible) { entity in
                        MediaActions(entity: entity) {
                            Text(entity.title)
                                .font(.subheadline.weight(.semibold))
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .minimumScaleFactor(0.85)
                                .frame(maxWidth: .infinity, minHeight: Platform.isMac ? 60 : 52)
                                .padding(.horizontal, 8)
                                .glassEffect(.regular, in: .rect(cornerRadius: 14))
                        }
                    }
                }
                .padding(.horizontal, AdaptiveLayout.horizontalPadding)
                .onGeometryChange(for: CGFloat.self) { $0.size.width - 2 * AdaptiveLayout.horizontalPadding } action: { self.gridWidth = $0 }

                if canCollapse {
                    Button {
                        withAnimation(.snappy) { self.isExpanded.toggle() }
                    } label: {
                        Label(
                            self.isExpanded ? "Show less" : "Show all (\(self.entities.count))",
                            systemImage: self.isExpanded ? "chevron.up" : "chevron.down"
                        )
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                    .accessibilityHint(self.isExpanded ? "Collapses the list" : "Shows every item")
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: AdaptiveLayout.cardSpacing) {
                        ForEach(self.entities) { entity in
                            MediaActions(entity: entity) { MediaCard(entity: entity) }
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.horizontal, AdaptiveLayout.horizontalPadding)
                    .padding(.vertical, 4)
                }
                .scrollPosition(id: self.$scrolledID, anchor: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { self.rowWidth = $0 }
            }
        }
    }

    // MARK: Paging (macOS)

    /// Cards fully visible in the row.
    private var cardsPerPage: Int {
        let step = AdaptiveLayout.cardWidth + AdaptiveLayout.cardSpacing
        let usable = self.rowWidth - 2 * AdaptiveLayout.horizontalPadding + AdaptiveLayout.cardSpacing
        return max(1, Int(usable / step))
    }

    private var canPage: Bool { self.entities.count > self.cardsPerPage }

    private var currentIndex: Int {
        self.scrolledID.flatMap { id in self.entities.firstIndex { $0.id == id } } ?? 0
    }

    /// Back / forward by a page, like the shelf arrows of Kaset for macOS (a mouse wheel
    /// cannot scroll sideways).
    private var pagingArrows: some View {
        HStack(spacing: 4) {
            self.arrow("chevron.left", label: "Previous", enabled: self.currentIndex > 0) { -1 }
            self.arrow(
                "chevron.right", label: "Next",
                enabled: self.currentIndex + self.cardsPerPage < self.entities.count
            ) { 1 }
        }
        .padding(.leading, 6)
    }

    private func arrow(_ symbol: String, label: LocalizedStringKey, enabled: Bool, direction: @escaping () -> Int) -> some View {
        Button {
            let last = max(self.entities.count - self.cardsPerPage, 0)
            let target = min(max(self.currentIndex + direction() * self.cardsPerPage, 0), last)
            withAnimation(.easeInOut(duration: 0.35)) { self.scrolledID = self.entities[target].id }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 26)
                .background(.quaternary, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .help(Text(label))
        .accessibilityLabel(Text(label))
    }
}

extension ShelfView {
    /// A browse section, with its "See all" link when the shelf has one.
    init(section: HomeSection) {
        self.init(
            title: section.title,
            entities: section.items.map(MediaEntity.init),
            seeAll: section.moreEndpoint.map { SeeAllDestination(title: section.title, endpoint: $0) }
        )
    }
}

/// Everything behind a shelf's "See all": the playlist page, or the sections of the browse
/// page as grids.
struct SeeAllView: View {
    @Environment(AppEnvironment.self) private var environment

    let destination: SeeAllDestination

    @State private var sections: [HomeSection] = []
    @State private var phase: Phase = .loading

    private enum Phase: Equatable {
        case loading, loaded, failed(String)
    }

    var body: some View {
        if self.destination.endpoint.pageType == .playlist {
            PlaylistDetailView(id: self.destination.endpoint.browseId, fallbackTitle: self.destination.title, thumbnailURL: nil)
        } else {
            self.grid
                .navigationTitle(self.destination.title)
                .inlineNavigationTitle()
                .task { await self.load() }
        }
    }

    @ViewBuilder
    private var grid: some View {
        switch self.phase {
        case .loading:
            ProgressView()
        case let .failed(message):
            LoadFailureView(message: message) { Task { await self.load() } }
        case .loaded:
            if self.sections.isEmpty {
                ContentUnavailableView("Nothing here yet.", systemImage: "tray")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 28) {
                        ForEach(self.sections) { section in
                            // A single section is the page itself; its title repeats the navigation title.
                            if self.sections.count > 1 {
                                Text(section.title)
                                    .font(.title2.weight(.bold))
                                    .accessibilityAddTraits(.isHeader)
                            }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: AdaptiveLayout.gridMinimum), spacing: AdaptiveLayout.cardSpacing, alignment: .top)], spacing: 20) {
                                ForEach(section.items.map(MediaEntity.init)) { entity in
                                    MediaActions(entity: entity) { MediaCard(entity: entity, width: nil) }
                                }
                            }
                        }
                    }
                    .padding(AdaptiveLayout.horizontalPadding)
                }
            }
        }
    }

    private func load() async {
        self.phase = .loading
        do {
            let endpoint = self.destination.endpoint
            self.sections = try await self.environment.client
                .browseSections(browseId: endpoint.browseId, params: endpoint.params).sections
            self.phase = .loaded
        } catch is CancellationError {
        } catch {
            self.phase = .failed(error.localizedDescription)
        }
    }
}
