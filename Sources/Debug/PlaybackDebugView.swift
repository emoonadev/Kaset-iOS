import SwiftUI

/// K4 verification screen: transport, state readout, queue, play-next, log.
struct PlaybackDebugView: View {
    let player: WebPlayer
    @ObservedObject private var log = SpikeLog.shared
    @AppStorage("nativeNowPlaying") private var nativeNowPlaying = true
    @State private var videoId = ""
    @State private var playlistId = ""
    @State private var nextVideoId = ""

    private struct Preset {
        let title: String
        let videoId: String
        let radio: Bool
    }

    /// Well-known tracks so the transport can be exercised without looking up ids.
    private static let presets = [
        Preset(title: "Radio : Rick Astley – Never Gonna Give You Up", videoId: "dQw4w9WgXcQ", radio: true),
        Preset(title: "Radio : Queen – Bohemian Rhapsody", videoId: "fJ9rUzIMcZQ", radio: true),
        Preset(title: "Radio : Ed Sheeran – Shape of You", videoId: "JGwWNGJdvx8", radio: true),
        Preset(title: "Piste seule : Luis Fonsi – Despacito", videoId: "kJQP7kiw5Fk", radio: false),
    ]

    var body: some View {
        NavigationStack {
            List {
                Section("État") {
                    let s = self.player.state
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text("\(s.isPlaying ? "▶︎" : "⏸") \(Int(s.position(at: context.date)))/\(Int(s.duration))s · vis=\(s.visibility ?? "?")")
                            .font(.footnote.monospacedDigit())
                    }
                    Text("\(s.title ?? "—") · \(s.artist ?? "—")").font(.footnote)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let age = self.player.lastMessageAt.map { "\(Int(context.date.timeIntervalSince($0))) s" } ?? "jamais"
                        Text("Dernier message de la page : \(age)\n\(self.player.pageURL ?? "page non chargée")")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Text("id=\(s.videoId ?? "-") next=\(s.canGoNext ? "✓" : "✗") prev=\(s.canGoPrevious ? "✓" : "✗")")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Transport") {
                    HStack(spacing: 24) {
                        Button { self.player.previous() } label: { Image(systemName: "backward.fill") }
                        Button { self.player.togglePlayPause() } label: { Image(systemName: "playpause.fill") }
                        Button { self.player.next() } label: { Image(systemName: "forward.fill") }
                        Button("−10 s") { self.player.seek(to: self.player.state.position() - 10) }
                        Button("+10 s") { self.player.seek(to: self.player.state.position() + 10) }
                    }
                    .buttonStyle(.borderless)
                    Button("Rafraîchir l'état") { self.player.refreshState() }
                    Toggle("Now Playing natif", isOn: self.$nativeNowPlaying)
                }

                Section("Pistes de test") {
                    ForEach(Self.presets, id: \.videoId) { preset in
                        Button(preset.title) {
                            self.player.play(videoId: preset.videoId, playlistId: preset.radio ? "RDAMVM\(preset.videoId)" : nil)
                        }
                    }
                    if let current = self.player.state.videoId {
                        Button("Ajouter « \(self.player.state.title ?? current) » comme prochaine (test file)") {
                            if let other = Self.presets.first(where: { $0.videoId != current }) {
                                self.player.playNext(videoId: other.videoId)
                            }
                        }
                    }
                }

                Section("Lancer") {
                    TextField("videoId", text: self.$videoId).plainTextInput()
                    TextField("playlistId (optionnel, ex. RDAMVM…)", text: self.$playlistId)
                        .plainTextInput()
                    Button("Lire") {
                        self.player.play(videoId: self.videoId, playlistId: self.playlistId.isEmpty ? nil : self.playlistId)
                    }
                    .disabled(self.videoId.isEmpty)

                    TextField("videoId à jouer ensuite", text: self.$nextVideoId)
                        .plainTextInput()
                    Button("Lire ensuite") { self.player.playNext(videoId: self.nextVideoId) }
                        .disabled(self.nextVideoId.isEmpty)
                    if let result = self.player.lastQueueResult {
                        Text("\(result.success ? "✓" : "✗") \(result.videoId) \(result.reason)").font(.caption)
                    }
                }

                Section("File d'attente (\(self.player.state.queue.count))") {
                    ForEach(self.player.state.queue) { entry in
                        HStack {
                            Image(systemName: entry.isCurrent ? "speaker.wave.2.fill" : "circle").font(.caption)
                            VStack(alignment: .leading) {
                                Text(entry.title.isEmpty ? entry.videoId : entry.title)
                                Text(entry.artist).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section {
                    ShareLink(item: self.log.fileURL) { Label("Partager le log", systemImage: "square.and.arrow.up") }
                    Button("Vider le log", role: .destructive) { self.log.clear() }
                    ForEach(Array(self.log.lines.suffix(60).enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(size: 10, design: .monospaced))
                    }
                } header: { Text("Log") }
            }
            .navigationTitle("Playback debug")
        }
    }
}
