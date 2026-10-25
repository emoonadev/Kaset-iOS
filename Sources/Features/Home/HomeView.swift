import SwiftUI

struct HomeView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var model: BrowsePageModel?
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: self.$path) {
            Group {
                if let model {
                    BrowsePageView(model: model, emptyMessage: "No recommendations yet.") {
                        NewReleasesShelf()
                        MixesShelf()
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Home")
            .entityDestinations()
            .toolbar { SettingsToolbarButton() }
        }
        .onChange(of: NotificationRouter.shared.pendingEntity, initial: true) { _, entity in
            guard let entity else { return }
            NotificationRouter.shared.pendingEntity = nil
            if case .song = entity.target {
                self.environment.playEntity(entity)
                self.environment.isNowPlayingPresented = true
            } else {
                self.path = NavigationPath([entity])
            }
        }
        .task(id: self.environment.auth.state) {
            let model = self.model ?? BrowsePageModel(type: .home, client: self.environment.client)
            self.model = model
            await model.load(force: true)
        }
    }
}
