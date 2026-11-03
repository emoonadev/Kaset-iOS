import SwiftUI
import UserNotifications

@main
struct KasetApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var environment = AppEnvironment.shared

    var body: some Scene {
        let environment = self.environment
        WindowGroup {
            RootView()
                .environment(environment)
                .tint(Color.brand)
        }
        .backgroundTask(.appRefresh(NewReleaseWatcher.taskIdentifier)) {
            await environment.newReleases.runBackgroundCheck(client: environment.client, auth: environment.auth)
        }
    }
}

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

extension Color {
    /// The red-pink of the app icon (kaset's cassette), used as the accent colour.
    static let brand = Color(red: 252 / 255, green: 19 / 255, blue: 85 / 255)
}
