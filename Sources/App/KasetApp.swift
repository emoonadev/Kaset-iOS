import SwiftUI
import UserNotifications

@main
struct KasetApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var environment = AppEnvironment()

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

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        let albumId = info[NotificationRouter.albumIdKey] as? String
        let title = info[NotificationRouter.albumTitleKey] as? String
        let videoId = info[NotificationRouter.videoIdKey] as? String
        await NotificationRouter.shared.open(albumId: albumId, title: title, videoId: videoId)
    }

    /// In the app the Home shelf already shows the releases; still show the banner.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}

extension Color {
    /// The red-pink of the app icon (kaset's cassette), used as the accent colour.
    static let brand = Color(red: 252 / 255, green: 19 / 255, blue: 85 / 255)
}
