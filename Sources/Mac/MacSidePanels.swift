import SwiftUI

/// Right-hand glass panel: lyrics or queue, like Kaset for macOS.
struct MacSidePanelView: View {
    @Environment(MacShell.self) private var shell

    let panel: MacSidePanel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(self.panel == .lyrics ? "Lyrics" : "Up Next")
                    .font(.headline)
                Spacer()
                if self.panel == .queue { MacQueueModeButtons() }
                Button {
                    self.shell.toggle(self.panel)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .background(.quaternary, in: Circle())
                }
                .buttonStyle(.plain)
                .help("Close")
                .accessibilityLabel("Close")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider().opacity(0.5)

            switch self.panel {
            case .lyrics: MacLyricsPanel()
            case .queue: MacQueuePanel()
            }
        }
        .frame(width: 340)
        .frame(maxHeight: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }
}

// MARK: - Lyrics

private struct MacLyricsPanel: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(MacShell.self) private var shell

    var body: some View {
        let state = self.environment.player.state
        let model = self.shell.nowPlaying

        Group {
            switch model.lyrics(for: state.videoId) {
            case let .synced(lyrics):
                SyncedLyricsView(lyrics: lyrics, fontSize: 22)
            case let .plain(lyrics) where lyrics.isAvailable:
                PlainLyricsView(lyrics: lyrics)
            case nil where state.videoId != nil:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            default:
                ContentUnavailableView("No lyrics", systemImage: "quote.bubble")
            }
        }
        .task(id: state.videoId) {
            guard let videoId = state.videoId else { return }
            // The length picks the right LRCLib entry; the page reports it a moment after the
            // track starts.
            var waits = 0
            while self.environment.player.state.duration <= 0, waits < 12 {
                try? await Task.sleep(for: .milliseconds(250))
                waits += 1
            }
            guard !Task.isCancelled else { return }
            let current = self.environment.player.state
            await model.loadLyrics(
                videoId: videoId, title: current.title, artist: current.artist, duration: current.duration
            )
        }
    }
}

// MARK: - Queue

private struct MacQueueModeButtons: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        let player = self.environment.player
        let state = player.state
        HStack(spacing: 2) {
            MacBarIconButton(label: "Shuffle", isSelected: state.isShuffleEnabled) { player.toggleShuffle() } icon: {
                Image(systemName: "shuffle")
                    .font(.system(size: 12))
                    .foregroundStyle(state.isShuffleEnabled ? Color.brand : .secondary)
            }
            MacBarIconButton(label: "Repeat", isSelected: state.repeatMode != .off) { player.cycleRepeat() } icon: {
                Image(systemName: state.repeatMode == .one ? "repeat.1" : "repeat")
                    .font(.system(size: 12))
                    .foregroundStyle(state.repeatMode == .off ? .secondary : Color.brand)
            }
        }
    }
}

/// The page's queue. Click plays an entry; entries after the current one can be dragged to
/// reorder or removed (both are best effort through the page's menus).
private struct MacQueuePanel: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        let player = self.environment.player
        let queue = player.state.queue
        let currentIndex = queue.firstIndex(where: \.isCurrent) ?? -1

        Group {
            if queue.isEmpty {
                ContentUnavailableView(
                    "Queue is empty", systemImage: "list.bullet",
                    description: Text("Play something to see what's next.")
                )
            } else {
                List {
                    ForEach(queue) { entry in
                        self.row(entry, isUpNext: entry.index > currentIndex)
                            .moveDisabled(entry.index <= currentIndex)
                            .contextMenu {
                                Button("Play") { player.playQueueEntry(at: entry.index) }
                                if entry.index > currentIndex {
                                    Button("Remove from Queue", role: .destructive) {
                                        player.removeQueueEntry(at: entry.index)
                                    }
                                }
                            }
                    }
                    .onMove { source, destination in
                        guard let from = source.first else { return }
                        let to = destination > from ? destination - 1 : destination
                        Task { await player.moveQueueEntry(from: from, to: to) }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .disabled(player.isReorderingQueue)
                .overlay {
                    if player.isReorderingQueue {
                        VStack(spacing: 8) {
                            ProgressView()
                            Text("Reordering…").font(.footnote).foregroundStyle(.secondary)
                        }
                        .padding(20)
                        .glassEffect(.regular, in: .rect(cornerRadius: 16))
                    }
                }
            }
        }
    }

    private func row(_ entry: PlaybackState.QueueEntry, isUpNext: Bool) -> some View {
        Button {
            self.environment.player.playQueueEntry(at: entry.index)
        } label: {
            HStack(spacing: 10) {
                Group {
                    if entry.isCurrent {
                        EqualizerView(isAnimating: self.environment.player.state.isPlaying)
                            .frame(height: 12)
                    } else {
                        Text("\(entry.index + 1)")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(width: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title.isEmpty ? entry.videoId : entry.title)
                        .font(.system(size: 13, weight: entry.isCurrent ? .semibold : .regular))
                        .lineLimit(1)
                        .foregroundStyle(isUpNext || entry.isCurrent ? Color.primary : Color.secondary)
                    if !entry.artist.isEmpty {
                        Text(entry.artist).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
    }
}
