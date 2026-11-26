import Observation
import SwiftUI

/// Sidebar destinations, in the order of Kaset for macOS.
enum MacSidebarItem: Hashable {
    case search, home
    case explore, charts, moodsAndGenres, newReleases, podcasts
    case library, likedMusic, history, recap
    case playlist(id: String, title: String)

    var title: LocalizedStringKey {
        switch self {
        case .search: "Search"
        case .home: "Home"
        case .explore: "Explore"
        case .charts: "Charts"
        case .moodsAndGenres: "Moods & Genres"
        case .newReleases: "New Releases"
        case .podcasts: "Podcasts"
        case .library: "Library"
        case .likedMusic: "Liked Music"
        case .history: "History"
        case .recap: "Recap"
        case let .playlist(_, title): LocalizedStringKey(title)
        }
    }

    var systemImage: String {
        switch self {
        case .search: "magnifyingglass"
        case .home: "house"
        case .explore: "globe"
        case .charts: "chart.line.uptrend.xyaxis"
        case .moodsAndGenres: "theatermask.and.paintbrush"
        case .newReleases: "sparkles"
        case .podcasts: "mic"
        case .library: "square.stack"
        case .likedMusic: "heart"
        case .history: "clock"
        case .recap: "chart.bar.xaxis"
        case .playlist: "music.note.list"
        }
    }

    /// Browse surface behind a Discover item.
    var browseType: PaginatedContentType? {
        switch self {
        case .explore: .explore
        case .charts: .charts
        case .moodsAndGenres: .moodsAndGenres
        case .newReleases: .newReleases
        case .history: .history
        default: nil
        }
    }

    var requiresSignIn: Bool {
        switch self {
        case .library, .likedMusic, .history, .recap, .playlist: true
        default: false
        }
    }
}

/// The right-hand glass panel (mutually exclusive, like Kaset for macOS).
enum MacSidePanel: Hashable {
    case lyrics, queue
}

/// Window state for the macOS shell: selection, per-item navigation, side panel and the
/// now-playing extras (rating, lyrics) shared by the player bar and the lyrics panel.
@MainActor
@Observable
final class MacShell {
    /// The main window's shell, for the menu bar commands.
    static var current: MacShell?

    var selection: MacSidebarItem? = .home
    var sidePanel: MacSidePanel?
    /// One navigation stack per sidebar item, so switching items keeps where you were.
    var paths: [MacSidebarItem: NavigationPath] = [:]
    /// Library playlists listed under "Playlists" in the sidebar.
    private(set) var playlists: [Playlist] = []
    /// Bumped to focus the search field (⌘F, or selecting Search again).
    var searchFocusRequest = 0

    let nowPlaying: NowPlayingModel
    @ObservationIgnored private(set) lazy var search = SearchViewModel(client: self.client)
    @ObservationIgnored private var browseModels: [PaginatedContentType: BrowsePageModel] = [:]
    @ObservationIgnored private var podcastsModel: PodcastsModel?
    @ObservationIgnored private let client: YTMusicClient

    init(client: YTMusicClient) {
        self.client = client
        self.nowPlaying = NowPlayingModel(client: client)
    }

    /// Account the Home page was last loaded for; Home reloads when it changes.
    @ObservationIgnored private var homeLoadedFor: AuthState?

    /// Home reloads when the account changes; otherwise it is loaded once.
    func loadHome(for state: AuthState) {
        let force = self.homeLoadedFor != state
        self.homeLoadedFor = state
        self.load(.home, force: force)
    }

    /// Starts a load owned by the shell, not by the view: SwiftUI can rebuild the detail view
    /// while it appears, which cancels a view `.task` and would leave the page on its spinner.
    func load(_ type: PaginatedContentType, force: Bool = false) {
        let model = self.browseModel(for: type)
        Task { await model.load(force: force) }
    }

    /// Loaded once per type and kept, so returning to an item does not reload it.
    func browseModel(for type: PaginatedContentType) -> BrowsePageModel {
        if let model = self.browseModels[type] { return model }
        let model = BrowsePageModel(type: type, client: self.client)
        self.browseModels[type] = model
        return model
    }

    /// The Podcasts page, loaded once and kept like the browse pages.
    func podcasts() -> PodcastsModel {
        if let podcastsModel { return podcastsModel }
        let model = PodcastsModel(client: self.client) { AppEnvironment.shared.auth.state == .signedIn }
        self.podcastsModel = model
        return model
    }

    func loadPodcasts(force: Bool = false) {
        let model = self.podcasts()
        Task { await model.load(force: force) }
    }

    /// Another account: its own podcasts page.
    func resetPodcasts() {
        self.podcastsModel = nil
        if self.selection == .podcasts { self.loadPodcasts() }
    }

    func path(for item: MacSidebarItem) -> Binding<NavigationPath> {
        Binding(
            get: { self.paths[item, default: NavigationPath()] },
            set: { self.paths[item] = $0 }
        )
    }

    /// Selecting the current item again goes back to its root.
    func select(_ item: MacSidebarItem) {
        if self.selection == item {
            self.paths[item] = NavigationPath()
            if item == .search { self.searchFocusRequest += 1 }
        } else {
            self.selection = item
        }
    }

    /// ⌘R: reloads the browse page on screen (there is no pull to refresh on the Mac).
    /// Bumped by ⌘R: the detail stack is rebuilt, so every page on it (library, liked songs,
    /// playlist, artist…) loads again; browse pages are fetched bypassing the cache.
    private(set) var refreshGeneration = 0

    func refreshCurrent() {
        if let type = self.selection == .home ? .home : self.selection?.browseType {
            self.load(type, force: true)
        }
        if self.selection == .podcasts { self.loadPodcasts(force: true) }
        if self.selection == .library { AppEnvironment.shared.libraryRevision += 1 }
        self.refreshGeneration += 1
        Task { await self.loadPlaylists(signedIn: AppEnvironment.shared.auth.state == .signedIn) }
    }

    func focusSearch() {
        if self.selection != .search { self.selection = .search }
        self.searchFocusRequest += 1
    }

    func toggle(_ panel: MacSidePanel) {
        withAnimation(.easeInOut(duration: 0.25)) {
            self.sidePanel = self.sidePanel == panel ? nil : panel
        }
    }

    /// Opens an album / playlist / artist from anywhere (player bar, menus) on top of the
    /// current item's stack.
    func open(_ entity: MediaEntity) {
        let item = self.selection ?? .home
        if self.selection == nil { self.selection = item }
        self.paths[item, default: NavigationPath()].append(entity)
    }

    func loadPlaylists(signedIn: Bool) async {
        guard signedIn else {
            self.playlists = []
            return
        }
        guard let content = try? await self.client.getLibraryContent() else { return }
        // Liked Music has its own row; uploads are not a playlist the user made.
        self.playlists = content.playlists.filter { playlist in
            playlist.id != "LM" && playlist.id != "VLLM" && playlist.id != Playlist.uploadedSongsBrowseID
        }
        // A deleted playlist leaves the sidebar: do not keep showing it.
        if case let .playlist(id, _) = self.selection, !self.playlists.contains(where: { $0.id == id }) {
            self.selection = .library
        }
    }

    /// Back to Home after sign-out, so a personal page does not stay on screen.
    func resetForSignOut() {
        self.paths = [:]
        if self.selection?.requiresSignIn == true { self.selection = .home }
    }
}
