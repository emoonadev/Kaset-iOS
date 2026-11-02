import AppIntents

/// The phrases Siri knows without any setup, and the actions shown first in Shortcuts.
/// French phrases live in `AppShortcuts.xcstrings`.
struct KasetShortcuts: AppShortcutsProvider {
    static let shortcutTileColor: ShortcutTileColor = .pink

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PlayPlaylistIntent(),
            phrases: [
                "Play \(\.$playlist) in \(.applicationName)",
                "Play my playlist \(\.$playlist) in \(.applicationName)",
                "Play a playlist in \(.applicationName)",
            ],
            shortTitle: "Play Playlist",
            systemImageName: "music.note.list"
        )
        AppShortcut(
            intent: SearchAndPlayIntent(),
            phrases: ["Search and play in \(.applicationName)"],
            shortTitle: "Search and Play",
            systemImageName: "magnifyingglass"
        )
        AppShortcut(
            intent: StartRadioIntent(),
            phrases: ["Start a radio in \(.applicationName)"],
            shortTitle: "Start Radio",
            systemImageName: "dot.radiowaves.left.and.right"
        )
        AppShortcut(
            intent: LikeCurrentSongIntent(),
            phrases: ["Like this song in \(.applicationName)"],
            shortTitle: "Like This Song",
            systemImageName: "heart"
        )
    }
}
