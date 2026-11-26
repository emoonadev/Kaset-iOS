import AVKit
import SwiftUI

/// Player bar at the bottom of the content area, as in Kaset for macOS: one Liquid Glass capsule
/// with the track on the left, transport and progress in the middle, lyrics / queue on the right.
/// Every control is a command to the web player; what is drawn mirrors `PlaybackState`.
struct MacPlayerBar: View {
    private static let songInfoWidth: CGFloat = 234
    private static let compactSongInfoWidth: CGFloat = 116
    /// Below this width the title / artist column is dropped (Kaset's breakpoint).
    private static let compactBreakpoint: CGFloat = 760

    @Environment(AppEnvironment.self) private var environment
    @Environment(MacShell.self) private var shell

    var body: some View {
        let state = self.environment.player.state

        GeometryReader { proxy in
            let compact = proxy.size.width <= Self.compactBreakpoint
            HStack(spacing: 10) {
                self.songInfo(state, compact: compact)
                    .frame(width: compact ? Self.compactSongInfoWidth : Self.songInfoWidth, height: 52)

                MacProgressSection(state: state)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)

                self.options
                    .frame(width: 142, height: 52)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 52)
        .glassEffect(.regular.interactive(), in: .capsule)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    // MARK: Song info

    private func songInfo(_ state: PlaybackState, compact: Bool) -> some View {
        HStack(spacing: 8) {
            ArtworkView(url: state.artworkURL)
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            if !compact {
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.title ?? String(localized: "Not Playing"))
                        .font(.system(size: 13))
                        .lineLimit(1)
                    self.artistButton(state)
                }
                .frame(width: 110, alignment: .leading)
            }

            self.likeButton(state)
            self.moreMenu(state)
        }
        .padding(.leading, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func artistButton(_ state: PlaybackState) -> some View {
        let text = Text(state.isAd ? String(localized: "Advertisement") : (state.artist ?? ""))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        if state.artist != nil, !state.isAd {
            Button {
                Task {
                    if let page = await self.shell.nowPlaying.authorPage(named: state.artist, videoId: state.videoId) {
                        self.shell.open(page)
                    }
                }
            } label: { text }
            .buttonStyle(.plain)
            .help("Go to Artist")
        } else {
            text
        }
    }

    @ViewBuilder
    private func likeButton(_ state: PlaybackState) -> some View {
        if self.environment.auth.state == .signedIn, let videoId = state.videoId {
            let liked = self.shell.nowPlaying.likeStatus == .like
            MacBarIconButton(label: liked ? "Unlike" : "Like") {
                Task { await self.shell.nowPlaying.toggleLike(videoId: videoId) }
            } icon: {
                Image(systemName: liked ? "heart.fill" : "heart")
                    .font(.system(size: 13))
                    .foregroundStyle(liked ? Color.brand : .primary)
                    .contentTransition(.symbolEffect(.replace))
            }
        }
    }

    @ViewBuilder
    private func moreMenu(_ state: PlaybackState) -> some View {
        if let videoId = state.videoId {
            Menu {
                Button("Play Next", systemImage: "text.insert") { self.environment.player.playNext(videoId: videoId) }
                Button("Add to Queue", systemImage: "text.append") { self.environment.player.addToQueue(videoId: videoId) }
                Button("Start Radio", systemImage: "dot.radiowaves.left.and.right") {
                    self.environment.player.startRadio(videoId: videoId)
                }
                if let url = URL(string: "https://music.youtube.com/watch?v=\(videoId)") {
                    Divider()
                    ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                    Button("Copy Link", systemImage: "link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .frame(width: 28, height: 28)
            .help("More")
        }
    }

    // MARK: Options

    private var options: some View {
        HStack(spacing: 6) {
            MacBarIconButton(label: "Lyrics", isSelected: self.shell.sidePanel == .lyrics) {
                self.shell.toggle(.lyrics)
            } icon: {
                Image(systemName: "quote.bubble")
                    .font(.system(size: 15))
                    .foregroundStyle(self.shell.sidePanel == .lyrics ? Color.brand : .primary)
            }
            MacBarIconButton(label: "Queue", isSelected: self.shell.sidePanel == .queue) {
                self.shell.toggle(.queue)
            } icon: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 15))
                    .foregroundStyle(self.shell.sidePanel == .queue ? Color.brand : .primary)
            }
        }
        .padding(.trailing, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
    }
}

// MARK: - Progress and transport

/// Transport row on top, elapsed / remaining at its sides and the seek lane under it.
private struct MacProgressSection: View {
    @Environment(AppEnvironment.self) private var environment

    let state: PlaybackState

    @State private var dragFraction: Double?
    @State private var pendingSeek: (target: TimeInterval, until: Date)?
    @State private var isHovering = false
    @State private var isVolumePresented = false

    var body: some View {
        ZStack(alignment: .top) {
            if self.state.isAd {
                Text("Advertisement")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.top, 34)
            } else {
                self.lane.padding(.top, 18)
            }
            self.controls.padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var controls: some View {
        let player = self.environment.player
        let hasTrack = self.state.videoId != nil
        return HStack(spacing: 6) {
            AirPlayRouteButton()
                .frame(width: 28, height: 28)
                .help("AirPlay")

            MacBarIconButton(label: "Shuffle", isSelected: self.state.isShuffleEnabled) {
                player.toggleShuffle()
            } icon: {
                Image(systemName: "shuffle")
                    .font(.system(size: 14))
                    .foregroundStyle(self.state.isShuffleEnabled ? Color.brand : .primary)
            }
            .disabled(!hasTrack)

            MacBarIconButton(label: "Previous") { player.previous() } icon: {
                Image(systemName: "backward.fill").font(.system(size: 13))
            }
            .disabled(!hasTrack)

            MacBarIconButton(label: self.state.isPlaying ? "Pause" : "Play") { player.togglePlayPause() } icon: {
                Image(systemName: self.state.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18))
                    .contentTransition(.symbolEffect(.replace))
            }

            MacBarIconButton(label: "Next") { player.next() } icon: {
                Image(systemName: "forward.fill").font(.system(size: 13))
            }
            .disabled(!hasTrack)

            MacBarIconButton(label: "Repeat", isSelected: self.state.repeatMode != .off) {
                player.cycleRepeat()
            } icon: {
                Image(systemName: self.state.repeatMode == .one ? "repeat.1" : "repeat")
                    .font(.system(size: 14))
                    .foregroundStyle(self.state.repeatMode == .off ? .primary : Color.brand)
                    .contentTransition(.symbolEffect(.replace))
            }
            .disabled(!hasTrack)

            MacBarIconButton(label: "Volume") { self.isVolumePresented.toggle() } icon: {
                Image(systemName: Self.volumeIcon(player.volume))
                    .font(.system(size: 14))
                    .contentTransition(.symbolEffect(.replace))
            }
            .popover(isPresented: self.$isVolumePresented, arrowEdge: .top) {
                MacVolumePopover()
            }
        }
    }

    private var lane: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let duration = max(self.state.duration, 0)
            let position = self.displayedPosition(at: context.date, duration: duration)
            let fraction = duration > 0 ? min(max(position / duration, 0), 1) : 0

            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    Text(Self.format(position))
                    Spacer(minLength: 8)
                    Text("-" + Self.format(max(0, duration - position)))
                }
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(height: 12)

                GeometryReader { proxy in
                    let width = proxy.size.width
                    let thumb: CGFloat = self.dragFraction != nil ? 12 : (self.isHovering ? 10 : 0)
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.14))
                        Capsule().fill(Color.brand).frame(width: max(width * fraction, 0))
                        Circle()
                            .fill(Color.brand)
                            .frame(width: thumb, height: thumb)
                            .offset(x: width * fraction - thumb / 2)
                            .opacity(thumb > 0 ? 1 : 0)
                    }
                    .frame(height: 4)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .contentShape(Rectangle().inset(by: -6))
                    .onHover { hovering in
                        withAnimation(.easeOut(duration: 0.12)) { self.isHovering = hovering && duration > 0 }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard duration > 0 else { return }
                                self.dragFraction = min(max(value.location.x / width, 0), 1)
                            }
                            .onEnded { value in
                                guard duration > 0 else { return }
                                let target = min(max(value.location.x / width, 0), 1) * duration
                                self.dragFraction = nil
                                self.pendingSeek = (target, Date().addingTimeInterval(3))
                                self.environment.player.seek(to: target)
                            }
                    )
                }
                .frame(height: 12)
            }
            .frame(height: 30)
        }
        .padding(.horizontal, 4)
        .opacity(self.state.duration > 0 ? 1 : 0.5)
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(Self.format(self.state.displayedPosition())) of \(Self.format(self.state.duration))")
    }

    private func displayedPosition(at date: Date, duration: TimeInterval) -> TimeInterval {
        if let dragFraction { return dragFraction * duration }
        let live = self.state.displayedPosition(at: date)
        if let pending = self.pendingSeek, date < pending.until, abs(live - pending.target) > 2 {
            return pending.target
        }
        return live
    }

    static func volumeIcon(_ volume: Double) -> String {
        switch volume {
        case 0: "speaker.slash.fill"
        case ..<0.34: "speaker.wave.1.fill"
        case ..<0.67: "speaker.wave.2.fill"
        default: "speaker.wave.3.fill"
        }
    }

    static func format(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Vertical volume slider in a small popover above the volume button.
private struct MacVolumePopover: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        let player = self.environment.player
        VStack(spacing: 10) {
            Image(systemName: MacProgressSection.volumeIcon(player.volume))
                .font(.system(size: 13))
                .frame(width: 16, height: 16)
            Slider(
                value: Binding(get: { player.volume }, set: { player.setVolume($0) }),
                in: 0 ... 1
            )
            .rotationEffect(.degrees(-90))
            .frame(width: 120)
            .frame(width: 24, height: 120)
            .tint(Color.brand)
            .accessibilityLabel("Volume")
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 10)
    }
}

