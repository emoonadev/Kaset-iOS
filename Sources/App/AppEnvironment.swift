import Foundation
import Observation
import WebKit

/// Owns the long-lived services.
@MainActor
@Observable
final class AppEnvironment {
    /// The one instance: the app's scene and the intents, which the system can run before any
    /// window exists, have to share the same player.
    static let shared = AppEnvironment()

    let accounts: AccountRegistry
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
    /// Name of the selected account (macOS sidebar footer).
    private(set) var accountName: String?

    /// Full-screen Now Playing. Lives here so any screen can open it (e.g. cover quick-play).
    var isNowPlayingPresented = false

    /// Bumped after the user's library changes (playlist created, renamed, deleted) so the
    /// Library screen reloads.
    var libraryRevision = 0

    /// Last song liked by an intent, so an open Now Playing shows the heart.
    var likedFromOutside: String?

    /// Bumped after every switch of Google account or channel, so screens showing personal
    /// content (and the account pickers) reload.
    private(set) var accountRevision = 0

    var isPlaybackDebugPresented = false

    /// Presents the sign-in sheet. Each presentation signs in to a fresh data store, so it
    /// adds an account; a cancelled sign-in throws that store away.
    var isLoginPresented = false {
        didSet {
            guard self.isLoginPresented != oldValue else { return }
            if self.isLoginPresented {
                // A plain "Sign in" while the active account's session is gone renews it.
                if self.reauthAccountID == nil, !self.addsNewAccount, self.auth.state == .signedOut {
                    self.reauthAccountID = self.accounts.activeID
                }
                self.addsNewAccount = false
                self.loginAccountID = self.reauthAccountID ?? UUID()
            } else if let id = self.loginAccountID {
                self.loginAccountID = nil
                if id != self.reauthAccountID {
                    Task { await AccountRegistry.removeDataStore(id) }
                }
                self.reauthAccountID = nil
            }
        }
    }

    /// Set while the sign-in sheet renews the session of an existing account (in its own store).
    @ObservationIgnored private var reauthAccountID: UUID?

    @ObservationIgnored private var addsNewAccount = false

    /// The active account's session expired: sign in again into that account's store.
    func signInAgain() {
        self.reauthAccountID = self.accounts.activeID
        self.isLoginPresented = true
    }

    /// Signs in to another Google account, kept alongside the existing ones.
    func addAccount() {
        self.addsNewAccount = true
        self.isLoginPresented = true
    }

    /// The data store of the sign-in in progress.
    @ObservationIgnored private(set) var loginAccountID: UUID?
    var loginDataStore: WKWebsiteDataStore {
        let id = self.loginAccountID ?? UUID()
        self.loginAccountID = id
        return AccountRegistry.dataStore(for: id)
    }

    init() {
        let accounts = AccountRegistry()
        self.accounts = accounts
        let auth = AuthStore(vault: accounts.activeVault, dataStore: accounts.activeDataStore)
        self.auth = auth
        self.client = YTMusicClient(auth: auth)
        self.player = WebPlayer(dataStore: { accounts.activeDataStore })
        self.client.brandIdProvider = { accounts.active?.brandId }
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

    /// Switches personal/brand identity within the active Google account: web session first,
    /// then API scope, then the player.
    func switchAccount(to account: UserAccount) async {
        guard let id = self.accounts.activeID else { return }
        await self.accountSwitcher.switchSession(to: account, in: self.accounts.activeDataStore)
        self.accounts.update(id) { $0.brandId = account.brandId }
        self.client.resetSessionState()
        self.player.reload()
        self.accountRevision += 1
        await self.refreshAccount()
    }

    /// Makes another Google account (or the guest, `nil`) active. Every web view is rebuilt on
    /// that account's data store; the last-played session belongs to the previous account, so
    /// it is dropped.
    func switchGoogleAccount(to id: UUID?) async {
        guard id != self.accounts.activeID || self.auth.state != .signedIn else { return }
        self.accounts.setActive(id)
        await self.auth.activate(dataStore: self.accounts.activeDataStore, vault: self.accounts.activeVault)
        self.client.resetSessionState()
        URLCache.shared.removeAllCachedResponses()
        self.player.reload(clearingSession: true)
        self.libraryRevision += 1
        self.accountRevision += 1
        await self.refreshAccount()
    }

    /// Launch work: put the archived session back, and reload the web view if it was missing.
    func start() async {
        await self.restoreSession()
        await self.refreshAccount()
        await self.accounts.removeOrphanedDataStores(keeping: Set([self.loginAccountID].compactMap { $0 }))
    }

    /// Runs once, whoever asks first: the launch, or an intent that arrives before it. A play
    /// issued after this is not lost to the reload.
    func restoreSession() async {
        let task = self.restoreTask ?? Task {
            let migrated = await self.accounts.migrateLegacySessionIfNeeded(
                legacyBrandIdKey: AccountSwitcher.legacyBrandIdKey
            )
            let restored = migrated
                ? await self.auth.activate(dataStore: self.accounts.activeDataStore, vault: self.accounts.activeVault)
                : await self.auth.restore()
            if migrated || restored {
                self.player.reload()
            }
        }
        self.restoreTask = task
        await task.value
    }

    func refreshAccount() async {
        defer { self.listening.use(accountID: self.accounts.activeID, email: self.accounts.active?.email) }
        guard self.auth.state == .signedIn, let id = self.accounts.activeID else {
            self.accountAvatarURL = nil
            self.accountName = nil
            return
        }
        let response = try? await self.client.fetchAccountsList()
        guard id == self.accounts.activeID else { return }
        let selected = response?.accounts.first(where: \.isSelected) ?? response?.accounts.first
        self.accountAvatarURL = selected?.thumbnailURL ?? self.accounts.active?.avatarURL
        self.accountName = selected?.name ?? self.accounts.active?.name
        let email = response?.googleEmail?.lowercased()
        self.accounts.update(id) {
            if let email { $0.email = email }
            if let selected {
                $0.name = selected.name
                $0.handle = selected.handle
                $0.avatarURL = selected.thumbnailURL
            }
        }
        // The same Google account signed in twice: keep the newest session (the active one).
        if let email {
            for duplicate in self.accounts.accounts where duplicate.id != id && duplicate.email == email {
                self.accounts.remove(duplicate.id)
                Task { await AccountRegistry.removeDataStore(duplicate.id) }
            }
        }
    }

    /// The sign-in sheet reached music.youtube.com: if its store holds a session, it becomes a
    /// new account and the active one.
    func loginFinished() async {
        guard let id = self.loginAccountID else { return }
        let cookies = await AccountRegistry.dataStore(for: id).httpCookieStore.allCookies()
        guard AuthCookies.material(from: cookies) != nil else { return }
        if !self.accounts.accounts.contains(where: { $0.id == id }) {
            self.accounts.add(GoogleAccount(id: id))
        }
        // Keep the store: it now belongs to the account.
        self.loginAccountID = nil
        self.reauthAccountID = nil
        self.isLoginPresented = false
        await self.switchGoogleAccount(to: id)
    }

    /// Signs the active account out and removes it from the device, then moves to the next
    /// account, or to the guest when it was the last one.
    func signOut() async {
        guard let id = self.accounts.activeID else {
            await self.auth.signOut()
            return
        }
        await self.auth.signOut()
        self.accounts.remove(id)
        await self.switchGoogleAccount(to: self.accounts.accounts.first?.id)
        await AccountRegistry.removeDataStore(id)
    }
}
