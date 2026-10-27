import AVKit
import MediaPlayer
import Observation
import SwiftUI

/// Rating and lyrics for the track the page is playing. The track itself comes from
/// `PlaybackState`; this only adds what the web player does not report.
@MainActor
@Observable
final class NowPlayingModel {
    private(set) var likeStatus: LikeStatus = .indifferent
    /// Artists of the current track, with ids, from the song metadata.
    private(set) var artists: [Artist] = []
    /// Lyrics of `lyricsVideoId`; `nil` until loaded.
    private(set) var lyrics: LyricResult?
    private(set) var lyricsVideoId: String?
    private(set) var isLoadingLyrics = false
    /// Average colour of the current artwork; drives the background gradient.
    private(set) var artworkColor: UIColor?
    private var loadedVideoId: String?
    private var loadedArtworkURL: URL?
    private let client: YTMusicClient

    init(client: YTMusicClient) {
        self.client = client
    }

    func trackChanged(to videoId: String?) async {
        guard videoId != self.loadedVideoId else { return }
        self.loadedVideoId = videoId
        self.likeStatus = .indifferent
        self.artists = []
        guard let videoId else { return }
        if let song = try? await self.client.getSong(videoId: videoId), self.loadedVideoId == videoId {
            self.likeStatus = song.likeStatus ?? .indifferent
            self.artists = song.artists.filter(\.hasNavigableId)
        }
    }

    /// Artist to open for a tapped name: from metadata, else the top artist search result.
    func resolveArtist(named name: String?) async -> Artist? {
        if let first = self.artists.first { return first }
        guard let name, !name.isEmpty,
              let response = try? await self.client.search(query: name)
        else { return nil }
        return response.artists.first
    }

    func artworkChanged(to url: URL?) async {
        guard url != self.loadedArtworkURL else { return }
        self.loadedArtworkURL = url
        guard let url else {
            self.artworkColor = nil
            return
        }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let color = Self.averageColor(of: data)
        else { return }
        guard self.loadedArtworkURL == url else { return }
        self.artworkColor = color
    }

    /// Mean colour via a 1×1 redraw; cheap and stable for a background tint.
    nonisolated private static func averageColor(of data: Data) -> UIColor? {
        guard let image = UIImage(data: data)?.cgImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        let space = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return UIColor(
            red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255, blue: CGFloat(pixel[2]) / 255, alpha: 1
        )
    }

    func toggleLike(videoId: String) async {
        let next: LikeStatus = self.likeStatus == .like ? .indifferent : .like
        let previous = self.likeStatus
        self.likeStatus = next
        do {
            try await self.client.rateSong(videoId: videoId, rating: next)
        } catch {
            self.likeStatus = previous
        }
    }

    /// Lyrics for a track, `nil` while they load or when they belong to another track.
    func lyrics(for videoId: String?) -> LyricResult? {
        guard let videoId, videoId == self.lyricsVideoId else { return nil }
        return self.lyrics
    }

    /// YouTube Music and LRCLib are asked in parallel; synced lyrics win over plain ones, and
    /// YouTube Music wins a tie.
    func loadLyrics(videoId: String, title: String?, artist: String?, duration: TimeInterval) async {
        guard videoId != self.lyricsVideoId || self.lyrics == nil else { return }
        self.lyricsVideoId = videoId
        self.lyrics = nil
        self.isLoadingLyrics = true

        let client = self.client
        async let youtube = (try? await client.getLyrics(videoId: videoId)) ?? .unavailable
        async let lrclib: LyricResult = if let title, let artist {
            await LRCLibClient.search(title: title, artist: artist, duration: duration > 0 ? duration : nil)
        } else {
            .unavailable
        }
        let result = Self.preferred(await youtube, await lrclib)

        guard self.lyricsVideoId == videoId else { return }
        self.lyrics = result
        self.isLoadingLyrics = false
    }

