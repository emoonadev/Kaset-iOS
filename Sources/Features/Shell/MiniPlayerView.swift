import SwiftUI

/// Bottom accessory. Mirrors `PlaybackState`; buttons only send commands to the page.
struct MiniPlayerView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    let namespace: Namespace.ID
    let onTap: () -> Void

    var body: some View {
        let state = self.environment.player.state

        HStack(spacing: 12) {
            Button(action: self.onTap) {
                HStack(spacing: 12) {
                    ArtworkView(url: state.artworkURL)
                        .frame(width: 36, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 0) {
                        Text(state.title ?? "Not playing")
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        if self.placement != .inline, state.isAd {
                            Text("Advertisement")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if self.placement != .inline, let artist = state.artist {
                            Text(artist)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Now Playing")

            Button {
                Haptics.tap()
                self.environment.player.togglePlayPause()
            } label: {
                Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 32, height: 32)
            }
            .foregroundStyle(.primary)
            .accessibilityLabel(state.isPlaying ? "Pause" : "Play")

            Button {
                Haptics.tap()
                self.environment.player.next()
            } label: {
                Image(systemName: "forward.fill")
                    .frame(width: 32, height: 32)
            }
            .foregroundStyle(.primary)
            .disabled(!state.canGoNext)
            .accessibilityLabel("Next")
        }
        .padding(.horizontal, 12)
        .matchedTransitionSource(id: "miniPlayer", in: self.namespace)
    }
}
