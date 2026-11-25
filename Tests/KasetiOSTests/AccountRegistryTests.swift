import Foundation
import Testing

@testable import KasetiOS

@MainActor
struct AccountRegistryTests {
    private let defaults: UserDefaults
    private let vaults = VaultBox()

    init() {
        let suite = "AccountRegistryTests.\(UUID().uuidString)"
        self.defaults = UserDefaults(suiteName: suite)!
        self.defaults.removePersistentDomain(forName: suite)
    }

    private func makeRegistry() -> AccountRegistry {
        AccountRegistry(defaults: self.defaults, vaultFactory: { [vaults] in vaults.vault($0) })
    }

    @Test func startsAsGuest() {
        let registry = self.makeRegistry()
        #expect(registry.accounts.isEmpty)
        #expect(registry.activeID == nil)
        #expect(registry.active == nil)
    }

    @Test func persistsAccountsAndActiveSelection() {
        let first = GoogleAccount(id: UUID(), name: "Personal")
        let second = GoogleAccount(id: UUID(), name: "Work", brandId: "UC123")
        let registry = self.makeRegistry()
        registry.add(first)
        registry.add(second)
        registry.setActive(second.id)

        let reloaded = self.makeRegistry()
        #expect(reloaded.accounts == [first, second])
        #expect(reloaded.activeID == second.id)
        #expect(reloaded.active?.brandId == "UC123")
    }

    @Test func activeFallsBackToFirstAccountWhenStoredOneIsGone() {
        let account = GoogleAccount(id: UUID())
        let registry = self.makeRegistry()
        registry.add(account)
        self.defaults.set(UUID().uuidString, forKey: "accounts.active")

        #expect(self.makeRegistry().activeID == account.id)
    }

    @Test func setActiveIgnoresUnknownIds() {
        let registry = self.makeRegistry()
        registry.add(GoogleAccount(id: UUID()))
        registry.setActive(UUID())
        #expect(registry.activeID == nil)
    }

    @Test func removeDeletesTheCookieArchiveAndClearsActive() {
        let account = GoogleAccount(id: UUID())
        let registry = self.makeRegistry()
        registry.add(account)
        registry.setActive(account.id)
        registry.vault(for: account.id).save(Data([1]))

        registry.remove(account.id)

        #expect(registry.accounts.isEmpty)
        #expect(registry.activeID == nil)
        #expect(registry.vault(for: account.id).load() == nil)
    }

    @Test func eachAccountHasItsOwnVault() {
        let a = UUID(), b = UUID()
        let registry = self.makeRegistry()
        registry.vault(for: a).save(Data([1]))
        #expect(registry.vault(for: b).load() == nil)
        #expect(registry.vault(for: a).load() == Data([1]))
    }

    @Test func updateChangesOneAccount() {
        let account = GoogleAccount(id: UUID())
        let registry = self.makeRegistry()
        registry.add(account)
        registry.update(account.id) { $0.name = "Renamed" }
        #expect(self.makeRegistry().accounts.first?.name == "Renamed")
    }
}

/// Hands out one in-memory vault per Keychain account name.
private final class VaultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var vaults: [String: InMemoryCookieVault] = [:]

    func vault(_ name: String) -> CookieVault {
        self.lock.withLock {
            if let vault = self.vaults[name] { return vault }
            let vault = InMemoryCookieVault()
            self.vaults[name] = vault
            return vault
        }
    }
}
