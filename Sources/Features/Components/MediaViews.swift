import SwiftUI

extension View {
    /// Menus and context menus draw their icons with the tint; the accent colour is for the
    /// tab bar and primary actions, so menus use the neutral label colour instead.
    func neutralMenuTint() -> some View { self.tint(.primary) }
}

/// Square (or circular) artwork card used in shelves.
struct MediaCard: View {
    @Environment(AppEnvironment.self) private var environment

    let entity: MediaEntity
    /// `nil` fills the proposed width (grids).
    var width: CGFloat? = AdaptiveLayout.cardWidth

    /// macOS shows the play button when the pointer is over the card, as Music does; touch
    /// screens have no hover, so iOS always shows it.
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // The square sets the size; the artwork only fills it. Drawn directly, a wide
            // (video) thumbnail in fill mode would widen the card past its grid column.
            Color.clear
                .frame(width: self.width, height: self.width)
                .aspectRatio(1, contentMode: .fit)
                .overlay { ArtworkView(url: self.entity.thumbnailURL) }
                .clipShape(self.entity.isCircular ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 10, style: .continuous)))
                .overlay {
                    if self.entity.isCircular {
                        Circle().strokeBorder(.primary.opacity(0.08))
                    } else {
                        RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.primary.opacity(0.08))
                    }
                }
                .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
                .overlay(alignment: .bottomTrailing) { self.quickPlay }
                .overlay(alignment: .topLeading) { self.nowPlayingBadge }
            Text(self.entity.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .padding(.top, 2)
            if let subtitle = self.entity.subtitle {
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: self.width, alignment: .leading)
        .frame(maxWidth: self.width == nil ? .infinity : nil, alignment: .leading)
        .multilineTextAlignment(.leading)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { self.isHovering = hovering }
        }
    }

    /// Animated bars on the cover of whatever the player is on (song, playlist, album).
    @ViewBuilder
    private var nowPlayingBadge: some View {
        let identity = self.environment.player.identity
        if self.entity.isCurrent(in: identity) {
            EqualizerView(isAnimating: identity.isPlaying, color: .white)
                .frame(width: 16, height: 14)
                .padding(8)
                .background(.black.opacity(0.55), in: Circle())
                .padding(8)
                .accessibilityLabel("Now playing")
        }
    }

    /// Playlists and albums open their page on tap; this plays them without opening it.
    @ViewBuilder
    private var quickPlay: some View {
        switch self.entity.target {
        case .playlist, .album:
            Button {
                Haptics.tap()
                self.environment.playEntity(self.entity)
            } label: {
                Image(systemName: "play.fill")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(.black.opacity(0.55), in: Circle())
            }
            .buttonStyle(.plain)
            .padding(8)
            .opacity(Platform.isMac && !self.isHovering ? 0 : 1)
            .help(Text("Play \(self.entity.title)"))
            .accessibilityLabel("Play \(self.entity.title)")
        default:
            EmptyView()
        }
    }
}

/// List row used by search results.
struct MediaRow: View {
    let entity: MediaEntity

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(url: self.entity.thumbnailURL)
                .frame(width: 56, height: 56)
                .clipShape(self.entity.isCircular ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 8, style: .continuous)))
            VStack(alignment: .leading, spacing: 2) {
                Text(self.entity.title).font(.body).lineLimit(1)
                if let subtitle = self.entity.subtitle {
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

/// Wraps content so a tap and the long-press menu send commands to the web player.
/// Songs and playlists play; albums and artists open their detail screen (K8).
struct MediaActions<Content: View>: View {
    @Environment(AppEnvironment.self) private var environment

    let entity: MediaEntity
    @ViewBuilder var content: Content

    @State private var isAddToPlaylistPresented = false

    private var isSignedIn: Bool { self.environment.auth.state == .signedIn }

    var body: some View {
        self.actions
            .modifier(AddToPlaylistPresentation(entity: self.entity, isPresented: self.$isAddToPlaylistPresented))
    }

    @ViewBuilder
    private var actions: some View {
        switch self.entity.target {
        case .song, .episode:
            Button(action: self.play) { self.content }
                .buttonStyle(.plain)
                .neutralMenuTint()
                .contextMenu { self.menu }
        case .playlist, .album:
            // Like the macOS app: the page opens; playing is an explicit action.
            NavigationLink(value: self.entity) { self.content }
                .buttonStyle(.plain)
                .neutralMenuTint()
                .contextMenu {
                    Button("Play", systemImage: "play.fill") { self.environment.playEntity(self.entity) }
                    if self.isSignedIn {
                        Button("Add to Playlist…", systemImage: "text.badge.plus") {
                            self.isAddToPlaylistPresented = true
                        }
                    }
                }
        case .artist, .mood:
            NavigationLink(value: self.entity) { self.content }
                .buttonStyle(.plain)
        case .podcast:
            NavigationLink(value: self.entity) { self.content }
                .buttonStyle(.plain)
                .neutralMenuTint()
                .contextMenu {
                    Button("Play Latest Episode", systemImage: "play.fill") { self.environment.playEntity(self.entity) }
                }
        case .unsupported:
            self.content.opacity(0.5)
        }
    }

    private func play() {
        let player = self.environment.player
        switch self.entity.target {
        case let .song(videoId):
            player.play(videoId: videoId, playlistId: "RDAMVM\(videoId)")
        default:
            self.environment.playEntity(self.entity)
        }
    }

    @ViewBuilder
    private var menu: some View {
        Button("Play", systemImage: "play.fill", action: self.play)
        if let videoId = self.entity.videoId {
            Button("Play Next", systemImage: "text.insert") {
                self.environment.player.playNext(videoId: videoId)
            }
            Button("Add to Queue", systemImage: "text.append") {
                self.environment.player.addToQueue(videoId: videoId)
            }
            // A radio or a playlist built from podcast episodes is not useful.
            if case .song = self.entity.target {
                Button("Start Radio", systemImage: "dot.radiowaves.left.and.right") {
                    self.environment.player.startRadio(videoId: videoId)
                }
                if self.isSignedIn {
                    Button("Add to Playlist…", systemImage: "text.badge.plus") {
                        self.isAddToPlaylistPresented = true
                    }
                }
            }
        }
    }
}

/// Inline error with a retry action.
struct LoadFailureView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Couldn't load", systemImage: "exclamationmark.triangle")
        } description: {
            Text(self.message)
        } actions: {
            Button("Try Again", action: self.retry)
        }
    }
}

/// Hosts the add-to-playlist sheet for a cover: one song, or a playlist/album's songs.
private struct AddToPlaylistPresentation: ViewModifier {
    let entity: MediaEntity
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content.sheet(isPresented: self.$isPresented) {
            switch self.entity.target {
            case let .song(videoId):
                AddToPlaylistSheet(source: .song(videoId: videoId, title: self.entity.title))
            case let .playlist(id), let .album(id):
                AddToPlaylistSheet(source: .collection(id: id, title: self.entity.title))
            default:
                EmptyView()
            }
        }
    }
}
