import SwiftUI

/// Menu bar: a Controls menu with the usual music app shortcuts, and View items for the side
/// panels and sidebar destinations.
struct PlaybackCommands: Commands {
    let environment: AppEnvironment

    private var player: WebPlayer { self.environment.player }

    var body: some Commands {
        CommandMenu("Controls") {
            // Space is handled by `SpaceBarMonitor` so it still types in text fields.
            Button(self.player.state.isPlaying ? "Pause" : "Play") { self.player.togglePlayPause() }
            Button("Next") { self.player.next() }
                .keyboardShortcut(.rightArrow, modifiers: .command)
            Button("Previous") { self.player.previous() }
                .keyboardShortcut(.leftArrow, modifiers: .command)

            Divider()

            Button("Go Forward 10 Seconds") { self.player.seek(to: self.player.state.position() + 10) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            Button("Go Back 10 Seconds") { self.player.seek(to: max(0, self.player.state.position() - 10)) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])

            Divider()

            Button("Increase Volume") { self.player.setVolume(self.player.volume + 0.1) }
                .keyboardShortcut(.upArrow, modifiers: .command)
            Button("Decrease Volume") { self.player.setVolume(self.player.volume - 0.1) }
                .keyboardShortcut(.downArrow, modifiers: .command)

            Divider()

            Button(self.player.state.isShuffleEnabled ? "Turn Off Shuffle" : "Shuffle") { self.player.toggleShuffle() }
                .keyboardShortcut("s", modifiers: [.command, .control])
            Button("Repeat: \(self.repeatLabel)") { self.player.cycleRepeat() }
                .keyboardShortcut("r", modifiers: [.command, .control])

            Divider()

            Button("Like Song") {
                guard let videoId = self.player.state.videoId else { return }
                Task { await MacShell.current?.nowPlaying.toggleLike(videoId: videoId) }
            }
            .keyboardShortcut("l", modifiers: .command)
            .disabled(self.player.state.videoId == nil || self.environment.auth.state != .signedIn)
        }

        CommandGroup(after: .sidebar) {
            Button("Lyrics") { MacShell.current?.toggle(.lyrics) }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Button("Queue") { MacShell.current?.toggle(.queue) }
                .keyboardShortcut("u", modifiers: [.command, .option])
            Divider()
            Button("Refresh") { MacShell.current?.refreshCurrent() }
                .keyboardShortcut("r", modifiers: .command)
            Button("Search") { MacShell.current?.focusSearch() }
                .keyboardShortcut("f", modifiers: .command)
            Button("Home") { MacShell.current?.select(.home) }
                .keyboardShortcut("1", modifiers: .command)
            Button("Explore") { MacShell.current?.select(.explore) }
                .keyboardShortcut("2", modifiers: .command)
            Button("Library") { MacShell.current?.select(.library) }
                .keyboardShortcut("3", modifiers: .command)
                .disabled(self.environment.auth.state != .signedIn)
            Divider()
        }

        CommandGroup(replacing: .newItem) {}
    }

    private var repeatLabel: String {
        switch self.player.state.repeatMode {
        case .off: String(localized: "Off")
        case .all: String(localized: "All")
        case .one: String(localized: "One")
        }
    }
}

/// Space toggles playback anywhere in the window except while typing.
@MainActor
enum SpaceBarMonitor {
    private static var monitor: Any?

    static func install() {
        guard self.monitor == nil else { return }
        self.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
            guard event.keyCode == 49, modifiers.isEmpty, !event.isARepeat else { return event }
            // Local monitors run on the main thread.
            let isTyping = event.window.map { $0.attachedSheet != nil || $0.firstResponder is NSText } ?? true
            guard !isTyping else { return event }
            MainActor.assumeIsolated { AppEnvironment.shared.player.togglePlayPause() }
            return nil
        }
    }
}
