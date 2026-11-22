import Foundation
import Observation

/// The plays recorded on this device, for the listening recap, one history per Google account.
/// Kept in a JSON file per account in Application Support and, once the user picked a folder
/// (iCloud Drive), merged with a file per account email in that folder so every device sees the
/// same history. CloudKit would need a paid developer account; a file the user picks works
/// without one. Nothing is recorded as a guest.
@MainActor
@Observable
final class ListeningHistory {
    /// The shared file of single-account versions; merged once into the account that inherited
    /// this device's history.
    nonisolated static let legacySyncFileName = "Kaset Listening History.json"
    private static let bookmarkKey = "recap.syncFolderBookmark"
    /// Account that inherited the history of single-account versions.
    private static let legacyOwnerKey = "recap.legacyOwner"
    private static let legacyFileName = "listening-history.json"

    nonisolated static func syncFileName(for email: String) -> String {
        "Kaset Listening History - \(email).json"
    }
    /// Writes while a play goes on are batched; a new play is saved right away.
    private static let saveInterval: TimeInterval = 30
    /// Least time between two syncs triggered by new plays.
    private static let syncInterval: TimeInterval = 10 * 60

    private(set) var log: ListeningLog
    /// Name of the sync folder, `nil` when syncing is off.
    private(set) var syncFolderName: String?
    private(set) var isSyncing = false
    private(set) var lastSync: Date?
    private(set) var syncError: String?

    @ObservationIgnored private var tracker = PlayTracker()
    /// The active account's file; `nil` as a guest (nothing is recorded).
    @ObservationIgnored private var fileURL: URL?
    @ObservationIgnored private var accountID: UUID?
    /// Email of the active account: names its sync file. Unknown yet: no syncing.
    private(set) var accountEmail: String?
    @ObservationIgnored private var lastSave = Date.distantPast
    @ObservationIgnored private var hasUnsavedChanges = false
    @ObservationIgnored private let spikeLog = SpikeLog.shared

    var plays: [ListenedPlay] { self.log.plays }

    /// Starts as a guest; `use(accountID:email:)` loads an account's history. `fileURL` loads a
    /// given file instead (tests).
    init(fileURL: URL? = nil) {
        self.fileURL = fileURL
        self.log = fileURL.flatMap(Self.load) ?? ListeningLog()
        self.syncFolderName = self.resolveSyncFolder()?.lastPathComponent
    }

    private nonisolated static func load(_ url: URL) -> ListeningLog? {
        (try? Data(contentsOf: url)).flatMap { try? ListeningLog.decode($0) }
    }

    /// Moves to another account's history (`nil`: guest). The first account to come here takes
    /// over the history recorded by single-account versions.
    func use(accountID: UUID?, email: String?) {
        let email = email?.lowercased()
        guard accountID != self.accountID || email != self.accountEmail || self.fileURL == nil else { return }
        let sameAccount = accountID == self.accountID && self.fileURL != nil
        self.accountEmail = email
        if !sameAccount {
            self.flush()
            self.tracker = PlayTracker()
            self.lastSync = nil
            self.syncError = nil
            self.accountID = accountID
            if let accountID {
                let url = Platform.appSupportFile("listening-history-\(accountID.uuidString).json")
                self.adoptLegacyHistory(into: url, for: accountID)
                self.fileURL = url
                self.log = Self.load(url) ?? ListeningLog()
            } else {
                self.fileURL = nil
                self.log = ListeningLog()
            }
        }
        if email != nil { Task { await self.sync() } }
    }

