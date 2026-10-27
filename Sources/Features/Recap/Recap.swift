import Foundation

/// The span a recap covers: a calendar week, month or year.
enum RecapPeriod: String, CaseIterable, Identifiable, Sendable {
    case week, month, year

    var id: String { self.rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .week: "Week"
        case .month: "Month"
        case .year: "Year"
        }
    }

    var component: Calendar.Component {
        switch self {
        case .week: .weekOfYear
        case .month: .month
        case .year: .year
        }
    }
}

struct RecapInterval: Equatable, Sendable {
    let period: RecapPeriod
    let start: Date
    let end: Date

    /// The period containing `date`.
    init(period: RecapPeriod, containing date: Date, calendar: Calendar = .current) {
        let interval = calendar.dateInterval(of: period.component, for: date)!
        self.period = period
        self.start = interval.start
        self.end = interval.end
    }

    /// The period `offset` steps before (negative) or after this one.
    func shifted(by offset: Int, calendar: Calendar = .current) -> RecapInterval {
        let date = calendar.date(byAdding: self.period.component, value: offset, to: self.start)!
        return RecapInterval(period: self.period, containing: date, calendar: calendar)
    }

    func contains(_ date: Date) -> Bool { date >= self.start && date < self.end }

    /// "27 Oct – 2 Nov", "October 2026", "2026".
    func title(calendar: Calendar = .current) -> String {
        switch self.period {
        case .week:
            let last = calendar.date(byAdding: .day, value: -1, to: self.end)!
            let style = Date.FormatStyle(date: .omitted, time: .omitted).day().month(.abbreviated)
            return "\(self.start.formatted(style)) – \(last.formatted(style))"
        case .month:
            return self.start.formatted(.dateTime.month(.wide).year())
        case .year:
            return self.start.formatted(.dateTime.year())
        }
    }
}

/// What a recap shows, computed from the play log.
struct Recap: Equatable, Sendable {
    struct ArtistStat: Equatable, Identifiable, Sendable {
        let name: String
        let seconds: TimeInterval
        let plays: Int
        /// Cover of the artist's most played song in the period, as their picture.
        let artworkURL: URL?
        var id: String { self.name }
        var minutes: Int { Int(self.seconds / 60) }
    }

    struct TrackStat: Equatable, Identifiable, Sendable {
        let videoId: String
        let title: String
        let artist: String
        let artworkURL: URL?
        let plays: Int
        let seconds: TimeInterval
        var id: String { self.videoId }
    }

    let interval: RecapInterval
    let seconds: TimeInterval
    let plays: Int
    /// Listening time of the period before, for the comparison.
    let previousSeconds: TimeInterval
    let topArtists: [ArtistStat]
    let topTracks: [TrackStat]
    /// Minutes listened in each hour of the day (index 0 = midnight).
    let minutesByHour: [Int]
    /// Artists played for the first time in this period; `nil` when the log started during
    /// the period (everything would look new).
    let newArtists: [String]?

    /// Distinct artists played in the period.
    let artistCount: Int

    var minutes: Int { Int(self.seconds / 60) }

    /// Change from the previous period, as a fraction (`0.12` = +12 %); `nil` without data.
    var change: Double? {
        guard self.previousSeconds >= 60 else { return nil }
        return (self.seconds - self.previousSeconds) / self.previousSeconds
    }

    /// The busiest hour of the day, when there is any listening.
    var peakHour: Int? {
        guard let max = self.minutesByHour.max(), max > 0 else { return nil }
        return self.minutesByHour.firstIndex(of: max)
    }

    init(
        plays log: [ListenedPlay], interval: RecapInterval, calendar: Calendar = .current,
        artistLimit: Int = 5, trackLimit: Int = 10
    ) {
        self.interval = interval
        let plays = log.filter { interval.contains($0.startedAt) }
        let previous = interval.shifted(by: -1, calendar: calendar)
        self.previousSeconds = log.filter { previous.contains($0.startedAt) }.reduce(0) { $0 + $1.seconds }
        self.seconds = plays.reduce(0) { $0 + $1.seconds }
        self.plays = plays.count

        var tracks: [String: (play: ListenedPlay, count: Int, seconds: TimeInterval)] = [:]
        for play in plays {
            let entry = tracks[play.videoId]
            // Keep the latest metadata (titles get fixed, artwork changes size).
            tracks[play.videoId] = (play, (entry?.count ?? 0) + 1, (entry?.seconds ?? 0) + play.seconds)
        }
        let rankedTracks = tracks.values.sorted {
            $0.count != $1.count ? $0.count > $1.count : $0.seconds > $1.seconds
        }
        self.topTracks = rankedTracks.prefix(trackLimit).map {
            TrackStat(
                videoId: $0.play.videoId, title: $0.play.title, artist: $0.play.artist,
                artworkURL: $0.play.artworkURL, plays: $0.count, seconds: $0.seconds
            )
        }

        var artists: [String: (seconds: TimeInterval, plays: Int)] = [:]
        for play in plays where !play.artist.isEmpty {
            let entry = artists[play.artist]
            artists[play.artist] = ((entry?.seconds ?? 0) + play.seconds, (entry?.plays ?? 0) + 1)
        }
        self.artistCount = artists.count
        let artworkByArtist = Dictionary(
            rankedTracks.map { ($0.play.artist, $0.play.artworkURL) }, uniquingKeysWith: { first, _ in first }
        )
        self.topArtists = artists
            .sorted { $0.value.seconds != $1.value.seconds ? $0.value.seconds > $1.value.seconds : $0.key < $1.key }
            .prefix(artistLimit)
            .map { ArtistStat(name: $0.key, seconds: $0.value.seconds, plays: $0.value.plays, artworkURL: artworkByArtist[$0.key] ?? nil) }

        var hours = Array(repeating: 0.0, count: 24)
        for play in plays {
            hours[calendar.component(.hour, from: play.startedAt)] += play.seconds
        }
        self.minutesByHour = hours.map { Int($0 / 60) }

        if let first = log.map(\.startedAt).min(), first < interval.start {
            let before = Set(log.filter { $0.startedAt < interval.start }.map(\.artist))
            // In order of first play in the period.
            var seen = Set<String>()
            self.newArtists = plays.sorted { $0.startedAt < $1.startedAt }.compactMap { play in
                guard !play.artist.isEmpty, !before.contains(play.artist), seen.insert(play.artist).inserted else { return nil }
                return play.artist
            }
        } else {
            self.newArtists = nil
        }
    }
}
