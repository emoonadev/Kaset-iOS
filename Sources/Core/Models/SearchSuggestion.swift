import Foundation

/// Represents a search suggestion from YouTube Music autocomplete.
struct SearchSuggestion: Identifiable, Hashable {
    /// Unique identifier for the suggestion.
    let id: String

    /// The suggested search query text.
    let query: String

    /// A past search of the signed-in account (`historySuggestionRenderer`), not a completion.
    let isFromHistory: Bool

    /// Token that removes this entry from the account's search history (`feedback` endpoint).
    let feedbackToken: String?

    /// Creates a suggestion with auto-generated ID.
    init(query: String, isFromHistory: Bool = false, feedbackToken: String? = nil) {
        self.id = UUID().uuidString
        self.query = query
        self.isFromHistory = isFromHistory
        self.feedbackToken = feedbackToken
    }

    /// Creates a suggestion with explicit ID.
    init(id: String, query: String, isFromHistory: Bool = false, feedbackToken: String? = nil) {
        self.id = id
        self.query = query
        self.isFromHistory = isFromHistory
        self.feedbackToken = feedbackToken
    }
}
