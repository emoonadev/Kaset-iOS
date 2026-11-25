import SwiftUI

/// The page's queue, as last reported. Everything here is a command to the page; the list
/// updates when the page reports a new queue.
///
/// Rows after the current track can be dragged to reorder (the page has no reorder primitive,
/// so the player rewrites that part of the queue) and deleted.
struct QueueView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let player = self.environment.player
        let queue = player.state.queue
        let currentIndex = queue.firstIndex(where: \.isCurrent) ?? -1

        NavigationStack {
            Group {
                if queue.isEmpty {
                    ContentUnavailableView("Queue is empty", systemImage: "list.bullet",
                                           description: Text("Play something to see what's next."))
                } else {
                    List {
                        ForEach(queue) { entry in
                            self.row(entry, isUpNext: entry.index > currentIndex)
                                .moveDisabled(entry.index <= currentIndex)
                                .deleteDisabled(entry.index <= currentIndex)
                        }
                        .onMove { source, destination in
                            guard let from = source.first else { return }
                            let to = destination > from ? destination - 1 : destination
                            Task { await player.moveQueueEntry(from: from, to: to) }
                        }
                        .onDelete { offsets in
                            for index in offsets.sorted(by: >) where index > currentIndex {
                                player.removeQueueEntry(at: index)
                            }
                        }
                    }
                    .listStyle(.plain)
                    .environment(\.editMode, .constant(.active))
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
            .navigationTitle("Up Next")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    let state = player.state
                    Button { player.toggleShuffle() } label: {
                        Image(systemName: "shuffle")
                            .symbolVariant(state.isShuffleEnabled ? .fill : .none)
                            .foregroundStyle(state.isShuffleEnabled ? Color.accentColor : Color.secondary)
                    }
                    .accessibilityLabel("Shuffle")
                    Button { player.cycleRepeat() } label: {
                        Image(systemName: state.repeatMode == .one ? "repeat.1" : "repeat")
                            .foregroundStyle(state.repeatMode == .off ? Color.secondary : Color.accentColor)
                    }
                    .accessibilityLabel("Repeat")
                }
                SheetCloseButton { self.dismiss() }
            }
        }
        .queueNoticeBanner()
        .presentationDetents([.medium, .large])
    }

    private func row(_ entry: PlaybackState.QueueEntry, isUpNext: Bool) -> some View {
        Button {
            self.environment.player.playQueueEntry(at: entry.index)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: entry.isCurrent ? "speaker.wave.2.fill" : "music.note")
                    .frame(width: 24)
                    .foregroundStyle(entry.isCurrent ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title.isEmpty ? entry.videoId : entry.title)
                        .lineLimit(1)
                        .foregroundStyle(isUpNext || entry.isCurrent ? Color.primary : Color.secondary)
                    if !entry.artist.isEmpty {
                        Text(entry.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }
}