    static func preferred(_ youtube: LyricResult, _ lrclib: LyricResult) -> LyricResult {
        for candidate in [youtube, lrclib] {
            if case let .synced(lyrics) = candidate, !lyrics.isEmpty { return candidate }
        }
        for candidate in [youtube, lrclib] where candidate.isAvailable {
            return candidate
        }
        return .unavailable
    }
}

/// Full-screen player. Every control sends a command to the web player; what is drawn comes
/// from `PlaybackState`, which only changes when the page reports back.
struct NowPlayingView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var model: NowPlayingModel?
    @State private var isQueuePresented = false
    @State private var isLyricsPresented = false
    @State private var dragOffset: CGFloat = 0
    @State private var artistToShow: Artist?
    @State private var isAddToPlaylistPresented = false

    var body: some View {
        let state = self.environment.player.state

        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom
            let margin = width * 0.08
            let top = -proxy.safeAreaInsets.top

            ZStack {
                self.background(state).ignoresSafeArea()

                // Positions follow Apple Music's Now Playing as fractions of the screen height.
                ZStack {
                    Capsule()
                        .fill(.white.opacity(0.35))
                        .frame(width: 42, height: 5)
                        .position(x: width / 2, y: top + height * 0.081)
                        .onTapGesture { self.dismiss() }

                    ArtworkView(url: state.artworkURL)
                        .aspectRatio(1, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .shadow(color: .black.opacity(0.3), radius: 22, y: 12)
                        .frame(width: width * (state.isPlaying ? 0.84 : 0.64))
                        .animation(.spring(duration: 0.5, bounce: 0.3), value: state.isPlaying)
                        .position(x: width / 2, y: top + height * (state.isPlaying ? 0.325 : 0.311))
                        .animation(.spring(duration: 0.5, bounce: 0.3), value: state.isPlaying)

                    self.titleRow(state)
                        .padding(.horizontal, margin)
                        .position(x: width / 2, y: top + height * 0.5925)

                    ScrubberView(state: state) { self.environment.player.seek(to: $0) }
                        .padding(.horizontal, margin)
                        .position(x: width / 2, y: top + height * 0.672)

                    self.transport(state)
                        .frame(width: width * 0.8)
                        .position(x: width / 2, y: top + height * 0.7625)

                    self.volumeRow
                        .padding(.horizontal, margin)
                        .position(x: width / 2, y: top + height * 0.865)

                    self.footer(state)
                        .frame(width: width * 0.8)
                        .position(x: width / 2, y: top + height * 0.925)
                }
            }
            .offset(y: max(self.dragOffset, 0))
            .gesture(
                DragGesture()
                    .onChanged { self.dragOffset = $0.translation.height }
                    .onEnded { value in
                        if value.translation.height > 140 || value.predictedEndTranslation.height > 400 {
                            self.dismiss()
                        } else {
                            withAnimation(.spring(duration: 0.3)) { self.dragOffset = 0 }
                        }
                    }
            )
        }
        .preferredColorScheme(.dark)
        .queueNoticeBanner()
        .task(id: state.videoId) {
            let model = self.model ?? NowPlayingModel(client: self.environment.client)
            self.model = model
            await model.trackChanged(to: state.videoId)
        }
        .task(id: state.artworkURL) {
            let model = self.model ?? NowPlayingModel(client: self.environment.client)
            self.model = model
            await model.artworkChanged(to: state.artworkURL)
        }
        .sheet(item: self.$artistToShow) { artist in
            NavigationStack {
                ArtistDetailView(id: artist.id, fallbackName: artist.name)
                    .entityDestinations()
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button(role: .close) { self.artistToShow = nil }
                        }
                    }
            }
        }
        .sheet(isPresented: self.$isQueuePresented) { QueueView() }
        .addToPlaylistSheet(
            isPresented: self.$isAddToPlaylistPresented,
            videoId: state.videoId ?? "", title: state.title
        )
        .sheet(isPresented: self.$isLyricsPresented) {
            LyricsSheet(model: self.model)
        }
    }

    /// Vertical gradient from the artwork's average colour, darker towards the bottom.
    private func background(_ state: PlaybackState) -> some View {
        let base = self.model?.artworkColor ?? UIColor(white: 0.25, alpha: 1)
        var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0, alpha: CGFloat = 0
        base.getHue(&hue, saturation: &sat, brightness: &bri, alpha: &alpha)
        let top = Color(hue: hue, saturation: min(sat * 1.05, 1), brightness: max(min(bri, 0.62), 0.32))
        let bottom = Color(hue: hue, saturation: min(sat * 1.1, 1), brightness: max(min(bri * 0.55, 0.34), 0.14))
        return LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
            .animation(.easeInOut(duration: 0.7), value: self.model?.artworkColor)
    }

    private func titleRow(_ state: PlaybackState) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(state.title ?? "Not playing")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                self.artistLabel(state)
            }
            Spacer(minLength: 0)
            Menu {
                if let videoId = state.videoId, let model {
                    if self.environment.auth.state == .signedIn {
                        Button(
                            model.likeStatus == .like ? "Unlike" : "Like",
                            systemImage: model.likeStatus == .like ? "heart.slash" : "heart"
                        ) {
                            Task { await model.toggleLike(videoId: videoId) }
                        }
                    }
                    if self.environment.auth.state == .signedIn {
                        Button("Add to Playlist…", systemImage: "text.badge.plus") { self.isAddToPlaylistPresented = true }
                    }
                    Button("Play Next", systemImage: "text.insert") { self.environment.player.playNext(videoId: videoId) }
                    Button("Start Radio", systemImage: "dot.radiowaves.left.and.right") {
                        self.environment.player.startRadio(videoId: videoId)
                    }
                    if let url = URL(string: "https://music.youtube.com/watch?v=\(videoId)") {
                        ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .neutralMenuTint()
            .accessibilityLabel("More")
        }
    }

    /// The artist name is a button: one artist opens their page, several offer a menu.
    @ViewBuilder
    private func artistLabel(_ state: PlaybackState) -> some View {
        let text = Text(state.artist ?? " ")
            .font(.system(size: 22))
            .foregroundStyle(.white.opacity(0.6))
            .lineLimit(1)
        let artists = self.model?.artists ?? []
        if artists.count > 1 {
            Menu {
                ForEach(artists) { artist in
                    Button(artist.name) { self.artistToShow = artist }
                }
            } label: { text }
            .neutralMenuTint()
        } else if state.artist != nil {
            Button {
                Task {
                    if let artist = await self.model?.resolveArtist(named: state.artist) {
                        self.artistToShow = artist
                    }
                }
            } label: { text }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the artist page")
        } else {
            text
        }
    }

    private func transport(_ state: PlaybackState) -> some View {
        HStack(spacing: 0) {
            Button { Haptics.tap(); self.environment.player.previous() } label: {
                Image(systemName: "backward.fill").font(.system(size: 40))
                    .frame(maxWidth: .infinity)
            }
            .disabled(!state.canGoPrevious)
            .accessibilityLabel("Previous")

            Button { Haptics.tap(); self.environment.player.togglePlayPause() } label: {
                Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 52))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(maxWidth: .infinity)
            }
            .accessibilityLabel(state.isPlaying ? "Pause" : "Play")

            Button { Haptics.tap(); self.environment.player.next() } label: {
                Image(systemName: "forward.fill").font(.system(size: 40))
                    .frame(maxWidth: .infinity)
            }
            .disabled(!state.canGoNext)
            .accessibilityLabel("Next")
        }
        .buttonStyle(PressableButtonStyle())
        .foregroundStyle(.white)
    }

    /// System output volume. `MPVolumeView` is the only supported control for it.
    private var volumeRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.fill")
            SystemVolumeSlider().frame(height: 30)
            Image(systemName: "speaker.wave.3.fill")
        }
        .font(.system(size: 14))
        .foregroundStyle(.white.opacity(0.55))
    }

    private func footer(_ state: PlaybackState) -> some View {
        HStack(spacing: 0) {
            Button { self.isLyricsPresented = true } label: {
                Image(systemName: "quote.bubble")
                    .font(.system(size: 22))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .accessibilityLabel("Lyrics")

            AirPlayButton()
                .frame(width: 44, height: 44)
                .frame(maxWidth: .infinity)

            Button { self.isQueuePresented = true } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 22))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .overlay(alignment: .topTrailing) {
                        // Same cue as Apple Music: the queue icon carries a badge when
                        // repeat / shuffle is on; both controls live inside the queue.
                        if state.repeatMode != .off || state.isShuffleEnabled {
                            Image(systemName: state.repeatMode == .one ? "repeat.1" : (state.repeatMode == .all ? "repeat" : "shuffle"))
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 22, height: 22)
                                .background(.white.opacity(0.22), in: Circle())
                                .offset(x: -14, y: -10)
                        }
                    }
            }
            .accessibilityLabel("Queue")
        }
        .buttonStyle(PressableButtonStyle())
        .foregroundStyle(.white.opacity(0.5))
    }

    private static func format(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Progress bar with a drag-to-seek gesture. While dragging it shows the finger position;
/// on release it sends one `seek` command and keeps showing that position until the page
/// reports a time near it (or a short timeout), so it does not jump back.
struct ScrubberView: View {
    let state: PlaybackState
    let onSeek: (TimeInterval) -> Void

    @State private var dragFraction: Double?
    @State private var pendingSeek: (target: TimeInterval, until: Date)?

    var body: some View {
        VStack(spacing: 6) {
            TimelineView(.periodic(from: .now, by: 0.25)) { context in
                let duration = max(self.state.duration, 0)
                let position = self.displayedPosition(at: context.date, duration: duration)
                let fraction = duration > 0 ? min(max(position / duration, 0), 1) : 0

                VStack(spacing: 8) {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.22))
                            Capsule().fill(.white.opacity(0.72)).frame(width: max(proxy.size.width * fraction, 0))
                        }
                        .frame(height: self.dragFraction == nil ? 6 : 10)
                        .clipShape(Capsule())
                        .animation(.spring(duration: 0.25), value: self.dragFraction == nil)
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    guard duration > 0 else { return }
                                    self.dragFraction = min(max(value.location.x / proxy.size.width, 0), 1)
                                }
                                .onEnded { value in
                                    guard duration > 0 else { return }
                                    let target = min(max(value.location.x / proxy.size.width, 0), 1) * duration
                                    self.dragFraction = nil
                                    self.pendingSeek = (target, Date().addingTimeInterval(3))
                                    self.onSeek(target)
                                }
                        )
                    }
                    .frame(height: 16)

                    HStack {
                        Text(Self.format(position))
                        Spacer()
                        Text("\u{2212}" + Self.format(max(0, duration - position)))
                    }
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.5))
                }
            }
        }
        .opacity(self.state.duration > 0 ? 1 : 0.5)
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(Self.format(self.state.position())) of \(Self.format(self.state.duration))")
        .accessibilityAdjustableAction { direction in
            let step: TimeInterval = 10
            let current = self.state.position()
            switch direction {
            case .increment: self.onSeek(min(current + step, self.state.duration))
            case .decrement: self.onSeek(max(current - step, 0))
            @unknown default: break
            }
        }
    }

    private func displayedPosition(at date: Date, duration: TimeInterval) -> TimeInterval {
        if let dragFraction { return dragFraction * duration }
        let live = self.state.position(at: date)
        if let pending = self.pendingSeek {
            // Hold the target until the page catches up with it (within 2 s) or the timeout.
            if date < pending.until, abs(live - pending.target) > 2 { return pending.target }
        }
        return live
    }

    private static func format(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Subtle scale-down on press, used for the player's icon buttons.
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}

struct SystemVolumeSlider: UIViewRepresentable {
    func makeUIView(context _: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.showsRouteButton = false
        view.tintColor = UIColor.white.withAlphaComponent(0.72)
        return view
    }

    func updateUIView(_: MPVolumeView, context _: Context) {}
}

struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context _: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.activeTintColor = .white
        view.tintColor = UIColor.white.withAlphaComponent(0.5)
        return view
    }

    func updateUIView(_: AVRoutePickerView, context _: Context) {}
}
