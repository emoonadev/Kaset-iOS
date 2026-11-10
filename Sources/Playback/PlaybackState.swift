import Foundation

/// What the page is doing, as last reported. The web view owns the truth; this only mirrors it.
enum RepeatMode: String, Equatable, Sendable {
    case off, all, one
}

struct PlaybackState: Equatable, Sendable {
    struct QueueEntry: Equatable, Identifiable, Sendable {
        let index: Int
        let videoId: String
        let title: String
        let artist: String
        let isCurrent: Bool

        var id: Int { self.index }
    }

    var videoId: String?
    /// The `list` of the page address: the playlist / radio the page's queue came from.
    var listId: String?
    var title: String?
    var artist: String?
    var album: String?
    var artworkURL: URL?

    /// `true` while the media element is playing (not paused, not ended).
    var isPlaying = false
    var hasMedia = false
    var position: TimeInterval = 0
    var duration: TimeInterval = 0
    var canGoNext = false
    var canGoPrevious = false
    var queue: [QueueEntry] = []
    /// Best effort, read from the page's player bar (selectors unverified on a device).
    var isShuffleEnabled = false
    /// The page is currently playing an advertisement.
    var isAd = false
    var repeatMode: RepeatMode = .off
    /// Seconds of the current track loaded past the playhead, as last reported.
    var bufferedAhead: TimeInterval?
    var visibility: String?
    var updatedAt = Date.distantPast
    /// Set natively from a skip until the page reports the new track (`TrackChangeHold`).
    var isChangingTrack = false

    /// Position now, extrapolated from the last report while playing.
    func position(at date: Date = Date()) -> TimeInterval {
        guard self.isPlaying else { return self.position }
        let elapsed = max(0, date.timeIntervalSince(self.updatedAt))
        let value = self.position + elapsed
        return self.duration > 0 ? min(value, self.duration) : value
    }

    /// What the progress bar, lyrics and lock screen show: 0 from the tap on next / previous,
    /// while the page still reports the old track for up to a second.
    func displayedPosition(at date: Date = Date()) -> TimeInterval {
        self.isChangingTrack ? 0 : self.position(at: date)
    }

    /// Applies a `state` message from the page script. Absent keys keep their previous value
    /// (the page only sends the queue when it changed); `null` clears the field.
    func applying(_ message: [String: Any], at date: Date = Date()) -> PlaybackState {
        var next = self
        next.updatedAt = date

        if let paused = message["paused"] as? Bool {
            let ended = message["ended"] as? Bool ?? false
            next.hasMedia = true
            next.isPlaying = !paused && !ended
        } else if message.keys.contains("paused") {
            next.hasMedia = false
            next.isPlaying = false
        }

        if message.keys.contains("currentTime") {
            next.position = Self.number(message["currentTime"]) ?? 0
        }
        if message.keys.contains("duration") {
            next.duration = Self.number(message["duration"]) ?? 0
        }
        if message.keys.contains("videoId") {
            next.videoId = Self.string(message["videoId"])
        }
        if message.keys.contains("listId") {
            next.listId = Self.string(message["listId"])
        }
        if message.keys.contains("title") {
            next.title = Self.string(message["title"])
        }
        if message.keys.contains("artist") {
            next.artist = Self.string(message["artist"])
        }
        if message.keys.contains("album") {
            next.album = Self.string(message["album"])
        }
        if message.keys.contains("artwork") {
            next.artworkURL = Self.string(message["artwork"]).flatMap(URL.init(string:))
        }
        if message.keys.contains("buf") {
            next.bufferedAhead = Self.number(message["buf"])
        }
        if let canNext = message["canNext"] as? Bool { next.canGoNext = canNext }
        if let canPrevious = message["canPrevious"] as? Bool { next.canGoPrevious = canPrevious }
        if let vis = message["vis"] as? String { next.visibility = vis }
        if let ad = message["ad"] as? Bool { next.isAd = ad }
        if let shuffle = message["shuffle"] as? Bool { next.isShuffleEnabled = shuffle }
        if let mode = message["repeat"] as? String { next.repeatMode = RepeatMode(rawValue: mode) ?? .off }

        if let rawQueue = message["queue"] as? [[String: Any]] {
            next.queue = rawQueue.enumerated().map { index, item in
                QueueEntry(
                    index: index,
                    videoId: Self.string(item["videoId"]) ?? "",
                    title: Self.string(item["title"]) ?? "",
                    artist: Self.string(item["artist"]) ?? "",
                    isCurrent: item["current"] as? Bool ?? false
                )
            }
        }
        return next
    }

    private static func string(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber: number.doubleValue
        case let double as Double: double
        default: nil
        }
    }
}

/// What is playing, reduced to what lists and covers need to light up their "now playing"
/// indicator. Separate from `PlaybackState` so views that read it are only invalidated when
/// the track, list or play/pause state really changes, not on every position update.
struct PlaybackIdentity: Equatable, Sendable {
    var videoId: String?
    var listId: String?
    var album: String?
    var isPlaying = false
}

/// Holds the displayed position at 0 from a skip until the page shows the change: another
/// track, or the same one started again (previous restarts a song past its first seconds).
/// The page keeps reporting the old song in the meantime, so the bar would keep running on it.
struct TrackChangeHold: Equatable, Sendable {
    let fromVideoId: String
    let fromPosition: TimeInterval
    /// A skip the page ignored (end of the queue) must not freeze the bar for good.
    let until: Date

    static let timeout: TimeInterval = 5

    init(from state: PlaybackState, at date: Date) {
        self.fromVideoId = state.videoId ?? ""
        self.fromPosition = state.position(at: date)
        self.until = date.addingTimeInterval(Self.timeout)
    }

    /// Whether a report just applied (`state`) shows the change has happened.
    func isReleased(by state: PlaybackState, at date: Date) -> Bool {
        if date >= self.until { return true }
        // A new track starts at 0; the media element can still hold the old time for a moment.
        guard state.position <= 5 else { return false }
        return state.videoId != self.fromVideoId || state.position < self.fromPosition - 1
    }
}
