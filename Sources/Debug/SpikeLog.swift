import Foundation
import os

/// Timestamped log that is mirrored to `Documents/spike-log.txt` and flushed on every line,
/// so it survives the app being killed in the background.
@MainActor
final class SpikeLog: ObservableObject {
    static let shared = SpikeLog()

    @Published private(set) var lines: [String] = []
    let fileURL: URL

    private var handle: FileHandle?
    private let formatter: DateFormatter

    private init() {
        let docs = Platform.logFolder
        self.fileURL = docs.appendingPathComponent("spike-log.txt")
        self.formatter = DateFormatter()
        self.formatter.dateFormat = "HH:mm:ss.SSS"

        if !FileManager.default.fileExists(atPath: self.fileURL.path) {
            FileManager.default.createFile(atPath: self.fileURL.path, contents: nil)
        }
        self.handle = try? FileHandle(forWritingTo: self.fileURL)
        _ = try? self.handle?.seekToEnd()
        self.write("---- launch \(Date()) ----")
    }

    func log(_ category: String, _ message: String) {
        // Mirrored to the unified log so lines show up in Xcode's console (filter by subsystem
        // `dev.emoona.kaset`, or search `[queue]`, `[inspect]`) as well as in the in-app log.
        Logger(subsystem: "dev.emoona.kaset", category: category).notice("[\(category)] \(message, privacy: .public)")
        let line = "\(self.formatter.string(from: Date())) [\(category)] \(message)"
        self.lines.append(line)
        if self.lines.count > 400 {
            self.lines.removeFirst(self.lines.count - 400)
        }
        self.write(line)
    }

    func clear() {
        self.lines.removeAll()
        try? self.handle?.truncate(atOffset: 0)
        _ = try? self.handle?.seek(toOffset: 0)
    }

    private func write(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        try? self.handle?.write(contentsOf: data)
        try? self.handle?.synchronize()
    }
}
