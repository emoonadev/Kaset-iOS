import Foundation
import Observation

/// Owns the long-lived services.
@MainActor
@Observable
final class AppEnvironment {
    /// The one instance: the app's scene and the intents, which the system can run before any
    /// window exists, have to share the same player.
    static let shared = AppEnvironment()

    let auth: AuthStore
    let client: YTMusicClient
    let player: WebPlayer
    let mixes = ArtistMixLibrary()
    let newReleases = NewReleaseWatcher()
    let listening = ListeningHistory()
    private let accountSwitcher = AccountSwitcher()
    @ObservationIgnored private var restoreTask: Task<Void, Never>?

    /// Photo of the selected account, for the navigation bar button.
    private(set) var accountAvatarURL: URL?

    /// Full-screen Now Playing. Lives here so any screen can open it (e.g. cover quick-play).
    var isNowPlayingPresented = false

    /// Bumped after the user's library changes (playlist created, renamed, deleted) so the
    /// Library screen reloads.
    var libraryRevision = 0

    /// Last song liked by an intent, so an open Now Playing shows the heart.
    var likedFromOutside: String?

    var isPlaybackDebugPresented = false
    var isLoginPresented = false

    init() {
        let auth = AuthStore()
        self.auth = auth
        self.client = YTMusicClient(auth: auth)
        self.player = WebPlayer()
        self.client.brandIdProvider = { AccountSwitcher.storedBrandId }
        let listening = self.listening
        self.player.onStateChange = { state, date in listening.playbackChanged(state, at: date) }
    }

    /// Plays an entity without opening its page. Playlists use their id as the queue; an album's
    /// playable `OLAK…` id is only known from its detail, so that is fetched first.
    func playEntity(_ entity: MediaEntity, opensNowPlaying: Bool = true) {
        if opensNowPlaying, entity.target.isPlayableCollection { self.isNowPlayingPresented = true }
        switch entity.target {
        case let .song(videoId):
            self.player.play(videoId: videoId, playlistId: "RDAMVM\(videoId)")
        case let .playlist(id):
            self.player.play(videoId: nil, playlistId: MediaEntity.watchPlaylistId(id))
        case let .album(id):
            Task {
                guard let detail = try? await self.client.getPlaylist(id: id).detail else { return }
                if let target = detail.libraryTargetId, !target.isEmpty {
                    self.player.play(videoId: nil, playlistId: MediaEntity.watchPlaylistId(target))
                } else if let first = detail.tracks.first(where: \.isPlayable) {
                    self.player.play(videoId: first.videoId, playlistId: "RDAMVM\(first.videoId)")
                }
            }
        case .artist, .mood, .unsupported:
            break
        }
    }

    /// Switches personal/brand identity: web session first, then API scope, then the player.
    func switchAccount(to account: UserAccount) async {
        await self.accountSwitcher.switchSession(to: account)
        self.client.resetSessionState()
        self.player.reload()
    }

    /// Launch work: put the archived session back, and reload the web view if it was missing.
    func start() async {
        await self.restoreSession()
        await self.refreshAccount()
    }

    /// Runs once, whoever asks first: the launch, or an intent that arrives before it. A play
    /// issued after this is not lost to the reload.
    func restoreSession() async {
        let task = self.restoreTask ?? Task {
            if await self.auth.restore() {
                self.player.reload()
            }
        }
        self.restoreTask = task
        await task.value
    }

    func refreshAccount() async {
        guard self.auth.state == .signedIn else {
            self.accountAvatarURL = nil
            return
        }
        let accounts = try? await self.client.fetchAccountsList().accounts
        self.accountAvatarURL = (accounts?.first(where: \.isSelected) ?? accounts?.first)?.thumbnailURL
    }

    func loginFinished() async {
        if await self.auth.loginFinished() {
            self.isLoginPresented = false
            self.player.reload()
            await self.refreshAccount()
        }
    }

    func signOut() async {
        await self.auth.signOut()
        UserDefaults.standard.removeObject(forKey: AccountSwitcher.brandIdKey)
        self.accountAvatarURL = nil
        self.client.resetSessionState()
        self.player.reload(clearingSession: true)
    }
}
