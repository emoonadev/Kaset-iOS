import Foundation
import Testing

@testable import KasetiOS

@MainActor
struct MixEditorModelTests {
    private static func artist(_ id: String, photo: String? = nil) -> MixArtist {
        MixArtist(id: id, name: id.uppercased(), thumbnailURL: photo.flatMap(URL.init(string:)))
    }

    @Test func togglesArtistsInAndOut() {
        let model = MixEditorModel()
        let artist = Self.artist("UCa")
        #expect(!model.canSave)
        model.toggle(artist)
        #expect(model.isSelected(artist))
        #expect(model.canSave)
        model.toggle(artist)
        #expect(model.mix.artists.isEmpty)
    }

    @Test func discoveryShareRoundsToWholePercents() {
        let model = MixEditorModel()
        model.discoveryShare = 0.30000000000000004
        #expect(model.mix.discoveryPercent == 30)
        #expect(model.discoveryShare == 0.3)
    }

    @Test func mergesSuggestionsHistoryFirstWithFollowedPhotos() {
        let merged = MixEditorModel.mergeSuggestions(
            history: [Self.artist("UCb"), Self.artist("UCa")],
            followed: [Self.artist("UCa", photo: "https://example.com/a.jpg"), Self.artist("UCc")],
            limit: 2
        )
        #expect(merged.map(\.id) == ["UCb", "UCa"])
        #expect(merged[1].thumbnailURL?.absoluteString == "https://example.com/a.jpg")
    }
}