/// 28 pt square icon button with a hover / selected fill, like Kaset's `PlayerBarIconButton`.
struct MacBarIconButton<Icon: View>: View {
    let label: LocalizedStringKey
    var isSelected = false
    let action: () -> Void
    @ViewBuilder let icon: () -> Icon

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false

    var body: some View {
        Button(action: self.action) {
            self.icon()
                .frame(width: 28, height: 28)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(self.fill)
                }
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(MacPressStyle())
        .foregroundStyle(.primary)
        .opacity(self.isEnabled ? 1 : 0.38)
        .help(Text(self.label))
        .accessibilityLabel(Text(self.label))
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { self.isHovering = hovering }
        }
    }

    private var fill: Color {
        let base: Color = self.colorScheme == .dark ? .white : .black
        if self.isHovering, self.isEnabled { return base.opacity(0.08) }
        if self.isSelected { return base.opacity(0.06) }
        return .clear
    }
}

private struct MacPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(duration: 0.18), value: configuration.isPressed)
    }
}

/// The system AirPlay / output picker.
private struct AirPlayRouteButton: NSViewRepresentable {
    func makeNSView(context _: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.isRoutePickerButtonBordered = false
        return view
    }

    func updateNSView(_: AVRoutePickerView, context _: Context) {}
}
