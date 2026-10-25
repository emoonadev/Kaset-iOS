import BackgroundTasks
import Foundation
import Observation
import UserNotifications

/// Watches followed artists for new albums and singles, with no server: a background app
/// refresh in the morning (from 7:00, when iOS lets it run), plus a catch-up when the app comes
/// to the front and no check ran for most of a day. New releases feed the Home shelf and,
/// when enabled, one local notification at 8:00.
@MainActor
@Observable
final class NewReleaseWatcher {
    static let taskIdentifier = "dev.emoona.kaset.newReleases"
    static let notificationsStorageKey = "settings.newReleaseNotifications"

    /// A background refresh gets about 30 s; one artist page takes well under a second.
    private static let backgroundLimit = 30
    private static let foregroundLimit = 100
    private static let concurrency = 6
    /// Most played artists, checked on every run before the others.
    private static let priorityCount = 20

    private(set) var state: NewReleaseState
    private(set) var isChecking = false

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let log = SpikeLog.shared

    /// On unless turned off in Settings.
    static var notificationsEnabled: Bool {
        UserDefaults.standard.object(forKey: self.notificationsStorageKey) as? Bool ?? true
    }

    /// Most recent first, for the Home shelf.
    var shelf: [NewRelease] { self.state.shelf }

    init(fileURL: URL? = nil) {
        let url = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            // v4: earlier versions shelved undated releases ahead of dated ones; start over.
            .appendingPathComponent("new-releases-v4.json")
        self.fileURL = url
        for old in ["new-releases.json", "new-releases-v2.json", "new-releases-v3.json"] {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent().appendingPathComponent(old))
        }
        self.state = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(NewReleaseState.self, from: $0) }
            ?? NewReleaseState()
    }

    // MARK: - Entry points

    /// The background app refresh: book the next morning first, so a run cut short by iOS
    /// still leaves one scheduled.
    func runBackgroundCheck(client: YTMusicClient, auth: AuthStore) async {
        self.scheduleBackgroundCheck()
        await self.check(client: client, auth: auth, limit: Self.backgroundLimit, reason: "background")
    }

    /// App came to the front: check when the morning run did not happen.
    func checkIfDue(client: YTMusicClient, auth: AuthStore) async {
        guard NewReleaseSchedule.isDue(lastCheck: self.state.lastCheck, now: .now) else { return }
        await self.check(client: client, auth: auth, limit: Self.foregroundLimit, reason: "catch-up")
    }

    /// "Check now" in Settings.
    func checkNow(client: YTMusicClient, auth: AuthStore) async {
        await self.check(client: client, auth: auth, limit: Self.foregroundLimit, reason: "manual")
    }

    func scheduleBackgroundCheck() {
        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        request.earliestBeginDate = NewReleaseSchedule.nextCheck(after: .now)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Simulator, or Background App Refresh turned off for the app.
            self.log.log("releases", "schedule failed: \(error.localizedDescription)")
        }
    }

    /// Asks for permission when the user turns notifications on. Returns whether they are allowed.
    func requestNotificationPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// Notifications are on by default: ask once, in the app, the first time a signed-in user
    /// opens it (a background check cannot show the permission prompt).
    func requestNotificationPermissionIfNeeded() async {
        guard Self.notificationsEnabled,
              await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .notDetermined
        else { return }
        _ = await self.requestNotificationPermission()
    }

    // MARK: - Check

    private func check(client: YTMusicClient, auth: AuthStore, limit: Int, reason: String) async {
        guard !self.isChecking else { return }
        self.isChecking = true
        defer { self.isChecking = false }

        // Launched in the background, the launch work that restores the session may not have run.
        if auth.state == .unknown { await auth.restore() }
        guard auth.state == .signedIn else { return }

        let subscribed: [Artist]
        do {
            subscribed = try await client.getSubscribedArtists()
        } catch {
            self.log.log("releases", "\(reason): subscriptions failed: \(error.localizedDescription)")
            self.state.lastResult = .init(date: .now, checked: 0, artists: 0, found: 0, failure: error.localizedDescription)
            self.save()
            return
        }
        var names: [String: String] = [:]
        for artist in subscribed {
            if let id = artist.publicChannelId { names[id] = artist.name }
        }
        let followed = Set(names.keys)

        // How much each artist is played, from the account's listening history.
        var plays: [String: Int] = [:]
        if let history = try? await client.getHistory() {
            for case let .song(song) in history.sections.flatMap(\.items) {
                for artist in song.artists {
                    guard let id = artist.publicChannelId else { continue }
                    plays[id, default: 0] += 1
                    if names[id] == nil { names[id] = artist.name }
                }
            }
        }
        let priority = NewReleaseState.priority(plays: plays, followed: followed, limit: Self.priorityCount)
        let watched = followed.union(priority)
        guard !watched.isEmpty else {
            self.log.log("releases", "\(reason): no followed or played artists")
            self.state.lastCheck = .now
            self.state.lastResult = .init(date: .now, checked: 0, artists: 0, found: 0)
            self.save()
            return
        }

        let batch = NewReleaseState.batch(Array(followed), priority: priority, after: self.state.cursor, limit: limit)
        let prioritized = Set(priority)
        var found: [NewRelease] = []
        var checked = 0
        for start in stride(from: 0, to: batch.count, by: Self.concurrency) {
            if Task.isCancelled { break }
            let chunk = Array(batch[start ..< min(start + Self.concurrency, batch.count)])
            let pages = await withTaskGroup(of: (String, [Album], [Album])?.self) { group in
                for id in chunk {
                    group.addTask {
                        guard let page = try? await client.getArtistReleases(id: id) else { return nil }
                        return (id, page.albums, page.singles)
                    }
                }
                var pages: [(String, [Album], [Album])] = []
                for await page in group {
                    if let page { pages.append(page) }
                }
                return pages
            }
            for (id, albums, singles) in pages {
                found += self.state.record(
                    artistId: id, artistName: names[id] ?? "", albums: albums, singles: singles, now: .now
                )
            }
            checked += pages.count
            if let last = chunk.last(where: { !prioritized.contains($0) }) { self.state.cursor = last }
            self.save()
        }

        await self.resolveDetails(client: client, priority: priority, limit: limit)
        if !Task.isCancelled { self.state.lastCheck = .now }
        // Also drops "new" releases whose date shows they are old (a re-upload, a late listing).
        self.state.prune(followed: watched, now: .now)
        let listed = Set(self.state.releases.map(\.id))
        found.removeAll { !listed.contains($0.id) }
        self.state.lastResult = .init(date: .now, checked: checked, artists: watched.count, found: found.count)
        self.save()
        let top = priority.prefix(5).map { "\(names[$0] ?? $0) (\(plays[$0] ?? 0))" }.joined(separator: ", ")
        self.log.log(
            "releases",
            "\(reason): checked \(checked)/\(batch.count) of \(watched.count) artists "
                + "(\(followed.count) followed, top: \(top)), \(found.count) new, \(self.state.releases.count) on the shelf"
                + (found.isEmpty ? "" : ": " + found.map { "\($0.artistName) – \($0.title)" }.joined(separator: ", "))
        )
        if !found.isEmpty { await self.announce(Set(found.map(\.id))) }
    }

    /// Reads the page of releases found earlier: release date, first track, number of tracks.
    /// Two requests each; up to `limit` per run, the rest on the next one.
    private func resolveDetails(client: YTMusicClient, priority: [String], limit: Int) async {
        let pending = Array(self.state.unresolved(priority: priority).prefix(limit).map(\.id))
        for start in stride(from: 0, to: pending.count, by: Self.concurrency) {
            if Task.isCancelled { return }
            let chunk = pending[start ..< min(start + Self.concurrency, pending.count)]
            let details = await withTaskGroup(of: (String, Date?, String?, Int?)?.self) { group in
                for id in chunk {
                    group.addTask {
                        guard let detail = try? await client.getPlaylist(id: id).detail else { return nil }
                        let first = detail.tracks.first(where: \.isPlayable) ?? detail.tracks.first
                        let date = if let videoId = first?.videoId { try? await client.getPublishDate(videoId: videoId) } else { Date?.none }
                        return (id, date, first?.videoId, detail.trackCount ?? detail.tracks.count)
                    }
                }
                var details: [(String, Date?, String?, Int?)] = []
                for await detail in group {
                    if let detail { details.append(detail) }
                }
                return details
            }
            for (id, date, videoId, trackCount) in details {
                self.state.resolve(id: id, releaseDate: date, videoId: videoId, trackCount: trackCount)
            }
            self.save()
        }
    }

    // MARK: - Notification

    /// Puts the releases just found into the notification of their delivery day, with the ones
    /// already waiting for it (same identifier: a second check before 8:00 updates the pending
    /// notification instead of adding one).
    private func announce(_ ids: Set<String>) async {
        guard Self.notificationsEnabled else { return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }

        let now = Date.now
        let delivery = NewReleaseSchedule.deliveryDate(foundAt: now)
        let day = NewReleaseSchedule.dayKey(for: delivery)
        for index in self.state.releases.indices where ids.contains(self.state.releases[index].id) {
            self.state.releases[index].notificationDay = day
        }
        self.save()
        let releases = self.state.releases.filter { $0.notificationDay == day }
        guard !releases.isEmpty else { return }

        let content = UNMutableNotificationContent()
        if releases.count == 1, let release = releases.first {
            content.title = release.isSingle
                ? String(localized: "New single from \(release.artistName)")
                : String(localized: "New album from \(release.artistName)")
            content.body = release.title
            content.userInfo = [
                NotificationRouter.albumIdKey: release.id,
                NotificationRouter.albumTitleKey: release.title,
                NotificationRouter.videoIdKey: release.isSingleTrack ? (release.videoId ?? "") : "",
            ]
        } else {
            content.title = String(localized: "\(releases.count) new releases")
            let listed = releases.prefix(3).map { "\($0.artistName) – \($0.title)" }.joined(separator: "\n")
            let rest = releases.count - 3
            content.body = rest > 0 ? listed + "\n" + String(localized: "and \(rest) more") : listed
        }
        content.sound = .default
        content.threadIdentifier = "new-releases"

        let trigger: UNNotificationTrigger = delivery > now.addingTimeInterval(60)
            ? UNCalendarNotificationTrigger(
                dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: delivery),
                repeats: false
            )
            : UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: "new-releases-\(day)", content: content, trigger: trigger)
        do {
            try await center.add(request)
            self.log.log("releases", "notification for \(releases.count) release(s) at \(delivery)")
        } catch {
            self.log.log("releases", "notification failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Storage

    private func save() {
        guard let data = try? JSONEncoder().encode(self.state) else { return }
        try? FileManager.default.createDirectory(
            at: self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        // Readable after the first unlock: the morning check runs with the phone locked.
        try? data.write(to: self.fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

/// Notification taps, handed from the notification delegate to the screens.
@MainActor
@Observable
final class NotificationRouter {
    static let shared = NotificationRouter()
    nonisolated static let albumIdKey = "albumId"
    nonisolated static let albumTitleKey = "albumTitle"
    nonisolated static let videoIdKey = "videoId"

    /// Album to open on Home, or one-track single to play; Home clears it once handled.
    var pendingEntity: MediaEntity?
    /// Bumped by a tap with several releases: Home comes to the front, where the shelf lists them.
    var homeRequest = 0

    func open(albumId: String?, title: String?, videoId: String?) {
        if let videoId, !videoId.isEmpty {
            self.pendingEntity = MediaEntity(
                id: "song-\(videoId)", title: title ?? "", subtitle: nil, thumbnailURL: nil,
                target: .song(videoId: videoId), isCircular: false
            )
        } else if let albumId {
            self.pendingEntity = MediaEntity(
                id: "album-\(albumId)", title: title ?? "", subtitle: nil, thumbnailURL: nil,
                target: .album(id: albumId), isCircular: false
            )
        }
        self.homeRequest += 1
    }
}
