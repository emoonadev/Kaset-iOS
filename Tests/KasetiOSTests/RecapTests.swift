import Foundation
import Testing

@testable import KasetiOS

struct PlayTrackerTests {
    private static let start = Date(timeIntervalSince1970: 1_800_000_000)

    private static func state(_ videoId: String?, playing: Bool = true, at position: TimeInterval = 0, duration: TimeInterval = 200, ad: Bool = false) -> PlaybackState {
        var state = PlaybackState()
        state.videoId = videoId
        state.hasMedia = videoId != nil
        state.isPlaying = playing
        state.position = position
        state.duration = duration
        state.title = videoId.map { "Song \($0)" }
        state.artist = "Artist"
        state.isAd = ad
        return state
    }

    /// Feeds a heartbeat every 2 s for `seconds`, returns the last play reported.
    @discardableResult
    private static func play(_ tracker: inout PlayTracker, _ videoId: String, from: TimeInterval, for seconds: TimeInterval, duration: TimeInterval = 200, playing: Bool = true, ad: Bool = false) -> ListenedPlay? {
        var last: ListenedPlay?
        var t: TimeInterval = 0
        while t <= seconds {
            let state = self.state(videoId, playing: playing, at: t, duration: duration, ad: ad)
            if let play = tracker.update(with: state, at: self.start.addingTimeInterval(from + t)) { last = play }
            t += 2
        }
        return last
    }

    @Test func playCountsAfterThirtySeconds() {
        var tracker = PlayTracker()
        #expect(Self.play(&tracker, "a", from: 0, for: 28) == nil)
        let play = Self.play(&tracker, "a", from: 30, for: 10)
        #expect(play?.videoId == "a")
        #expect(play?.title == "Song a")
        #expect(play?.startedAt == Self.start)
    }

    @Test func pausedTimeAndAdsDoNotCount() {
        var tracker = PlayTracker()
        Self.play(&tracker, "a", from: 0, for: 10)
        #expect(Self.play(&tracker, "a", from: 12, for: 60, playing: false) == nil)
        #expect(Self.play(&tracker, "a", from: 74, for: 60, ad: true) == nil)
        #expect(tracker.current?.seconds ?? 0 < 30)
    }

    @Test func shortSongCountsAfterHalfItsLength() {
        var tracker = PlayTracker()
        #expect(Self.play(&tracker, "a", from: 0, for: 20, duration: 40) != nil)
    }

    @Test func gapsLongerThanTheLimitAreIgnored() {
        var tracker = PlayTracker()
        Self.play(&tracker, "a", from: 0, for: 4)
        _ = tracker.update(with: Self.state("a", at: 300), at: Self.start.addingTimeInterval(300))
        #expect(tracker.current?.seconds == 4)
    }

    @Test func newTrackStartsANewPlayAndRepeatToo() {
        var tracker = PlayTracker()
        let first = Self.play(&tracker, "a", from: 0, for: 190)
        let second = Self.play(&tracker, "a", from: 200, for: 40)
        #expect(first != nil && second != nil)
        #expect(first?.id != second?.id)
        let third = Self.play(&tracker, "b", from: 250, for: 40)
        #expect(third?.videoId == "b")
    }
}

struct ListeningLogTests {
    private static func play(_ id: UUID = UUID(), seconds: TimeInterval, at time: TimeInterval = 0) -> ListenedPlay {
        ListenedPlay(id: id, videoId: "v", title: "T", artist: "A", startedAt: Date(timeIntervalSince1970: time), seconds: seconds)
    }

    @Test func mergeIsAUnionKeepingTheLongestPlay() throws {
        let shared = UUID()
        let mine = ListeningLog(plays: [Self.play(shared, seconds: 40, at: 10), Self.play(seconds: 60, at: 5)])
        let theirs = ListeningLog(plays: [Self.play(shared, seconds: 90, at: 10), Self.play(seconds: 30, at: 20)])
        let merged = mine.merged(with: theirs)
        #expect(merged.plays.count == 3)
        #expect(merged.plays.first { $0.id == shared }?.seconds == 90)
        #expect(merged.plays.map(\.startedAt) == merged.plays.map(\.startedAt).sorted())
        #expect(theirs.merged(with: mine) == merged)

        let roundTrip = try ListeningLog.decode(merged.encoded())
        #expect(roundTrip.plays.map(\.id) == merged.plays.map(\.id))
    }
}

struct RecapTests {
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        calendar.firstWeekday = 2
        return calendar
    }

    private static func date(_ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        self.calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }

    private static func play(_ videoId: String, _ artist: String, _ date: Date, minutes: Double = 3) -> ListenedPlay {
        ListenedPlay(id: UUID(), videoId: videoId, title: "Song \(videoId)", artist: artist, startedAt: date, seconds: minutes * 60)
    }

    @Test func intervalsFollowTheCalendar() {
        let week = RecapInterval(period: .week, containing: Self.date(10, 28), calendar: Self.calendar)
        #expect(week.start == Self.calendar.startOfDay(for: Self.date(10, 26)))
        #expect(week.shifted(by: -1, calendar: Self.calendar).start == Self.calendar.startOfDay(for: Self.date(10, 19)))
        let month = RecapInterval(period: .month, containing: Self.date(10, 28), calendar: Self.calendar)
        #expect(month.contains(Self.date(10, 1, 0)))
        #expect(!month.contains(Self.date(11, 1, 0)))
    }

    @Test func statsForAMonth() {
        let log = [
            Self.play("old", "Before", Self.date(9, 10)),
            Self.play("a", "A", Self.date(10, 2, 8)),
            Self.play("a", "A", Self.date(10, 3, 8)),
            Self.play("b", "B", Self.date(10, 4, 22), minutes: 10),
            Self.play("c", "Before", Self.date(10, 5, 8)),
            Self.play("next", "A", Self.date(11, 2)),
        ]
        let interval = RecapInterval(period: .month, containing: Self.date(10, 15), calendar: Self.calendar)
        let recap = Recap(plays: log, interval: interval, calendar: Self.calendar)
        #expect(recap.plays == 4)
        #expect(recap.minutes == 19)
        #expect(recap.artistCount == 3)
        #expect(recap.topArtists.map(\.name) == ["B", "A", "Before"])
        #expect(recap.topTracks.first?.videoId == "a")
        #expect(recap.topTracks.first?.plays == 2)
        #expect(recap.minutesByHour[8] == 9)
        #expect(recap.peakHour == 22)
        #expect(recap.newArtists == ["A", "B"])
        #expect(recap.previousSeconds == 180)
        #expect(recap.change.map { abs($0 - (19 * 60 - 180) / 180.0) < 0.001 } == true)
    }

    @Test func noNewArtistsWhenTheLogStartedDuringThePeriod() {
        let log = [Self.play("a", "A", Self.date(10, 2))]
        let interval = RecapInterval(period: .month, containing: Self.date(10, 15), calendar: Self.calendar)
        let recap = Recap(plays: log, interval: interval, calendar: Self.calendar)
        #expect(recap.newArtists == nil)
        #expect(recap.change == nil)
    }
}
