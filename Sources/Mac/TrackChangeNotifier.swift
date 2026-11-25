import AppKit
import Foundation
import Observation
import UserNotifications

/// Posts a local notification each time the playing song changes, whether the user skipped or
/// the queue moved on by itself. macOS only: on iOS the lock screen already shows the track.
///
/// Driven by the mirrored `PlaybackState`. The page reports a new `videoId` a little before its
/// Media Session details (artist, album, artwork) settle, so a track is announced after a short
/// pause, once `isMetadataCurrent` says the details belong to it, and only once per track. Rapid
/// skips collapse into one notification for the song that stays.
@MainActor
@Observable
final class TrackChangeNotifier {
    static let storageKey = "settings.trackChangeNotifications"
    /// Groups the notifications in Notification Center.
    nonisolated static let threadIdentifier = "now-playing"
    /// `userInfo` marker, so a click only brings the window forward (no navigation, no replay).
    nonisolated static let kindKey = "kind"
    nonisolated static let kindValue = "nowPlaying"
    /// Pause after a track change, so rapid skips produce one notification.
    private static let settleDelay: Duration = .milliseconds(900)
    /// Longest wait for the track's own details. Past it, the notification uses what the player
    /// reported for that video (correct title, maybe no artwork) rather than nothing.
    private static let metadataTimeout: Duration = .seconds(4)
    private static let metadataPollInterval: Duration = .milliseconds(150)

    /// On unless turned off in Settings.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: self.storageKey) as? Bool ?? true
    }

    /// Last known permission; Settings warns when macOS blocks Spool's notifications.
    private(set) var authorization: UNAuthorizationStatus = .notDetermined

    @ObservationIgnored private let log = SpikeLog.shared
    @ObservationIgnored private var lastAnnouncedID: String?
    /// The track waiting for `settleDelay`, kept up to date by every state report.
    @ObservationIgnored private var pending: PlaybackState?
    @ObservationIgnored private var postTask: Task<Void, Never>?
    /// The notification on screen for the previous track, removed when the next one is posted.
    @ObservationIgnored private var lastRequestID: String?

    /// Called at launch: asks for permission up front (from the app, where macOS can show the
    /// prompt) instead of on the first song change, and records the answer.
    func prepare() async {
        await self.refreshAuthorization()
        guard Self.isEnabled, self.authorization == .notDetermined else { return }
        _ = await self.requestPermission()
    }

    /// Asks macOS for permission. Returns whether notifications are allowed.
    func requestPermission() async -> Bool {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            self.log.log("notify", "permission \(granted ? "granted" : "refused")")
        } catch {
            self.log.log("notify", "permission request failed: \(error.localizedDescription)")
        }
        await self.refreshAuthorization()
        return self.isAllowed
    }

    var isAllowed: Bool {
        self.authorization == .authorized || self.authorization == .provisional
    }

    func refreshAuthorization() async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        if status != self.authorization {
            self.log.log("notify", "authorization: \(Self.describe(status))")
        }
        self.authorization = status
    }

    /// Opens Spool's page in System Settings → Notifications.
    static func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? "dev.emoona.kaset.mac"
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }

    private static func describe(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: "not determined"
        case .denied: "denied"
        case .authorized: "authorized"
        case .provisional: "provisional"
        case .ephemeral: "ephemeral"
        @unknown default: "unknown (\(status.rawValue))"
        }
    }

    func playbackChanged(_ state: PlaybackState) {
        guard state.hasMedia, !state.isAd, let videoId = state.videoId else { return }
        if let pending = self.pending, pending.videoId == videoId {
            self.pending = state
            return
        }
        guard videoId != self.lastAnnouncedID else { return }
        self.pending = state
        self.postTask?.cancel()
        self.postTask = Task { [weak self] in
            try? await Task.sleep(for: Self.settleDelay)
            let deadline = ContinuousClock.now + Self.metadataTimeout - Self.settleDelay
            while !Task.isCancelled, ContinuousClock.now < deadline,
                  self?.pending?.isMetadataCurrent == false
            {
                try? await Task.sleep(for: Self.metadataPollInterval)
            }
            guard !Task.isCancelled else { return }
            await self?.announcePending()
        }
    }

    private func announcePending() async {
        guard let state = self.pending, let videoId = state.videoId else { return }
        self.pending = nil
        if !state.isMetadataCurrent {
            self.log.log("notify", "\(videoId): track details still settling, using the player's")
        }
        guard let title = state.title, !title.isEmpty else {
            self.log.log("notify", "skipped \(videoId): no title yet")
            return
        }
        self.lastAnnouncedID = videoId
        guard Self.isEnabled else { return }
        await self.post(videoId: videoId, title: title, artist: state.artist ?? "", album: state.album, artworkURL: state.artworkURL)
    }

    private func post(videoId: String, title: String, artist: String, album: String?, artworkURL: URL?) async {
        let center = UNUserNotificationCenter.current()
        await self.refreshAuthorization()
        if self.authorization == .notDetermined { _ = await self.requestPermission() }
        guard self.isAllowed else {
            self.log.log("notify", "skipped \(videoId): notifications not allowed")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = artist
        if let album, !album.isEmpty, album != title { content.body = album }
        content.userInfo = [Self.kindKey: Self.kindValue]
        content.threadIdentifier = Self.threadIdentifier
        if let attachment = await Self.artworkAttachment(from: artworkURL, videoId: videoId) {
            content.attachments = [attachment]
        }
        guard !Task.isCancelled else { return }
        // A new identifier each time: reusing one only updates the notification already on
        // screen, without a new banner. The previous track's notification is removed instead,
        // so Notification Center keeps just the current song.
        if let previous = self.lastRequestID {
            center.removeDeliveredNotifications(withIdentifiers: [previous])
        }
        let identifier = "now-playing-\(videoId)-\(UUID().uuidString)"
        self.lastRequestID = identifier
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        do {
            try await center.add(request)
            self.log.log("notify", "posted \(videoId)")
        } catch {
            self.log.log("notify", "track notification failed: \(error.localizedDescription)")
        }
    }

    /// Notification attachments must be local files; the artwork is downloaded to a temporary one
    /// (moved into the notification store by the system once added).
    private static func artworkAttachment(from url: URL?, videoId: String) async -> UNNotificationAttachment? {
        guard let url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode ?? 200 == 200,
              !data.isEmpty
        else { return nil }
        let ext = response.mimeType == "image/png" ? "png" : "jpg"
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("spool-artwork-\(videoId)-\(UUID().uuidString).\(ext)")
        guard (try? data.write(to: file)) != nil else { return nil }
        return try? UNNotificationAttachment(identifier: "artwork", url: file)
    }

    /// A click on the notification: bring the main window to the front.
    static func showMainWindow() {
        NSApp.activate()
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }?.makeKeyAndOrderFront(nil)
    }
}
