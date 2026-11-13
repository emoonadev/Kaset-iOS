import AppIntents
import Foundation

/// A playlist of the user's library, as Siri and Shortcuts see it.
struct PlaylistEntity: AppEntity, Identifiable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Playlist")
    static let defaultQuery = PlaylistEntityQuery()

    let id: String
    let title: String
    let subtitle: String?
    let thumbnailURL: URL?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(self.title)",
            subtitle: self.subtitle.map { "\($0)" },
            image: self.thumbnailURL.map { .init(url: $0) }
        )
    }
}

struct PlaylistEntityQuery: EntityStringQuery {
    func entities(for identifiers: [PlaylistEntity.ID]) async throws -> [PlaylistEntity] {
        let playlists = try await AppEnvironment.shared.intentPlaylists()
        return identifiers.compactMap { id in playlists.first { $0.id == id } }
    }

    func entities(matching string: String) async throws -> [PlaylistEntity] {
        try await AppEnvironment.shared.intentPlaylists().filter { MusicIntentText.title($0.title, matches: string) }
    }

    func suggestedEntities() async throws -> [PlaylistEntity] {
        try await AppEnvironment.shared.intentPlaylists()
    }
}

/// A search result offered outside the app (Visual Intelligence). The id carries the kind and
/// the YouTube Music id, which is all the app needs to open it.
struct MusicItemEntity: AppEntity, Identifiable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Music")
    static let defaultQuery = MusicItemEntityQuery()

    let id: String
    let title: String
    let subtitle: String?
    let thumbnailURL: URL?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(self.title)",
            subtitle: self.subtitle.map { "\($0)" },
            image: self.thumbnailURL.map { .init(url: $0) }
        )
    }
}

extension MusicItemEntity {
    /// `nil` for what the app cannot open from outside (moods, podcasts).
    init?(_ entity: MediaEntity) {
        guard let id = Self.identifier(for: entity.target) else { return nil }
        self.init(id: id, title: entity.title, subtitle: entity.subtitle, thumbnailURL: entity.thumbnailURL)
    }

    /// An item known only by its id: enough to open it, its screen loads the rest.
    init?(id: String) {
        guard Self.target(for: id) != nil else { return nil }
        self.init(id: id, title: "", subtitle: nil, thumbnailURL: nil)
    }

    var mediaEntity: MediaEntity? {
        guard let target = Self.target(for: self.id) else { return nil }
        var isArtist = false
        if case .artist = target { isArtist = true }
        return MediaEntity(
            id: self.id, title: self.title, subtitle: self.subtitle, thumbnailURL: self.thumbnailURL,
            target: target, isCircular: isArtist
        )
    }

    static func identifier(for target: MediaEntity.Target) -> String? {
        switch target {
        case let .song(videoId): "song:\(videoId)"
        case let .album(id): "album:\(id)"
        case let .artist(id): "artist:\(id)"
        case let .playlist(id): "playlist:\(id)"
        case .mood, .unsupported: nil
        }
    }

    static func target(for identifier: String) -> MediaEntity.Target? {
        guard let separator = identifier.firstIndex(of: ":") else { return nil }
        let value = String(identifier[identifier.index(after: separator)...])
        guard !value.isEmpty else { return nil }
        switch identifier[..<separator] {
        case "song": return .song(videoId: value)
        case "album": return .album(id: value)
        case "artist": return .artist(id: value)
        case "playlist": return .playlist(id: value)
        default: return nil
        }
    }
}

struct MusicItemEntityQuery: EntityQuery {
    func entities(for identifiers: [MusicItemEntity.ID]) async throws -> [MusicItemEntity] {
        identifiers.compactMap { MusicItemEntity(id: $0) }
    }
}
