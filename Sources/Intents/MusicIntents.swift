import AppIntents
import Foundation

enum MusicIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notSignedIn
    case nothingPlaying
    case emptySearch
    case noSong(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notSignedIn: "Sign in to YouTube Music in Kaset first."
        case .nothingPlaying: "Nothing is playing in Kaset."
        case .emptySearch: "There is nothing to search for."
        case let .noSong(query): "No song found for \(query)."
        }
    }
}

/// Starting playback opens the app: the web player needs its window, and it may not be running.
struct PlayPlaylistIntent: AppIntent {
    static let title: LocalizedStringResource = "Play Playlist"
    static let description = IntentDescription("Plays a playlist from your library in Kaset.")
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Playlist", requestValueDialog: "Which playlist?")
    var playlist: PlaylistEntity

    @Parameter(title: "Shuffle", default: false)
    var shuffle: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$playlist)") {
            \.$shuffle
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        await AppEnvironment.shared.playPlaylist(id: self.playlist.id, shuffled: self.shuffle)
        return .result(dialog: "Playing \(self.playlist.title)")
    }
}

/// Plays what a text describes. This is the end of the *Recognise Music* shortcut.
struct SearchAndPlayIntent: AppIntent {
    static let title: LocalizedStringResource = "Search and Play"
    static let description = IntentDescription("Finds a song in YouTube Music and plays it in Kaset.")
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Song", description: "A title, ideally with the artist.", requestValueDialog: "Which song?")
    var query: String

    static var parameterSummary: some ParameterSummary {
        Summary("Search and play \(\.$query)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let query = MusicIntentText.normalizedQuery(self.query) else { throw MusicIntentError.emptySearch }
        guard let song = try await AppEnvironment.shared.firstSong(matching: query) else {
            throw MusicIntentError.noSong(query)
        }
        AppEnvironment.shared.playSong(song)
        return .result(dialog: "Playing \(song.title)")
    }
}

/// Radio of a named song or, without a name, of the song playing.
struct StartRadioIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Radio"
    static let description = IntentDescription("Starts a radio from a song, or from the song playing in Kaset.")
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Song", description: "Leave empty to use the song playing.", requestValueDialog: "Which song?")
    var query: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Start a radio from \(\.$query)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        await AppEnvironment.shared.restoreSession()
        if let query = self.query.flatMap(MusicIntentText.normalizedQuery) {
            guard let song = try await AppEnvironment.shared.firstSong(matching: query) else {
                throw MusicIntentError.noSong(query)
            }
            AppEnvironment.shared.playSong(song)
            return .result(dialog: "Radio of \(song.title)")
        }
        guard let videoId = AppEnvironment.shared.playingVideoId else {
            throw self.$query.needsValueError("Which song?")
        }
        let title = AppEnvironment.shared.player.state.title ?? ""
        SpikeLog.shared.log("intents", "radio of the song playing \(videoId)")
        AppEnvironment.shared.player.startRadio(videoId: videoId)
        return .result(dialog: "Radio of \(title)")
    }
}

/// Stays in the background: only an API call, and the app is already running if a song plays.
struct LikeCurrentSongIntent: AppIntent {
    static let title: LocalizedStringResource = "Like This Song"
    static let description = IntentDescription("Likes the song playing in Kaset.")
    static let supportedModes: IntentModes = .background

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let title = try await AppEnvironment.shared.likePlayingSong() else {
            throw MusicIntentError.nothingPlaying
        }
        return .result(dialog: "Liked \(title)")
    }
}

/// What the system runs when a Visual Intelligence result is tapped.
struct OpenMusicItemIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open in Kaset"
    static let isDiscoverable = false

    @Parameter(title: "Item")
    var target: MusicItemEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        if let entity = self.target.mediaEntity { await AppEnvironment.shared.openFromOutside(entity) }
        return .result()
    }
}
