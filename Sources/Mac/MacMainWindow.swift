import SwiftUI

/// Main window, laid out like Kaset for macOS: sidebar, content with the player bar floating at
/// its bottom, and the lyrics / queue glass panel sliding in from the right.
struct MacMainWindow: View {
    static let minimumWidth: CGFloat = 980
    static let minimumHeight: CGFloat = 600

    @Environment(AppEnvironment.self) private var environment
    @State private var shell: MacShell?

    var body: some View {
        Group {
            if let shell {
                MacMainContent()
                    .environment(shell)
            } else {
                Color.clear
            }
        }
        .frame(minWidth: Self.minimumWidth, minHeight: Self.minimumHeight)
        .onAppear {
            if self.shell == nil {
                let shell = MacShell(client: self.environment.client)
                MacShell.current = shell
                self.shell = shell
            }
        }
    }
}

private struct MacMainContent: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(MacShell.self) private var shell
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        let state = self.environment.player.state

        ZStack(alignment: .trailing) {
            NavigationSplitView(columnVisibility: self.$columnVisibility) {
                MacSidebar()
            } detail: {
                MacDetailView(item: self.shell.selection ?? .home)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        MacPlayerBar()
                    }
            }

            if let panel = self.shell.sidePanel {
                MacSidePanelView(panel: panel)
                    .padding(.top, 12)
                    .padding(.bottom, 76) // Room for the player bar.
                    .padding(.trailing, 16)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: self.shell.sidePanel)
        .queueNoticeBanner()
        .task(id: state.videoId) {
            await self.shell.nowPlaying.trackChanged(to: state.videoId)
            self.environment.player.applyVolume()
        }
        .onChange(of: self.environment.likedFromOutside) { _, videoId in
            if let videoId { self.shell.nowPlaying.likedElsewhere(videoId: videoId) }
        }
        .onChange(of: NotificationRouter.shared.homeRequest) { self.shell.select(.home) }
        .onChange(of: NotificationRouter.shared.pendingEntity, initial: true) { _, entity in
            guard let entity else { return }
            NotificationRouter.shared.pendingEntity = nil
            if case .song = entity.target {
                self.environment.playEntity(entity, opensNowPlaying: false)
            } else {
                self.shell.selection = .home
                self.shell.paths[.home] = NavigationPath([entity])
            }
        }
        .onChange(of: self.environment.auth.state) { _, newState in
            if newState == .signedOut { self.shell.resetForSignOut() }
        }
    }
}

/// Content for one sidebar item, in its own navigation stack.
private struct MacDetailView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(MacShell.self) private var shell

    let item: MacSidebarItem

    var body: some View {
        NavigationStack(path: self.shell.path(for: self.item)) {
            self.root
                .navigationTitle(Text(self.item.title))
                .entityDestinations()
        }
        // ⌘R rebuilds the stack (the path is kept), so the pages on it load again.
        .id("\(self.item)-\(self.shell.refreshGeneration)")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    self.shell.refreshCurrent()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Refresh (⌘R)")
            }
        }
    }

    @ViewBuilder
    private var root: some View {
        if self.item.requiresSignIn, self.environment.auth.state != .signedIn {
            ContentUnavailableView {
                Label("Sign in to use \(Text(self.item.title))", systemImage: "person.crop.circle")
            } description: {
                Text("Kaset works without an account for browsing, search and playback. Sign in to see your library, liked songs and history.")
            } actions: {
                Button("Sign in") { self.environment.isLoginPresented = true }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            switch self.item {
            case .search:
                SearchContent(model: self.shell.search)
            case .home:
                let model = self.shell.browseModel(for: .home)
                BrowsePageView(model: model, emptyMessage: "No recommendations yet.") {
                    NewReleasesShelf()
                    MixesShelf()
                }
                .onAppear { self.shell.loadHome(for: self.environment.auth.state) }
                .onChange(of: self.environment.auth.state) { _, state in self.shell.loadHome(for: state) }
            case .explore, .charts, .moodsAndGenres, .newReleases:
                if let type = self.item.browseType {
                    let model = self.shell.browseModel(for: type)
                    BrowsePageView(model: model)
                        .onAppear { self.shell.load(type) }
                }
            case .history:
                let model = self.shell.browseModel(for: .history)
                HistoryView(model: model)
                    .onAppear { self.shell.load(.history, force: true) }
            case .library:
                LibraryContentView().id(self.environment.libraryRevision)
            case .likedMusic:
                LikedMusicView()
            case .recap:
                RecapView()
            case let .playlist(id, title):
                PlaylistDetailView(id: id, fallbackTitle: title)
            }
        }
    }
}
