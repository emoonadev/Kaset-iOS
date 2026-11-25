import AVKit
import MediaPlayer
import SwiftUI

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
        .onChange(of: self.environment.likedFromOutside) { _, videoId in
            if let videoId { self.model?.likedElsewhere(videoId: videoId) }
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
