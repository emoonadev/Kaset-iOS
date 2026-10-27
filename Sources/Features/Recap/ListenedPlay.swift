import Foundation

/// One play of a song, recorded on the device once it was listened to long enough.
/// `seconds` keeps growing while the same play goes on.
struct ListenedPlay: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    let videoId: String
    var title: String
    var artist: String
    var album: String?
    var artworkURL: URL?
    let startedAt: Date
    /// Time actually listened (paused time and ads do not count).
    var seconds: TimeInterval
}

/// The play log as written to disk and to the sync file.
struct ListeningLog: Codable, Equatable, Sendable {
    var version = 1
    var plays: [ListenedPlay] = []

    /// Union of two logs (this device and the sync file): one entry per play id, keeping the
    /// longest listening time when both sides have it. Sorted oldest first.
    func merged(with other: ListeningLog) -> ListeningLog {
        var byId = Dictionary(self.plays.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for play in other.plays {
            if let mine = byId[play.id], mine.seconds >= play.seconds { continue }
            byId[play.id] = play
        }
        return ListeningLog(version: self.version, plays: byId.values.sorted { $0.startedAt < $1.startedAt })
    }

    static func decode(_ data: Data) throws -> ListeningLog {
        try self.decoder.decode(ListeningLog.self, from: data)
    }

    func encoded() throws -> Data {
        try Self.encoder.encode(self)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// Turns the stream of playback states into plays. Pure value so it can be tested without the
/// web view: feed it every state the page reports, store what it returns.
struct PlayTracker: Equatable, Sendable {
    /// A play counts after this much listening (half the song for songs shorter than a minute).
    static let threshold: TimeInterval = 30
    /// Longest gap between two reports that still counts as listening; longer gaps mean the
    /// page was suspended or the report was lost.
    static let maxGap: TimeInterval = 15

    private(set) var current: ListenedPlay?
    /// The current play crossed the threshold and is in the log.
    private(set) var isRecorded = false
    private var lastUpdate: Date?
    private var wasPlaying = false
    private var lastPosition: TimeInterval = 0

    /// Applies a reported state. Returns the play to insert or update in the log, if any.
    mutating func update(with state: PlaybackState, at now: Date) -> ListenedPlay? {
        defer {
            self.lastUpdate = now
            self.wasPlaying = state.isPlaying && !state.isAd
            if !state.isAd { self.lastPosition = state.position }
        }
        guard let videoId = state.videoId, state.hasMedia else {
            self.current = nil
            return nil
        }
        if state.isAd { return nil }

        // Repeat one (or starting the same song again): same video, back to the start.
        let restarted = self.current?.videoId == videoId && state.position < 5 && self.lastPosition > state.position + 30
        if self.current?.videoId != videoId || restarted {
            self.current = ListenedPlay(
                id: UUID(), videoId: videoId, title: state.title ?? "", artist: state.artist ?? "",
                album: state.album, artworkURL: state.artworkURL, startedAt: now, seconds: 0
            )
            self.isRecorded = false
            return nil
        }
        guard var play = self.current else { return nil }

        // Metadata can arrive a moment after the video id.
        if let title = state.title { play.title = title }
        if let artist = state.artist { play.artist = artist }
        if state.album != nil { play.album = state.album }
        if state.artworkURL != nil { play.artworkURL = state.artworkURL }

        if self.wasPlaying, let lastUpdate = self.lastUpdate {
            let gap = now.timeIntervalSince(lastUpdate)
            if gap > 0, gap <= Self.maxGap { play.seconds += gap }
        }
        self.current = play

        let needed = state.duration > 0 ? min(Self.threshold, state.duration / 2) : Self.threshold
        guard play.seconds >= needed, !play.title.isEmpty else { return nil }
        self.isRecorded = true
        return play
    }
}
