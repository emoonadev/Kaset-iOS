import SwiftUI
import UserNotifications

@main
struct KasetApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #else
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif
    @State private var environment = AppEnvironment.shared

    var body: some Scene {
        let environment = self.environment
        #if os(iOS)
        WindowGroup {
            RootView()
                .environment(environment)
                .tint(Color.brand)
        }
        .backgroundTask(.appRefresh(NewReleaseWatcher.taskIdentifier)) {
            await environment.newReleases.runBackgroundCheck(client: environment.client, auth: environment.auth)
        }
        #else
        // One main window, like Kaset for macOS: closing it keeps the app (and the music) running.
        Window("Spool", id: "main") {
            RootView()
                .environment(environment)
                .tint(Color.brand)
        }
        .defaultSize(width: 1180, height: 760)
        .windowToolbarStyle(.unified)
        .commands { PlaybackCommands(environment: environment) }

        Settings {
            SettingsView()
                .environment(environment)
                .tint(Color.brand)
                .frame(width: 520, height: 620)
        }
        #endif
    }
}

#if os(iOS)
/// Notification taps. The delegate has to be set before launch finishes for a tap that
/// launches the app to be delivered.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    /// Completion handlers, not the `async` variants: an `async` delegate method completes off the
    /// main thread, and UIKit's handler for a tap must run on it.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let albumId = info[NotificationRouter.albumIdKey] as? String
        let title = info[NotificationRouter.albumTitleKey] as? String
        let videoId = info[NotificationRouter.videoIdKey] as? String
        Task { @MainActor in
            NotificationRouter.shared.open(albumId: albumId, title: title, videoId: videoId)
            completionHandler()
        }
    }

    /// In the app the Home shelf already shows the releases; still show the banner.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void
    ) {
        Task { @MainActor in
            completionHandler([.banner, .list])
        }
    }
}
#else
/// Notification taps, and keeping the app alive (playing) when its window is closed.
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationWillFinishLaunching(_: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }

    func applicationDidFinishLaunching(_: Notification) {
        MainActor.assumeIsolated { SpaceBarMonitor.install() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool { false }

    /// Clicking the Dock icon with no window brings the main window back.
    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }?.makeKeyAndOrderFront(nil)
        }
        return true
    }

    func applicationWillTerminate(_: Notification) {
        Task { @MainActor in AppEnvironment.shared.listening.flush() }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let albumId = info[NotificationRouter.albumIdKey] as? String
        let title = info[NotificationRouter.albumTitleKey] as? String
        let videoId = info[NotificationRouter.videoIdKey] as? String
        Task { @MainActor in
            NotificationRouter.shared.open(albumId: albumId, title: title, videoId: videoId)
            completionHandler()
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void
    ) {
        Task { @MainActor in
            completionHandler([.banner, .list])
        }
    }
}
#endif

extension Color {
    /// The blue of the app icon (kaset's cassette), used as the accent colour.
    static let brand = Color(red: 19 / 255, green: 96 / 255, blue: 252 / 255)
}
