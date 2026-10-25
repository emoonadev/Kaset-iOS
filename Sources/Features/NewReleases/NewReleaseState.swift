import Foundation

/// An album or single that appeared on a followed artist's page since the previous check.
struct NewRelease: Codable, Hashable, Identifiable {
    let id: String
    let title: String
    let artistId: String
    let artistName: String
    let thumbnailURL: URL?
    let year: String?
    let isSingle: Bool
    let foundAt: Date
    /// Day key (`yyyy-MM-dd`) of the notification that announces it; `nil` until scheduled.
    var notificationDay: String?
    /// Filled from the release page after it is found: the first track's publication date
    /// (pages only give the year), its video, and the number of tracks.
    var releaseDate: Date?
    var videoId: String?
    var trackCount: Int?
    var detailsResolved: Bool?
    /// Shelved on the artist's first visit (never announced), rather than found as new.
    var isFromFirstVisit: Bool?

    /// What the shelf is ordered by: the release date when known.
    var sortDate: Date { self.releaseDate ?? self.foundAt }

    /// A one-track single is shown and played as a song, not as a one-song playlist.
    var isSingleTrack: Bool { self.trackCount == 1 && self.videoId != nil }
}

/// What the check remembers between runs. Pure value + rules so it can be tested without the
/// network, the scheduler or the notification center.
struct NewReleaseState: Codable, Equatable {
    /// Release ids already seen on each artist page (key: public channel id). An artist with
    /// no entry has not been visited yet: its current releases are recorded, not announced.
    var seen: [String: Set<String>] = [:]
    var releases: [NewRelease] = []
    /// Last artist checked, so the next run continues from there when a run cannot do them all.
    var cursor: String?
    var lastCheck: Date?
    /// Shown in Settings: what the last check did.
    var lastResult: CheckResult?

    struct CheckResult: Codable, Equatable {
        var date: Date
        var checked: Int
        var artists: Int
        var found: Int
        var failure: String?
    }

    /// Releases stay on the Home shelf this long after they came out (or were found, while the
    /// release date is unknown).
    static let shelfLifetime: TimeInterval = 60 * 24 * 60 * 60

    /// Most recent first. A release waits off the shelf until its page has been read: without
    /// its date it cannot be placed.
    var shelf: [NewRelease] {
        self.releases.filter { $0.detailsResolved == true }.sorted { $0.sortDate > $1.sortDate }
    }

