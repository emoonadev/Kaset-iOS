import Foundation
import Testing

@testable import KasetiOS

struct NewReleaseStateTests {
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        return calendar
    }

    private static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        self.calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private static func album(_ id: String, year: String? = "2026") -> Album {
        Album(id: "MPRE\(id)", title: "Title \(id)", artists: nil, thumbnailURL: nil, year: year, trackCount: nil)
    }

    private static let now = date(2026, 10, 24, 7, 30)

    @Test func firstVisitAnnouncesNothingButShelvesTheLatestReleasesOfTheYear() {
        var state = NewReleaseState()
        let found = state.record(
            artistId: "UCa", artistName: "A",
            albums: [Self.album("1"), Self.album("0"), Self.album("9")],
            singles: [Self.album("2"), Self.album("old", year: "2020"), Self.album("3"), Self.album("4")],
            now: Self.now, calendar: Self.calendar
        )
        #expect(found.isEmpty)
        #expect(state.seen["UCa"]?.count == 7)
        // Latest album and latest two singles, this year's only.
        #expect(state.releases.map(\.id) == ["MPRE1", "MPRE2"])
        #expect(state.releases.allSatisfy { $0.isFromFirstVisit == true })
        // Not on the shelf before their date is known.
        #expect(state.shelf.isEmpty)
    }

    @Test func shelfIsOrderedByReleaseDateAndOldOnesArePrunedOnceDated() {
        var state = NewReleaseState()
        _ = state.record(
            artistId: "UCa", artistName: "A", albums: [Self.album("feb")], singles: [Self.album("oct")],
            now: Self.now, calendar: Self.calendar
        )
        _ = state.record(artistId: "UCb", artistName: "B", albums: [], singles: [], now: Self.now, calendar: Self.calendar)
        let new = state.record(
            artistId: "UCb", artistName: "B", albums: [Self.album("sep")], singles: [],
            now: Self.now, calendar: Self.calendar
        )
        #expect(new.map(\.id) == ["MPREsep"])
        // Found as new first, then by artist priority.
        #expect(state.unresolved(priority: ["UCa"]).map(\.id) == ["MPREsep", "MPREfeb", "MPREoct"])
        state.resolve(id: "MPREsep", releaseDate: Self.date(2026, 9, 15), videoId: "v3", trackCount: 12)
        #expect(state.shelf.map(\.id) == ["MPREsep"])
        state.resolve(id: "MPREfeb", releaseDate: Self.date(2026, 2, 1), videoId: "v1", trackCount: 10)
        state.resolve(id: "MPREoct", releaseDate: Self.date(2026, 10, 20), videoId: "v2", trackCount: 1)
        #expect(state.unresolved().isEmpty)
        #expect(state.shelf.map(\.id) == ["MPREoct", "MPREsep", "MPREfeb"])
        #expect(state.shelf.first?.isSingleTrack == true)
        #expect(state.shelf.last?.isSingleTrack == false)
        state.prune(followed: nil, now: Self.now)
        #expect(state.shelf.map(\.id) == ["MPREoct", "MPREsep"])
    }

    @Test func publishDatesParseWithOrWithoutTime() {
        let full = YTMusicClient.parsePublishDate("2023-03-30T06:00:07-07:00")
        #expect(full == Date(timeIntervalSince1970: 1_680_181_207))
        #expect(YTMusicClient.parsePublishDate("2023-03-30") != nil)
        #expect(YTMusicClient.parsePublishDate("soon") == nil)
    }

    @Test func aReleaseNotSeenBeforeIsNewOnce() {
        var state = NewReleaseState()
        _ = state.record(artistId: "UCa", artistName: "A", albums: [Self.album("1")], singles: [], now: Self.now, calendar: Self.calendar)
        let found = state.record(
            artistId: "UCa", artistName: "A", albums: [Self.album("1")], singles: [Self.album("3")],
            now: Self.now, calendar: Self.calendar
        )
        #expect(found.map(\.id) == ["MPRE3"])
        #expect(found.first?.isSingle == true)
        #expect(found.first?.artistName == "A")
        let again = state.record(
            artistId: "UCa", artistName: "A", albums: [Self.album("1")], singles: [Self.album("3")],
            now: Self.now, calendar: Self.calendar
        )
        #expect(again.isEmpty)
        #expect(state.releases.map(\.id) == ["MPRE3", "MPRE1"])
    }

    @Test func anOldReleaseResurfacingIsNotNew() {
        var state = NewReleaseState()
        _ = state.record(artistId: "UCa", artistName: "A", albums: [], singles: [], now: Self.now, calendar: Self.calendar)
        let found = state.record(
            artistId: "UCa", artistName: "A", albums: [Self.album("old", year: "2019")], singles: [],
            now: Self.now, calendar: Self.calendar
        )
        #expect(found.isEmpty)
        #expect(state.seen["UCa"] == ["MPREold"])
    }

    @Test func lastYearStillCountsInJanuary() {
        #expect(NewReleaseState.isRecent(year: "2025", now: Self.date(2026, 1, 5), calendar: Self.calendar))
        #expect(!NewReleaseState.isRecent(year: "2025", now: Self.date(2026, 2, 5), calendar: Self.calendar))
        #expect(NewReleaseState.isRecent(year: "Single", now: Self.now, calendar: Self.calendar))
        #expect(NewReleaseState.isRecent(year: nil, now: Self.now, calendar: Self.calendar))
    }

    @Test func pruneDropsOldShelfEntriesAndUnfollowedArtists() {
        var state = NewReleaseState()
        _ = state.record(artistId: "UCa", artistName: "A", albums: [], singles: [], now: Self.now, calendar: Self.calendar)
        _ = state.record(artistId: "UCb", artistName: "B", albums: [], singles: [], now: Self.now, calendar: Self.calendar)
        _ = state.record(artistId: "UCa", artistName: "A", albums: [Self.album("1")], singles: [], now: Self.now, calendar: Self.calendar)
        #expect(state.releases.map(\.id) == ["MPRE1"])
        state.prune(followed: ["UCa"], now: Self.now.addingTimeInterval(61 * 24 * 60 * 60))
        #expect(state.releases.isEmpty)
        #expect(Set(state.seen.keys) == ["UCa"])
    }

    @Test func batchesRotateThroughAllArtists() {
        let ids = ["e", "a", "d", "b", "c"]
        #expect(NewReleaseState.batch(ids, after: nil, limit: 10) == ["a", "b", "c", "d", "e"])
        #expect(NewReleaseState.batch(ids, after: nil, limit: 2) == ["a", "b"])
        #expect(NewReleaseState.batch(ids, after: "b", limit: 2) == ["c", "d"])
        #expect(NewReleaseState.batch(ids, after: "d", limit: 2) == ["e", "a"])
        #expect(NewReleaseState.batch(ids, after: "z", limit: 2) == ["a", "b"])
    }

    @Test func mostPlayedArtistsComeFirstOnEveryRun() {
        let ids = ["a", "b", "c", "d", "e"]
        #expect(NewReleaseState.batch(ids, priority: ["d", "x"], after: nil, limit: 4) == ["d", "x", "a", "b"])
        #expect(NewReleaseState.batch(ids, priority: ["d", "x"], after: "b", limit: 4) == ["d", "x", "c", "e"])
        #expect(NewReleaseState.batch(ids, priority: ["d"], after: nil, limit: 10) == ["d", "a", "b", "c", "e"])
    }

    @Test func priorityRanksByPlaysAndNeedsMorePlaysForArtistsNotFollowed() {
        let plays = ["UCf": 2, "UCg": 9, "UCx": 5, "UCy": 1, "UCz": 3]
        let order = NewReleaseState.priority(plays: plays, followed: ["UCf", "UCg", "UCh"], limit: 10)
        #expect(order == ["UCg", "UCx", "UCz", "UCf"])
        #expect(NewReleaseState.priority(plays: plays, followed: ["UCf", "UCg"], limit: 2) == ["UCg", "UCx"])
    }

    @Test func nextCheckIsTheNextSevenOClock() {
        let early = NewReleaseSchedule.nextCheck(after: Self.date(2026, 10, 24, 5), calendar: Self.calendar)
        #expect(early == Self.date(2026, 10, 24, 7))
        let late = NewReleaseSchedule.nextCheck(after: Self.date(2026, 10, 24, 9), calendar: Self.calendar)
        #expect(late == Self.date(2026, 10, 25, 7))
    }

    @Test func notificationWaitsForEightAndStaysQuietAtNight() {
        let morning = Self.date(2026, 10, 24, 7, 10)
        #expect(NewReleaseSchedule.deliveryDate(foundAt: morning, calendar: Self.calendar) == Self.date(2026, 10, 24, 8))
        let day = Self.date(2026, 10, 24, 14)
        #expect(NewReleaseSchedule.deliveryDate(foundAt: day, calendar: Self.calendar) == day)
        let night = Self.date(2026, 10, 24, 23)
        #expect(NewReleaseSchedule.deliveryDate(foundAt: night, calendar: Self.calendar) == Self.date(2026, 10, 25, 8))
        #expect(NewReleaseSchedule.dayKey(for: Self.date(2026, 3, 4, 8), calendar: Self.calendar) == "2026-03-04")
    }

    @Test func catchUpIsDueAfterMostOfADay() {
        #expect(NewReleaseSchedule.isDue(lastCheck: nil, now: Self.now))
        #expect(!NewReleaseSchedule.isDue(lastCheck: Self.now.addingTimeInterval(-3600), now: Self.now))
        #expect(NewReleaseSchedule.isDue(lastCheck: Self.now.addingTimeInterval(-21 * 3600), now: Self.now))
    }
}
