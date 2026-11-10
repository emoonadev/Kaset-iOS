import SwiftUI

/// Lyrics of whatever the page is playing; follows track changes while open.
struct LyricsSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    let model: NowPlayingModel?

    var body: some View {
        let state = self.environment.player.state

        NavigationStack {
            Group {
                switch self.model?.lyrics(for: state.videoId) {
                case let .synced(lyrics):
                    SyncedLyricsView(lyrics: lyrics)
                case let .plain(lyrics) where lyrics.isAvailable:
                    PlainLyricsView(lyrics: lyrics)
                case nil where state.videoId != nil:
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                default:
                    ContentUnavailableView("No lyrics", systemImage: "quote.bubble")
                }
            }
            .navigationTitle("Lyrics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { self.dismiss() } } }
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
            await self.model?.loadLyrics(
                videoId: videoId, title: current.title, artist: current.artist, duration: current.duration
            )
        }
    }
}

/// Plain lyrics: one block of text.
private struct PlainLyricsView: View {
    let lyrics: Lyrics

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(self.lyrics.text).font(.title3).frame(maxWidth: .infinity, alignment: .leading)
                if let source = self.lyrics.source {
                    Text(source).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding()
        }
    }
}

/// Synced lyrics: the current line is highlighted and kept in view; tapping a line seeks there.
/// Scrolling by hand pauses the follow for a few seconds, as in Apple Music.
private struct SyncedLyricsView: View {
    @Environment(AppEnvironment.self) private var environment

    let lyrics: SyncedLyrics

    @State private var currentIndex: Int?
    @State private var followPausedUntil = Date.distantPast

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    ForEach(Array(self.lyrics.lines.enumerated()), id: \.offset) { index, line in
                        self.row(line, index: index)
                    }
                    Text("Source: \(Self.sourceName(self.lyrics.source))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 12)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 32)
            }
            .onScrollPhaseChange { _, phase in
                if phase == .interacting || phase == .decelerating {
                    self.followPausedUntil = Date().addingTimeInterval(3)
                }
            }
            .onChange(of: self.currentIndex) { previous, index in
                guard let index, Date() >= self.followPausedUntil else { return }
                // The first jump (sheet just opened) is instant; the rest glide.
                if previous == nil {
                    proxy.scrollTo(index, anchor: UnitPoint(x: 0.5, y: 0.3))
                } else {
                    withAnimation(.spring(duration: 0.6)) { proxy.scrollTo(index, anchor: UnitPoint(x: 0.5, y: 0.3)) }
                }
            }
        }
        .task(id: self.lyrics) {
            while !Task.isCancelled {
                let timeMs = Int(self.environment.player.state.displayedPosition() * 1000)
                let index = self.lyrics.currentLineIndex(at: timeMs)
                if index != self.currentIndex { self.currentIndex = index }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    private func row(_ line: SyncedLyricLine, index: Int) -> some View {
        let isCurrent = index == self.currentIndex
        return Button {
            Haptics.tap()
            self.followPausedUntil = .distantPast
            self.currentIndex = index
            self.environment.player.seek(to: TimeInterval(line.timeInMs) / 1000)
        } label: {
            Text(line.text.isEmpty ? "♪" : line.text)
                .font(.system(size: 28, weight: .bold))
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(isCurrent ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                .scaleEffect(isCurrent ? 1 : 0.96, anchor: .leading)
                .animation(.easeInOut(duration: 0.3), value: isCurrent)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(index)
        .accessibilityHint("Plays from this line")
    }

    private static func sourceName(_ source: String) -> String {
        source == "YTMusic" ? "YouTube Music" : source
    }
}
