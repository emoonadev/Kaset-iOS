import Foundation

/// Text handling behind the intents; no framework types, so it can be tested on its own.
enum MusicIntentText {
    /// A query worth searching: trimmed and on one line, `nil` when nothing is left.
    /// Shortcuts variables often arrive with line breaks ("Title\nArtist").
    static func normalizedQuery(_ raw: String) -> String? {
        let words = raw.split(whereSeparator: \.isWhitespace)
        return words.isEmpty ? nil : words.joined(separator: " ")
    }

    /// Whether a playlist title matches what was typed or said, ignoring case and accents.
    static func title(_ title: String, matches query: String) -> Bool {
        title.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// One line of text found in an image, with its height relative to the image.
    struct ImageLine: Equatable {
        let text: String
        let height: Double
    }

    /// Searches for what an image shows. On covers and posters the name is the largest text,
    /// so that goes first, then with the next line in case the name alone is too vague.
    /// Lines without at least two letters (dates, prices, track numbers) are ignored.
    static func imageQueries(from lines: [ImageLine]) -> [String] {
        let names = lines
            .filter { $0.text.filter(\.isLetter).count >= 2 }
            .sorted { $0.height > $1.height }
            .compactMap { self.normalizedQuery($0.text) }
        guard let first = names.first else { return [] }
        guard let second = names.dropFirst().first(where: { $0.caseInsensitiveCompare(first) != .orderedSame }) else {
            return [first]
        }
        return [first, "\(first) \(second)"]
    }
}
