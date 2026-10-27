import SwiftUI

/// Launch routing: unknown → splash, otherwise the tabs (signed-out users are guests). The player's web
/// view stays attached to the window as a hidden 1×1 view for the whole app lifetime so audio
/// keeps running.
struct RootView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var environment = self.environment

        Group {
            switch environment.auth.state {
            case .unknown:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .signedOut, .signedIn:
                // Signed-out users browse as guests; sign-in lives on the navigation bar button.
                MainTabView()
            }
        }
        .background(alignment: .topLeading) {
            WebViewHost(webView: environment.player.webView)
                .id(environment.player.generation)
                // A phone-sized (but invisible) page: at 1×1 the web app lays out as a tiny
                // viewport and its queue/player-bar DOM is not reliably populated.
                .frame(width: 390, height: 844)
                .opacity(0)
                .allowsHitTesting(false)
        }
        .task { await environment.start() }
        .task(id: environment.auth.state) {
            guard environment.auth.state == .signedIn else { return }
            await environment.newReleases.requestNotificationPermissionIfNeeded()
            await environment.newReleases.checkIfDue(client: environment.client, auth: environment.auth)
        }
        .onChange(of: self.scenePhase) { _, phase in
            switch phase {
            case .active:
                Task { await environment.listening.sync() }
                guard environment.auth.state == .signedIn else { return }
                Task { await environment.newReleases.checkIfDue(client: environment.client, auth: environment.auth) }
            case .background:
                environment.newReleases.scheduleBackgroundCheck()
                environment.listening.flush()
                Task { await environment.listening.sync() }
            default:
                break
            }
        }
        .sheet(isPresented: $environment.isLoginPresented) {
            LoginView { Task { await environment.loginFinished() } }
        }
    }
}
