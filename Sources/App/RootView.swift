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
                #if os(iOS)
                MainTabView()
                #else
                MacMainWindow()
                #endif
            }
        }
        .background(alignment: .topLeading) {
            WebViewHost(webView: environment.player.webView)
                .id(environment.player.generation)
                // An invisible page with a real viewport: at 1×1 the web app lays out as a tiny
                // viewport and its queue/player-bar DOM is not reliably populated. iOS's desktop
                // content mode widens a phone-sized view to a desktop viewport; macOS uses the
                // frame as is, and below ~1000 pt YouTube Music drops its player bar.
                .frame(width: Platform.isMac ? 1280 : 390, height: Platform.isMac ? 800 : 844)
                .opacity(0)
                .allowsHitTesting(false)
        }
        .task { await environment.start() }
        .task(id: environment.auth.state) {
            guard environment.auth.state == .signedIn else { return }
            KasetShortcuts.updateAppShortcutParameters()
            await environment.newReleases.requestNotificationPermissionIfNeeded()
            await environment.newReleases.checkIfDue(client: environment.client, auth: environment.auth)
        }
        .onChange(of: environment.libraryRevision) { KasetShortcuts.updateAppShortcutParameters() }
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
            #if os(iOS)
            LoginView { Task { await environment.loginFinished() } }
            #else
            VStack(spacing: 0) {
                HStack {
                    Text("Sign in to YouTube Music").font(.headline)
                    Spacer()
                    Button("Cancel") { environment.isLoginPresented = false }
                        .keyboardShortcut(.cancelAction)
                }
                .padding(12)
                Divider()
                LoginView { Task { await environment.loginFinished() } }
            }
            .frame(width: 500, height: 650)
            #endif
        }
    }
}
