import SwiftUI

/// Apple Music-style shell: Home · Discover · Collections · Search, with the mini player as the
/// tab bar's bottom accessory (full pill, or compact inline when the bar minimizes).
struct MainTabView: View {
    enum Tab: Hashable {
        case home, discover, collections, search
    }

    @Environment(AppEnvironment.self) private var environment
    @Namespace private var nowPlayingNamespace
    @State private var selection: Tab = .home

    var body: some View {
        TabView(selection: self.$selection) {
            SwiftUI.Tab("Home", systemImage: "house", value: Tab.home) {
                HomeView()
            }
            SwiftUI.Tab("Discover", systemImage: "sparkles", value: Tab.discover) {
                DiscoverView()
            }
            SwiftUI.Tab("Collections", systemImage: "square.stack", value: Tab.collections) {
                CollectionsView()
            }
            SwiftUI.Tab("Search", systemImage: "magnifyingglass", value: Tab.search, role: .search) {
                SearchView()
            }
        }
        .queueNoticeBanner()
        .onChange(of: NotificationRouter.shared.homeRequest) { self.selection = .home }
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory {
            MiniPlayerView(
                namespace: self.nowPlayingNamespace,
                onTap: { self.environment.isNowPlayingPresented = true }
            )
        }
        .fullScreenCover(isPresented: Bindable(self.environment).isNowPlayingPresented) {
            NowPlayingView()
                .navigationTransition(.zoom(sourceID: "miniPlayer", in: self.nowPlayingNamespace))
        }
    }
}
