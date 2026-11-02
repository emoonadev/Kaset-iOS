import Foundation
import Testing

@testable import KasetiOS

struct MusicIntentTextTests {
    @Test func queryIsCleanedUpAndPutOnOneLine() {
        #expect(MusicIntentText.normalizedQuery("  Hallelujah\n  Leonard   Cohen ") == "Hallelujah Leonard Cohen")
        #expect(MusicIntentText.normalizedQuery(" \n\t ") == nil)
    }

    @Test func playlistTitleMatchIgnoresCaseAndAccents() {
        #expect(MusicIntentText.title("Été à Paris", matches: "ete a"))
        #expect(!MusicIntentText.title("Workout", matches: "night"))
    }

    @Test func largestTextIsSearchedFirstThenWithTheNextLine() {
        let lines = [
            MusicIntentText.ImageLine(text: "World Tour", height: 0.05),
            MusicIntentText.ImageLine(text: "Metallica", height: 0.2),
            MusicIntentText.ImageLine(text: "Tickets", height: 0.01),
        ]
        #expect(MusicIntentText.imageQueries(from: lines) == ["Metallica", "Metallica World Tour"])
    }

    @Test func imageTextWithoutLettersIsIgnored() {
        let lines = [
            MusicIntentText.ImageLine(text: "12.06.2026", height: 0.3),
            MusicIntentText.ImageLine(text: "Adele", height: 0.1),
        ]
        #expect(MusicIntentText.imageQueries(from: lines) == ["Adele"])
        #expect(MusicIntentText.imageQueries(from: [.init(text: "2026", height: 0.3)]).isEmpty)
    }

    @Test func repeatedImageLineGivesOneQuery() {
        let lines = [
            MusicIntentText.ImageLine(text: "ADELE", height: 0.2),
            MusicIntentText.ImageLine(text: "Adele", height: 0.1),
        ]
        #expect(MusicIntentText.imageQueries(from: lines) == ["ADELE"])
    }
}

struct MusicItemEntityTests {
    @Test(arguments: [
        MediaEntity.Target.song(videoId: "v1"), .album(id: "MPREb_x"), .artist(id: "UC1"), .playlist(id: "VLPL:with:colons"),
    ])
    func targetSurvivesTheIdentifier(target: MediaEntity.Target) throws {
        let identifier = try #require(MusicItemEntity.identifier(for: target))
        #expect(MusicItemEntity.target(for: identifier) == target)
    }

    @Test func whatCannotBeOpenedHasNoEntity() {
        let mood = MediaEntity(
            id: "m", title: "Chill", subtitle: nil, thumbnailURL: nil,
            target: .mood(browseId: "b", params: nil), isCircular: false
        )
        #expect(MusicItemEntity(mood) == nil)
    }

    @Test func malformedIdentifiersAreRejected() {
        #expect(MusicItemEntity(id: "video:abc") == nil)
        #expect(MusicItemEntity(id: "album:") == nil)
        #expect(MusicItemEntity(id: "nonsense") == nil)
    }

    @Test func itemKnownByIdStillOpens() throws {
        let entity = try #require(MusicItemEntity(id: "artist:UC1")?.mediaEntity)
        #expect(entity.target == .artist(id: "UC1"))
        #expect(entity.isCircular)
    }
}

@MainActor
struct IntentWiringTests {
    @Test func likingWithNothingPlayingFailsWithAMessage() async {
        await #expect(throws: MusicIntentError.self) {
            _ = try await LikeCurrentSongIntent().perform()
        }
    }
}

@MainActor
struct IntentPlaylistTests {
    private func playlist(_ id: String, mood: Bool = false) -> Playlist {
        Playlist(
            id: id, title: id, description: nil, thumbnailURL: nil, trackCount: nil,
            moodCategoryEndpoint: mood ? MoodCategoryEndpoint(browseId: "b", params: nil) : nil
        )
    }

    @Test func likedMusicComesFirstOnceAndUnplayableEntriesAreDropped() {
        let result = AppEnvironment.playableIntentPlaylists([
            self.playlist("VLPLa"), self.playlist("VLLM"),
            self.playlist(Playlist.uploadedSongsBrowseID), self.playlist("mood", mood: true),
        ])
        #expect(result.map(\.id) == [LikedMusicPlaylist.id, "VLPLa"])
    }
}
