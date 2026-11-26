import SwiftUI

extension View {
    /// Registers the screens a `MediaEntity` or a "See all" link navigates to. Apply once per `NavigationStack`.
    func entityDestinations() -> some View {
        self.navigationDestination(for: MediaEntity.self) { EntityPage(entity: $0) }
            .navigationDestination(for: SeeAllDestination.self) { SeeAllView(destination: $0) }
    }

    /// `entityDestinations()`, plus `openEntity` pushing on `path`. Apply once per `NavigationStack`
    /// that has a path.
    func entityNavigation(path: Binding<NavigationPath>) -> some View {
        self.entityDestinations()
            .environment(\.openEntity, { path.wrappedValue.append($0) })
    }
}

extension EnvironmentValues {
    /// Pushes a page on the enclosing navigation stack. Author links use it: they sit inside
    /// cards that already are a button or a link, where a nested link would not get the tap.
    @Entry var openEntity: (@MainActor (MediaEntity) -> Void)? = nil
}

/// The screen an entity opens.
struct EntityPage: View {
    let entity: MediaEntity

    var body: some View {
        switch self.entity.target {
        case let .album(id), let .playlist(id):
            PlaylistDetailView(id: id, fallbackTitle: self.entity.title, thumbnailURL: self.entity.thumbnailURL)
        case let .artist(id):
            ArtistDetailView(id: id, fallbackName: self.entity.title)
        case let .mood(browseId, params):
            MoodCategoryView(browseId: browseId, params: params, title: self.entity.title)
        case let .podcast(id):
            PodcastShowView(id: id, fallbackTitle: self.entity.title, thumbnailURL: self.entity.thumbnailURL)
        case .song, .episode, .unsupported:
            ContentUnavailableView(self.entity.title, systemImage: "music.note")
        }
    }
}

/// Sections for one mood / genre.
struct MoodCategoryView: View {
    @Environment(AppEnvironment.self) private var environment

    let browseId: String
    let params: String?
    let title: String

    @State private var sections: [HomeSection] = []
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
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        ForEach(self.sections) { section in
                            ShelfView(section: section)
                        }
                    }
                    .padding(.vertical)
                }
            }
        }
        .navigationTitle(self.title)
        .inlineNavigationTitle()
        .task { await self.load() }
    }

    private func load() async {
        self.phase = .loading
        do {
            self.sections = try await self.environment.client
                .getMoodCategory(browseId: self.browseId, params: self.params).sections
            self.phase = .loaded
        } catch is CancellationError {
        } catch {
            self.phase = .failed(error.localizedDescription)
        }
    }
}
