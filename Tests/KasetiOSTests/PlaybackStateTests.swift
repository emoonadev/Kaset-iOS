import Foundation
import Testing

@testable import KasetiOS

struct PlaybackStateTests {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    @Test func appliesPlayingMessage() {
        let state = PlaybackState().applying([
            "kind": "state", "paused": false, "ended": false, "currentTime": 12.5, "duration": 200.0,
            "videoId": "abc", "title": "Song", "artist": "Artist", "artwork": "https://example.com/a.jpg",
            "canNext": true, "canPrevious": false, "vis": "hidden",
        ], at: self.t0)
        #expect(state.isPlaying)
        #expect(state.hasMedia)
        #expect(state.position == 12.5)
        #expect(state.duration == 200)
        #expect(state.videoId == "abc")
        #expect(state.artworkURL?.absoluteString == "https://example.com/a.jpg")
        #expect(state.canGoNext && !state.canGoPrevious)
        #expect(state.visibility == "hidden")
    }

    @Test func pausedAndEndedAreNotPlaying() {
        let paused = PlaybackState().applying(["paused": true, "ended": false])
        #expect(!paused.isPlaying && paused.hasMedia)
        let ended = PlaybackState().applying(["paused": false, "ended": true])
        #expect(!ended.isPlaying)
    }

    @Test func nullPausedMeansNoMedia() {
        let playing = PlaybackState().applying(["paused": false, "ended": false])
        let gone = playing.applying(["paused": NSNull()])
        #expect(!gone.hasMedia && !gone.isPlaying)
    }

    @Test func absentKeysKeepPreviousValues() {
        let first = PlaybackState().applying(["paused": false, "title": "A", "queue": [["videoId": "x", "title": "X", "artist": "Y", "current": true]]])
        let second = first.applying(["paused": false, "currentTime": 3.0])
        #expect(second.title == "A")
        #expect(second.queue.count == 1)
        #expect(second.queue[0].isCurrent)
    }

    @Test func nullTitleClearsIt() {
        let first = PlaybackState().applying(["title": "A"])
        #expect(first.applying(["title": NSNull()]).title == nil)
    }

    @Test func positionExtrapolatesOnlyWhilePlaying() {
        var state = PlaybackState().applying(["paused": false, "ended": false, "currentTime": 10.0, "duration": 100.0], at: self.t0)
        #expect(state.position(at: self.t0.addingTimeInterval(5)) == 15)
        #expect(state.position(at: self.t0.addingTimeInterval(500)) == 100)
        state = state.applying(["paused": true, "ended": false, "currentTime": 20.0], at: self.t0)
        #expect(state.position(at: self.t0.addingTimeInterval(30)) == 20)
    }

    @Test func scriptLiteralEscapes() {
        #expect(PlayerScripts.literal("a\"b") == "\"a\\\"b\"")
    }
}

struct PlaybackStateExtrasTests {
    @Test func parsesShuffleRepeatAndList() {
        let state = PlaybackState().applying([
            "paused": false, "ended": false, "listId": "RDAMVMabc", "shuffle": true, "repeat": "one",
        ])
        #expect(state.listId == "RDAMVMabc")
        #expect(state.isShuffleEnabled)
        #expect(state.repeatMode == .one)
    }

    @Test func unknownRepeatFallsBackToOff() {
        #expect(PlaybackState().applying(["repeat": "weird"]).repeatMode == .off)
    }

    @Test func playlistBrowseIdPrefixes() {
        #expect(YTMusicClient.playlistBrowseId(for: "PLabc") == "VLPLabc")
        #expect(YTMusicClient.playlistBrowseId(for: "VLPLabc") == "VLPLabc")
        #expect(YTMusicClient.playlistBrowseId(for: "RDCLAK5uy_x") == "RDCLAK5uy_x")
        #expect(YTMusicClient.playlistBrowseId(for: "MPREb_x") == "MPREb_x")
    }

    @Test func contentLanguageFallsBackToEnglish() {
        #expect(ContentLanguage.en.apiCode == "en")
        #expect(ContentLanguage.fr.apiCode == "fr")
        #expect(ContentLanguage.system.apiCode.count == 2)
    }
}

struct AdStateTests {
    @Test func adFlagIsParsed() {
        #expect(PlaybackState().applying(["paused": false, "ad": true]).isAd)
        #expect(!PlaybackState().applying(["paused": false, "ad": false]).isAd)
    }

    @Test func adSkipIsOffByDefault() {
        UserDefaults.standard.removeObject(forKey: AdSkip.storageKey)
        #expect(!AdSkip.isEnabled)
    }
}

struct TrackChangeHoldTests {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    private func playing(_ videoId: String, at time: TimeInterval) -> PlaybackState {
        PlaybackState().applying(["paused": false, "ended": false, "currentTime": time, "duration": 240.0, "videoId": videoId], at: self.t0)
    }

    @Test func skipShowsZeroWhileThePageStillReportsTheOldSong() {
        var state = self.playing("old", at: 125)
        let hold = TrackChangeHold(from: state, at: self.t0)
        state.isChangingTrack = true
        #expect(state.displayedPosition(at: self.t0.addingTimeInterval(0.8)) == 0)
        // The raw position (recap, recovery) keeps following the page.
        #expect(state.position(at: self.t0.addingTimeInterval(0.8)) > 125)

        let lateReport = state.applying(["currentTime": 125.9, "videoId": "old"], at: self.t0.addingTimeInterval(0.9))
        #expect(!hold.isReleased(by: lateReport, at: self.t0.addingTimeInterval(0.9)))
        // The media element can report the new id with the old time for a moment.
        let mixed = state.applying(["currentTime": 126.0, "videoId": "new"], at: self.t0.addingTimeInterval(1))
        #expect(!hold.isReleased(by: mixed, at: self.t0.addingTimeInterval(1)))

        let newSong = state.applying(["currentTime": 0.0, "videoId": "new"], at: self.t0.addingTimeInterval(1.1))
        #expect(hold.isReleased(by: newSong, at: self.t0.addingTimeInterval(1.1)))
    }

    @Test func previousThatRestartsTheSameSongReleasesTheHold() {
        let state = self.playing("song", at: 60)
        let hold = TrackChangeHold(from: state, at: self.t0)
        let restarted = state.applying(["currentTime": 0.2, "videoId": "song"], at: self.t0.addingTimeInterval(0.4))
        #expect(hold.isReleased(by: restarted, at: self.t0.addingTimeInterval(0.4)))
    }

    @Test func earlySkipWaitsForTheNewSongNotForALowTime() {
        let state = self.playing("song", at: 3)
        let hold = TrackChangeHold(from: state, at: self.t0)
        let stillOld = state.applying(["currentTime": 3.4, "videoId": "song"], at: self.t0.addingTimeInterval(0.4))
        #expect(!hold.isReleased(by: stillOld, at: self.t0.addingTimeInterval(0.4)))
    }

    @Test func aSkipThePageIgnoresStopsHoldingAfterTheTimeout() {
        let state = self.playing("last", at: 200)
        let hold = TrackChangeHold(from: state, at: self.t0)
        let unchanged = state.applying(["currentTime": 204.0, "videoId": "last"], at: self.t0.addingTimeInterval(4))
        #expect(!hold.isReleased(by: unchanged, at: self.t0.addingTimeInterval(4)))
        #expect(hold.isReleased(by: unchanged, at: self.t0.addingTimeInterval(TrackChangeHold.timeout)))
    }
}