    /// Releases whose page has not been read yet, in reading order: the ones found as new
    /// first (they may be announced), then by artist in `priority` order.
    func unresolved(priority: [String] = []) -> [NewRelease] {
        let rank = Dictionary(priority.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return self.releases.filter { $0.detailsResolved != true }.sorted {
            let new0 = $0.isFromFirstVisit != true, new1 = $1.isFromFirstVisit != true
            if new0 != new1 { return new0 }
            return (rank[$0.artistId] ?? .max) < (rank[$1.artistId] ?? .max)
        }
    }

    mutating func resolve(id: String, releaseDate: Date?, videoId: String?, trackCount: Int?) {
        guard let index = self.releases.firstIndex(where: { $0.id == id }) else { return }
        self.releases[index].releaseDate = releaseDate
        self.releases[index].videoId = videoId
        self.releases[index].trackCount = trackCount
        self.releases[index].detailsResolved = true
    }

    /// Records one artist's page and returns the releases to announce: the ones that appeared
    /// since the last visit. On the first visit nothing is announced, but the artist's latest
    /// releases of the year (first of each shelf, newest first) go on the shelf, so music that
    /// came out before the first check still shows up; once their release date is known, the
    /// ones older than the shelf lifetime are pruned.
    mutating func record(
        artistId: String, artistName: String, albums: [Album], singles: [Album],
        now: Date, calendar: Calendar = .current
    ) -> [NewRelease] {
        let items = albums.map { ($0, false) } + singles.map { ($0, true) }
        let ids = Set(items.map(\.0.id))
        let listed = Set(self.releases.map(\.id))
        func release(_ album: Album, isSingle: Bool) -> NewRelease? {
            guard album.hasNavigableId, !listed.contains(album.id),
                  Self.isRecent(year: album.year, now: now, calendar: calendar)
            else { return nil }
            return NewRelease(
                id: album.id, title: album.title, artistId: artistId, artistName: artistName,
                thumbnailURL: album.thumbnailURL, year: album.year, isSingle: isSingle, foundAt: now
            )
        }

        guard let known = self.seen[artistId] else {
            self.seen[artistId] = ids
            var latest = albums.prefix(1).compactMap { release($0, isSingle: false) }
                + singles.prefix(2).compactMap { release($0, isSingle: true) }
            for index in latest.indices { latest[index].isFromFirstVisit = true }
            self.releases.append(contentsOf: latest)
            return []
        }
        let found = items.filter { !known.contains($0.0.id) }.compactMap { release($0.0, isSingle: $0.1) }
        // Keep ids that scrolled off the shelf too, so they are not announced again if they come back.
        self.seen[artistId] = known.union(ids)
        self.releases.insert(contentsOf: found, at: 0)
        return found
    }

    /// Drops shelf entries past their lifetime and artists no longer followed.
    mutating func prune(followed: Set<String>?, now: Date) {
        self.releases.removeAll { now.timeIntervalSince($0.sortDate) > Self.shelfLifetime }
        if let followed { self.seen = self.seen.filter { followed.contains($0.key) } }
    }

    /// A page only gives the year. Something never seen before with an older year is an old
    /// release resurfacing (shelf reordering), not a new one. Releases from late December still
    /// count in January. No readable year: kept.
    static func isRecent(year: String?, now: Date, calendar: Calendar = .current) -> Bool {
        guard let year, let value = Int(year.trimmingCharacters(in: .whitespaces)) else { return true }
        let current = calendar.component(.year, from: now)
        if value >= current { return true }
        return value == current - 1 && calendar.component(.month, from: now) == 1
    }

    /// The next artists to check: the `priority` ones first, every run, then the others in
    /// turn (continuing after `cursor`, wrapping around) up to `limit`.
    static func batch(_ artistIds: [String], priority: [String] = [], after cursor: String?, limit: Int) -> [String] {
        let first = Array(priority.prefix(limit))
        let prioritized = Set(first)
        let others = artistIds.filter { !prioritized.contains($0) }.sorted()
        let room = limit - first.count
        guard others.count > room else { return first + others }
        let start = cursor.flatMap { cursor in others.firstIndex { $0 > cursor } } ?? 0
        return first + (0 ..< room).map { others[(start + $0) % others.count] }
    }

    /// Order of importance: artists by how often they appear in the listening history
    /// (most first); followed artists qualify with one play, others need `minimumUnfollowedPlays`.
    static func priority(
        plays: [String: Int], followed: Set<String>, limit: Int, minimumUnfollowedPlays: Int = 3
    ) -> [String] {
        plays
            .filter { id, count in followed.contains(id) ? count > 0 : count >= minimumUnfollowedPlays }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(limit)
            .map(\.key)
    }
}

/// When things happen: the morning check and the 8:00 notification.
enum NewReleaseSchedule {
    static let checkHour = 7
    static let notificationHour = 8
    /// Found later than this: announced the next morning instead of at night.
    static let quietHour = 22

    /// Earliest start of the next background check: the next 7:00. iOS starts it some time
    /// after that, depending on how the app is used.
    static func nextCheck(after now: Date, calendar: Calendar = .current) -> Date {
        calendar.nextDate(
            after: now, matching: DateComponents(hour: self.checkHour, minute: 0), matchingPolicy: .nextTime
        ) ?? now.addingTimeInterval(24 * 60 * 60)
    }

    /// When to show the notification: 8:00 when found before it, right away during the day,
    /// the next 8:00 when found late in the evening.
    static func deliveryDate(foundAt now: Date, calendar: Calendar = .current) -> Date {
        let hour = calendar.component(.hour, from: now)
        guard hour < self.notificationHour || hour >= self.quietHour else { return now }
        return calendar.nextDate(
            after: now, matching: DateComponents(hour: self.notificationHour, minute: 0), matchingPolicy: .nextTime
        ) ?? now
    }

    /// Key of a delivery date's day: one notification per day gathers everything it announces.
    static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    /// A check is due when none ran for most of a day (catch-up when the app comes to the front).
    static func isDue(lastCheck: Date?, now: Date) -> Bool {
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) > 20 * 60 * 60
    }
}