    private func adoptLegacyHistory(into url: URL, for accountID: UUID) {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: Self.legacyOwnerKey) == nil else { return }
        defaults.set(accountID.uuidString, forKey: Self.legacyOwnerKey)
        let legacy = Platform.appSupportFile(Self.legacyFileName)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: legacy.path), !fileManager.fileExists(atPath: url.path) else { return }
        try? fileManager.moveItem(at: legacy, to: url)
    }

    private var ownsLegacyHistory: Bool {
        self.accountID.map { UserDefaults.standard.string(forKey: Self.legacyOwnerKey) == $0.uuidString } ?? false
    }

    // MARK: - Recording

    /// Every state the page reports goes through here.
    func playbackChanged(_ state: PlaybackState, at date: Date) {
        guard self.fileURL != nil, let play = self.tracker.update(with: state, at: date) else { return }
        if let index = self.log.plays.lastIndex(where: { $0.id == play.id }) {
            self.log.plays[index] = play
            self.hasUnsavedChanges = true
            if date.timeIntervalSince(self.lastSave) >= Self.saveInterval { self.save() }
        } else {
            self.log.plays.append(play)
            self.spikeLog.log("recap", "play: \(play.title) — \(play.artist)")
            self.save()
            if let lastSync = self.lastSync, date.timeIntervalSince(lastSync) < Self.syncInterval { return }
            Task { await self.sync() }
        }
    }

    /// App going to the background: write what is pending.
    func flush() {
        if self.hasUnsavedChanges { self.save() }
    }

    private func save() {
        self.lastSave = Date()
        self.hasUnsavedChanges = false
        guard let fileURL = self.fileURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try self.log.encoded().write(to: fileURL, options: .atomic)
        } catch {
            self.spikeLog.log("recap", "save failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Sync

    /// Uses `folder` (picked by the user) for syncing, and syncs right away.
    func setSyncFolder(_ folder: URL) async {
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        do {
            let bookmark = try folder.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
            self.syncFolderName = folder.lastPathComponent
            self.syncError = nil
        } catch {
            self.syncError = error.localizedDescription
            return
        }
        await self.sync()
    }

    func stopSyncing() {
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        self.syncFolderName = nil
        self.lastSync = nil
        self.syncError = nil
    }

    /// Merges this device's plays with the sync file and writes the union to both.
    func sync() async {
        guard !self.isSyncing, self.fileURL != nil, let email = self.accountEmail,
              let folder = self.resolveSyncFolder() else { return }
        self.isSyncing = true
        defer { self.isSyncing = false }
        self.flush()
        let local = self.log
        let accountID = self.accountID
        let includeLegacy = self.ownsLegacyHistory
        do {
            let remote = try await Task.detached {
                try Self.syncFile(in: folder, named: Self.syncFileName(for: email), with: local, includeLegacy: includeLegacy)
            }.value
            // The account changed while syncing: this result belongs to the previous one.
            guard accountID == self.accountID else { return }
            // Plays recorded while the file was being read are kept by the merge.
            let merged = self.log.merged(with: remote)
            let added = merged.plays.count - self.log.plays.count
            if merged != self.log {
                self.log = merged
                self.save()
            }
            self.lastSync = Date()
            self.syncError = nil
            self.spikeLog.log("recap", "sync: \(merged.plays.count) plays, \(added) from other devices")
        } catch {
            self.syncError = error.localizedDescription
            self.spikeLog.log("recap", "sync failed: \(error.localizedDescription)")
        }
    }

    /// Reads the sync file, merges `local` into it and writes it back when it changed, under file
    /// coordination (iCloud Drive may be writing it from another device). Returns the merged log.
    /// While the account's file does not exist yet, `includeLegacy` seeds it with the shared file
    /// of single-account versions (left in place for devices not updated yet).
    private nonisolated static func syncFile(
        in folder: URL, named name: String, with local: ListeningLog, includeLegacy: Bool
    ) throws -> ListeningLog {
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let file = folder.appendingPathComponent(name)
        let legacyFile = folder.appendingPathComponent(self.legacySyncFileName)
        var coordinationError: NSError?
        var result: Result<ListeningLog, Error> = .success(local)
        NSFileCoordinator().coordinate(writingItemAt: file, options: .forMerging, error: &coordinationError) { url in
            do {
                var remote = ListeningLog()
                if FileManager.default.fileExists(atPath: url.path) {
                    remote = try ListeningLog.decode(Data(contentsOf: url))
                } else if includeLegacy, FileManager.default.fileExists(atPath: legacyFile.path),
                          let legacy = try? ListeningLog.decode(Data(contentsOf: legacyFile)) {
                    remote = legacy
                }
                let merged = remote.merged(with: local)
                if merged != remote { try merged.encoded().write(to: url, options: .atomic) }
                result = .success(merged)
            } catch {
                result = .failure(error)
            }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    private func resolveSyncFolder() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return nil }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &isStale) else { return nil }
        if isStale, let fresh = try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: Self.bookmarkKey)
        }
        return url
    }
}
