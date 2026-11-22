import Foundation
import Observation
import WebKit

/// One signed-in Google account on this device.
///
/// Each account owns an isolated `WKWebsiteDataStore` (cookies, local storage, caches) named by
/// `id`, and a Keychain cookie archive under the same id. Brand channels of that Google account
/// are not separate entries: they are picked with `brandId` inside the account's session.
struct GoogleAccount: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    /// The Google account's email, once fetched. The `id` is random per device; the email is the
    /// same everywhere, so data shared between devices (the recap file) is keyed by it.
    var email: String?
    /// Name and photo of the identity last seen selected (shown in the account picker).
    var name: String?
    var handle: String?
    var avatarURL: URL?
    /// Selected brand channel within this Google account, `nil` for the personal channel.
    var brandId: String?
}

/// The accounts on this device and which one is active.
///
/// With no active account the app is a guest and uses the default data store, which holds no
/// Google session. Sign-in always happens in a fresh store, so adding an account never touches
/// the session of another.
@MainActor
@Observable
final class AccountRegistry {
    private static let accountsKey = "accounts.list"
    private static let activeKey = "accounts.active"
    /// Keychain item of the single-account versions, migrated on first launch.
    private static let legacyVaultAccount = "youtube-music-cookies"

    private(set) var accounts: [GoogleAccount]
    private(set) var activeID: UUID?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let vaultFactory: (String) -> CookieVault

    init(
        defaults: UserDefaults = .standard,
        vaultFactory: @escaping (String) -> CookieVault = { KeychainCookieVault(account: $0) }
    ) {
        self.defaults = defaults
        self.vaultFactory = vaultFactory
        let accounts = defaults.data(forKey: Self.accountsKey)
            .flatMap { try? JSONDecoder().decode([GoogleAccount].self, from: $0) } ?? []
        self.accounts = accounts
        let active = defaults.string(forKey: Self.activeKey).flatMap(UUID.init(uuidString:))
        self.activeID = accounts.contains { $0.id == active } ? active : accounts.first?.id
    }

    var active: GoogleAccount? { self.accounts.first { $0.id == self.activeID } }

    // MARK: - Storage per account

    static func dataStore(for id: UUID?) -> WKWebsiteDataStore {
        guard let id else { return .default() }
        return WKWebsiteDataStore(forIdentifier: id)
    }

    func vault(for id: UUID?) -> CookieVault {
        guard let id else { return InMemoryCookieVault() }
        return self.vaultFactory("cookies.\(id.uuidString)")
    }

    var activeDataStore: WKWebsiteDataStore { Self.dataStore(for: self.activeID) }
    var activeVault: CookieVault { self.vault(for: self.activeID) }

    // MARK: - Changes

    func add(_ account: GoogleAccount) {
        if let index = self.accounts.firstIndex(where: { $0.id == account.id }) {
            self.accounts[index] = account
        } else {
            self.accounts.append(account)
        }
        self.save()
    }

    func setActive(_ id: UUID?) {
        self.activeID = id.flatMap { id in self.accounts.contains { $0.id == id } ? id : nil }
        self.save()
    }

    /// Forgets the account and its cookie archive. The data store is removed by the caller
    /// once no web view uses it any more (see `removeDataStore`).
    func remove(_ id: UUID) {
        self.vault(for: id).delete()
        self.accounts.removeAll { $0.id == id }
        if self.activeID == id { self.activeID = nil }
        self.save()
    }

    func update(_ id: UUID, _ change: (inout GoogleAccount) -> Void) {
        guard let index = self.accounts.firstIndex(where: { $0.id == id }) else { return }
        var account = self.accounts[index]
        change(&account)
        guard account != self.accounts[index] else { return }
        self.accounts[index] = account
        self.save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(self.accounts) {
            self.defaults.set(data, forKey: Self.accountsKey)
        }
        self.defaults.set(self.activeID?.uuidString, forKey: Self.activeKey)
    }

    // MARK: - Data store housekeeping

    /// Deletes a data store from disk. WebKit refuses while a web view still uses it, so this
    /// retries for a few seconds; anything left over is swept by `removeOrphanedDataStores`.
    static func removeDataStore(_ id: UUID) async {
        for attempt in 0 ..< 5 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(1)) }
            do {
                try await WKWebsiteDataStore.remove(forIdentifier: id)
                return
            } catch {
                continue
            }
        }
    }

    /// Removes stores left behind by cancelled sign-ins or interrupted removals.
    func removeOrphanedDataStores(keeping extra: Set<UUID> = []) async {
        let known = Set(self.accounts.map(\.id)).union(extra)
        for id in await WKWebsiteDataStore.allDataStoreIdentifiers where !known.contains(id) {
            try? await WKWebsiteDataStore.remove(forIdentifier: id)
        }
    }

    // MARK: - Migration

    /// Single-account versions kept the session in the default data store. Moves it into an
    /// account of its own (cookies are the whole session, so copying them is enough), then
    /// clears the Google data from the default store, which from now on is the guest store.
    /// Returns `true` if an account was created.
    func migrateLegacySessionIfNeeded(legacyBrandIdKey: String) async -> Bool {
        guard self.accounts.isEmpty else { return false }
        let legacyVault = self.vaultFactory(Self.legacyVaultAccount)
        let defaultStore = WKWebsiteDataStore.default()
        let live = await defaultStore.httpCookieStore.allCookies()
        let archive = AuthCookies.archive(live) ?? legacyVault.load()
        guard let archive, !AuthCookies.restore(from: archive).isEmpty else {
            legacyVault.delete()
            return false
        }

        let account = GoogleAccount(id: UUID(), brandId: self.defaults.string(forKey: legacyBrandIdKey))
        guard self.vault(for: account.id).save(archive) else { return false }
        self.add(account)
        self.setActive(account.id)
        legacyVault.delete()
        self.defaults.removeObject(forKey: legacyBrandIdKey)
        await Self.clearGoogleData(in: defaultStore)
        return true
    }

    /// Removes Google/YouTube cookies and site data from a store.
    static func clearGoogleData(in store: WKWebsiteDataStore) async {
        for cookie in await store.httpCookieStore.allCookies() where AuthCookies.isAllowedDomain(cookie.domain) {
            await store.httpCookieStore.deleteCookie(cookie)
        }
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types)
            .filter { $0.displayName.contains("google") || $0.displayName.contains("youtube") }
        await store.removeData(ofTypes: types, for: records)
    }
}
