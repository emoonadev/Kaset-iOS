import SwiftUI

/// Explore · Charts · Moods · New releases · Podcasts. Every segment keeps its own model and
/// scroll position: segments are loaded the first time they are shown and then only hidden.
struct DiscoverView: View {
    enum Segment: String, CaseIterable, Identifiable {
        case explore = "Explore"
        case charts = "Charts"
        case moods = "Moods"
        case newReleases = "New"
        case podcasts = "Podcasts"

        var id: String { self.rawValue }

        /// Browse surface behind the segment; Podcasts has its own page model.
        var type: PaginatedContentType? {
            switch self {
            case .explore: .explore
            case .charts: .charts
            case .moods: .moodsAndGenres
            case .newReleases: .newReleases
            case .podcasts: nil
            }
        }
    }

    @Environment(AppEnvironment.self) private var environment
    @State private var selection: Segment = .explore
    @State private var models: [Segment: BrowsePageModel] = [:]
    @State private var podcasts: PodcastsModel?
    @State private var visited: Set<Segment> = [.explore]
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: self.$path) {
            VStack(spacing: 0) {
                Picker("Section", selection: self.$selection) {
                    ForEach(Segment.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 8)

                ZStack {
                    ForEach(Segment.allCases) { segment in
                        if self.visited.contains(segment) {
                            self.page(for: segment)
                                .opacity(self.selection == segment ? 1 : 0)
                                .allowsHitTesting(self.selection == segment)
                        }
                    }
                }
            }
            .navigationTitle("Discover")
            .entityNavigation(path: self.$path)
            .toolbar { SettingsToolbarButton() }
        }
        .task(id: self.selection) {
            self.visited.insert(self.selection)
            if let type = self.selection.type {
                if self.models[self.selection] == nil {
                    self.models[self.selection] = BrowsePageModel(type: type, client: self.environment.client)
                }
                await self.models[self.selection]?.load()
            } else {
                // Not awaited here: SwiftUI can cancel this view task while the page appears,
                // which would stop the load and leave the page on its spinner.
                let model = self.podcastsModel()
                Task { await model.load() }
            }
        }
        .onChange(of: self.environment.contentScope) {
            // Another account: its podcasts page is loaded again when shown.
            self.podcasts = nil
            self.visited.remove(.podcasts)
            if self.selection == .podcasts {
                self.visited.insert(.podcasts)
                Task { await self.podcastsModel().load() }
            }
        }
    }

    @ViewBuilder
    private func page(for segment: Segment) -> some View {
        if segment == .podcasts {
            if let podcasts { PodcastsView(model: podcasts) }
        } else if let model = self.models[segment] {
            BrowsePageView(model: model)
        }
    }

    private func podcastsModel() -> PodcastsModel {
        if let podcasts { return podcasts }
        let auth = self.environment.auth
        let model = PodcastsModel(client: self.environment.client) { auth.state == .signedIn }
        self.podcasts = model
        return model
    }
}
