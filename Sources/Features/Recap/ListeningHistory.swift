import Foundation
import Observation

/// The plays recorded on this device, for the listening recap. Kept in a JSON file in
/// Application Support and, once the user picked a folder (iCloud Drive), merged with a file in
/// that folder so every device sees the same history. CloudKit would need a paid developer
/// account; a file the user picks works without one.
@MainActor
@Observable
final class ListeningHistory {
    nonisolated static let syncFileName = "Kaset Listening History.json"
    private static let bookmarkKey = "recap.syncFolderBookmark"
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
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private var lastSave = Date.distantPast
    @ObservationIgnored private var hasUnsavedChanges = false
    @ObservationIgnored private let spikeLog = SpikeLog.shared

    var plays: [ListenedPlay] { self.log.plays }

    init(fileURL: URL? = nil) {
        let url = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("listening-history.json")
        self.fileURL = url
        self.log = (try? Data(contentsOf: url)).flatMap { try? ListeningLog.decode($0) } ?? ListeningLog()
        self.syncFolderName = self.resolveSyncFolder()?.lastPathComponent
    }

    // MARK: - Recording

    /// Every state the page reports goes through here.
    func playbackChanged(_ state: PlaybackState, at date: Date) {
        guard let play = self.tracker.update(with: state, at: date) else { return }
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
        do {
            try FileManager.default.createDirectory(
                at: self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try self.log.encoded().write(to: self.fileURL, options: .atomic)
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
        guard !self.isSyncing, let folder = self.resolveSyncFolder() else { return }
        self.isSyncing = true
        defer { self.isSyncing = false }
        self.flush()
        let local = self.log
        do {
            let remote = try await Task.detached { try Self.syncFile(in: folder, with: local) }.value
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
    private nonisolated static func syncFile(in folder: URL, with local: ListeningLog) throws -> ListeningLog {
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let file = folder.appendingPathComponent(self.syncFileName)
        var coordinationError: NSError?
        var result: Result<ListeningLog, Error> = .success(local)
        NSFileCoordinator().coordinate(writingItemAt: file, options: .forMerging, error: &coordinationError) { url in
            do {
                var remote = ListeningLog()
                if FileManager.default.fileExists(atPath: url.path) {
                    remote = try ListeningLog.decode(Data(contentsOf: url))
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
