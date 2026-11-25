import Foundation
import SwiftUI

// Trimmed from kaset: Services/API/YTMusicClient.swift (request building, auth headers,
// error mapping, pagination, API key resolution). Only Home/browse, Search, suggestions and
// their continuations are carried so far; later steps add Library, detail screens, actions.
// Auth comes from `AuthStore` instead of kaset's AuthService/WebKitManager.

// MARK: - PaginatedContentType

/// Browse surfaces that paginate via continuation tokens.
enum PaginatedContentType: String, Hashable {
    case home = "FEmusic_home"
    case explore = "FEmusic_explore"
    case charts = "FEmusic_charts"
    case moodsAndGenres = "FEmusic_moods_and_genres"
    case newReleases = "FEmusic_new_releases"
    case history = "FEmusic_history"

    var displayName: String {
        switch self {
        case .home: "home"
        case .explore: "explore"
        case .charts: "charts"
        case .moodsAndGenres: "moods and genres"
        case .newReleases: "new releases"
        case .history: "history"
        }
    }
}

// MARK: - YTMusicClient

@MainActor
final class YTMusicClient {
    enum AuthPolicy {
        case optional
        case required
    }

    private let auth: AuthStore
    private let session: URLSession
    private let apiKeyResolver: YTMusicAPIKeyResolver
    let cache: APICache
    let logger = DiagnosticsLogger.api

    /// Brand account ID for the selected account; `nil` for the primary account.
    var brandIdProvider: (() -> String?)?

    private static let baseURL = "https://music.youtube.com/youtubei/v1"
    private static let clientVersion = "1.20231204.01.00"

    private var continuationTokens: [PaginatedContentType: String] = [:]
    private var paginationEpochs: [PaginatedContentType: UInt64] = [:]
    private var continuationGeneration = 0

    init(
        auth: AuthStore,
        session: URLSession? = nil,
        apiKeyResolver: YTMusicAPIKeyResolver? = nil,
        cache: APICache = .shared
    ) {
        self.auth = auth
        let resolvedSession = session ?? URLSession(configuration: APISessionConfiguration.make())
        self.session = resolvedSession
        self.apiKeyResolver = apiKeyResolver ?? YTMusicAPIKeyResolver(session: resolvedSession)
        self.cache = cache
    }

    // MARK: - Browse pages (Home, Explore, Charts, Moods, New releases, History)

    /// First page of a browse surface; call `continuation(for:)` for the rest.
    func page(_ type: PaginatedContentType, forceRefresh: Bool = false) async throws -> HomeResponse {
        self.logger.info("Fetching \(type.displayName) page")
        let epoch = (self.paginationEpochs[type] ?? 0) &+ 1
        self.paginationEpochs[type] = epoch
        self.continuationTokens[type] = nil

        let generation = self.continuationGeneration
        // History changes with every song played: never cached.
        let data = try await self.request(
            "browse", body: ["browseId": type.rawValue],
            ttl: type == .history ? nil : APICache.TTL.home, bypassCache: forceRefresh
        )
        let response = HomeResponseParser.parse(data)
        let token = HomeResponseParser.extractContinuationToken(from: data)
        if generation == self.continuationGeneration, self.paginationEpochs[type] == epoch {
            self.continuationTokens[type] = token
        }
        return response
    }

    func hasMore(_ type: PaginatedContentType) -> Bool {
        self.continuationTokens[type] != nil
    }

    /// Next batch of sections, or `nil` when there is nothing more (or the page was superseded).
    func continuation(for type: PaginatedContentType) async throws -> [HomeSection]? {
        guard let token = self.continuationTokens[type] else { return nil }
        let generation = self.continuationGeneration
        let epoch = self.paginationEpochs[type] ?? 0

        do {
            let data = try await self.request("browse", body: ["continuation": token], ttl: APICache.TTL.home)
            let sections = HomeResponseParser.parseContinuation(data)
            guard generation == self.continuationGeneration, self.paginationEpochs[type] == epoch else {
                return nil
            }
            self.continuationTokens[type] = HomeResponseParser.extractContinuationTokenFromContinuation(data)
            return sections
        } catch is CancellationError {
            // Keep the token so the next appearance of the scroll sentinel can retry.
            throw CancellationError()
        } catch {
            if generation == self.continuationGeneration, self.paginationEpochs[type] == epoch {
                self.continuationTokens[type] = nil
            }
            throw error
        }
    }

    func getHome(forceRefresh: Bool = false) async throws -> HomeResponse {
        try await self.page(.home, forceRefresh: forceRefresh)
    }

    // MARK: - Search

    /// Search, optionally restricted to one kind (YouTube Music's own filter params, from kaset).
    func search(query: String, filter: SearchFilter = .all) async throws -> SearchResponse {
        var body: [String: Any] = ["query": query]
        if let params = filter.params { body["params"] = params }
        let data = try await self.request("search", body: body, ttl: APICache.TTL.search)
        return SearchResponseParser.parse(data)
    }

    func getSearchContinuation(token: String) async throws -> SearchResponse {
        let generation = self.continuationGeneration
        let data = try await self.request("search", body: ["continuation": token], ttl: APICache.TTL.search)
        guard generation == self.continuationGeneration else { throw CancellationError() }
        return SearchResponseParser.parseContinuation(data)
    }

    func getSearchSuggestions(query: String) async throws -> [SearchSuggestion] {
        guard !query.isEmpty else { return [] }
        // Ephemeral: not cached.
        let data = try await self.request("music/get_search_suggestions", body: ["input": query])
        return SearchSuggestionsParser.parse(data)
    }

    /// The signed-in account's recent searches: what YouTube Music lists under an empty search
    /// field. Empty as a guest.
    func getSearchHistory() async throws -> [SearchSuggestion] {
        let data = try await self.request("music/get_search_suggestions", body: ["input": ""])
        let suggestions = SearchSuggestionsParser.parse(data)
        let history = suggestions.filter(\.isFromHistory)
        // Counts only: the entries are personal.
        self.logger.debug("Search history: \(history.count) of \(suggestions.count) entries")
        return history
    }

    /// Removes entries from the account's search history.
    func removeSearchHistory(feedbackTokens: [String]) async throws {
        guard !feedbackTokens.isEmpty else { return }
        _ = try await self.request("feedback", body: ["feedbackTokens": feedbackTokens])
    }

    /// Drops cached responses and pagination state (sign-out, account switch).
    func resetSessionState() {
        self.continuationGeneration &+= 1
        self.cache.invalidateAll()
        self.continuationTokens.removeAll()
        self.paginationEpochs.removeAll()
    }

    // MARK: - Request plumbing

    static let authRequiredActionEndpoints: Set<String> = [
        "like/like", "like/dislike", "like/removelike", "feedback",
        "subscription/subscribe", "subscription/unsubscribe",
        "playlist/get_add_to_playlist", "browse/edit_playlist", "playlist/create", "playlist/delete",
    ]

    private static let authRequiredBrowseIds: Set<String> = [
        "FEmusic_liked_playlists", "FEmusic_liked_albums", "FEmusic_liked_videos",
        "FEmusic_history", "FEmusic_library_landing", "FEmusic_library_artists",
        "FEmusic_library_corpus_artists", "FEmusic_library_corpus_track_artists",
        "FEmusic_library_songs", "FEmusic_recently_played", "FEmusic_offline",
        "FEmusic_library_privately_owned_landing", "FEmusic_library_privately_owned_tracks",
        "FEmusic_library_privately_owned_albums", "FEmusic_library_privately_owned_artists",
    ]

    private func authPolicy(endpoint: String, body: [String: Any]) -> AuthPolicy {
        if Self.authRequiredActionEndpoints.contains(endpoint) { return .required }
        if endpoint == "browse", let browseId = body["browseId"] as? String,
           Self.authRequiredBrowseIds.contains(browseId)
            || browseId == LikedMusicPlaylist.browseID
            || browseId.hasPrefix("MPLAUC")
        {
            return .required
        }
        return .optional
    }

    private func headers(authPolicy: AuthPolicy) async throws -> (headers: [String: String], authenticated: Bool) {
        let origin = AuthCookies.origin
        if let material = await self.auth.material() {
            let hash = AuthCookies.sapisidHash(sapisid: material.sapisid, origin: origin, timestamp: Int(Date().timeIntervalSince1970))
            return ([
                "Cookie": material.cookieHeader,
                "Authorization": "SAPISIDHASH \(hash)",
                "Origin": origin,
                "Referer": origin,
                "Content-Type": "application/json",
                "X-Goog-AuthUser": "0",
                "X-Origin": origin,
            ], true)
        }
        if authPolicy == .required { throw YTMusicError.notAuthenticated }
        return (["Origin": origin, "Referer": origin, "Content-Type": "application/json"], false)
    }

    private func context(authenticated: Bool) -> [String: Any] {
        var user: [String: Any] = ["lockedSafetyMode": false]
        if authenticated, let brandId = self.brandIdProvider?() {
            user["onBehalfOfUser"] = brandId
        }
        return [
            "client": [
                "clientName": "WEB_REMIX",
                "clientVersion": Self.clientVersion,
                "hl": ContentLanguage.current.apiCode,
                "gl": "US",
                "experimentIds": [],
                "experimentsToken": "",
                "browserName": "Safari",
                "browserVersion": "17.0",
                "osName": "Macintosh",
                "osVersion": "10_15_7",
                "platform": "DESKTOP",
                "userAgent": APISessionConfiguration.userAgent,
                "utcOffsetMinutes": InnerTubeSupport.utcOffsetMinutes(for: .current),
            ],
            "user": user,
        ]
    }

    func request(
        _ endpoint: String,
        body: [String: Any],
        ttl: TimeInterval? = nil,
        bypassCache: Bool = false,
        authPolicy explicitPolicy: AuthPolicy? = nil
    ) async throws -> [String: Any] {
        let policy = explicitPolicy ?? self.authPolicy(endpoint: endpoint, body: body)
        let (headers, authenticated) = try await self.headers(authPolicy: policy)

        var fullBody = body
        fullBody["context"] = self.context(authenticated: authenticated)

        let scope = authenticated ? (self.brandIdProvider?() ?? "primary") : "guest"
        let cacheKey = APICache.stableCacheKey(endpoint: endpoint, body: fullBody, brandId: scope)
        if ttl != nil, !bypassCache, let cached = self.cache.get(key: cacheKey) {
            return cached
        }

        let json = try await RetryPolicy.default.execute { [self] in
            try await self.perform(endpoint, body: fullBody, headers: headers, authenticated: authenticated)
        }
        if let ttl { self.cache.set(key: cacheKey, data: json, ttl: ttl) }
        return json
    }

    private func perform(
        _ endpoint: String,
        body: [String: Any],
        headers: [String: String],
        authenticated: Bool
    ) async throws -> [String: Any] {
        let apiKey = try await self.apiKeyResolver.resolve()
        var components = URLComponents(string: "\(Self.baseURL)/\(endpoint)")
        components?.queryItems = [
            URLQueryItem(name: "key", value: apiKey),
            URLQueryItem(name: "prettyPrint", value: "false"),
        ]
        guard let url = components?.url else {
            throw YTMusicError.unknown(message: "Invalid API URL for endpoint: \(endpoint)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = authenticated
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        switch try await Self.send(request, session: self.session) {
        case let .success(data):
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw YTMusicError.parseError(message: "Response is not a JSON object")
            }
            return json
        case let .authError(statusCode):
            self.logger.error("Auth error: HTTP \(statusCode)")
            guard authenticated else { throw YTMusicError.notAuthenticated }
            self.auth.sessionExpired()
            throw YTMusicError.authExpired
        case let .httpError(statusCode):
            throw YTMusicError.apiError(message: "HTTP \(statusCode)", code: statusCode)
        case let .networkError(error):
            if let urlError = error as? URLError, urlError.code == .cancelled { throw CancellationError() }
            throw YTMusicError.networkError(underlying: error)
        }
    }

    private enum NetworkResult {
        case success(Data)
        case authError(statusCode: Int)
        case httpError(statusCode: Int)
        case networkError(Error)
    }

    nonisolated private static func send(_ request: URLRequest, session: URLSession) async throws -> NetworkResult {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .networkError(URLError(.badServerResponse))
            }
            if http.statusCode == 401 || http.statusCode == 403 { return .authError(statusCode: http.statusCode) }
            guard (200 ... 299).contains(http.statusCode) else { return .httpError(statusCode: http.statusCode) }
            return .success(data)
        } catch {
            return .networkError(error)
        }
    }
}

// MARK: - YTMusicAPIKeyResolver

/// Resolves the web client's public Innertube API key from the music.youtube.com page
/// instead of storing one in source (kaset `YTMusicAPIKeyResolver`).
@MainActor
final class YTMusicAPIKeyResolver {
    nonisolated static let environmentVariable = "KASET_YTMUSIC_API_KEY"
    nonisolated static let defaultWebClientURL = URL(string: "https://music.youtube.com")!

    private let session: URLSession
    private let webClientURL: URL
    private var cachedAPIKey: String?
    private var inFlightResolve: Task<String, any Error>?

    init(session: URLSession = .shared, webClientURL: URL = defaultWebClientURL) {
        self.session = session
        self.webClientURL = webClientURL
    }

    func resolve() async throws -> String {
        if let cachedAPIKey { return cachedAPIKey }
        if let override = ProcessInfo.processInfo.environment[Self.environmentVariable]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty
        {
            self.cachedAPIKey = override
            return override
        }
        if let inFlightResolve { return try await inFlightResolve.value }

        let task = Task { [session, webClientURL] in
            try await Self.fetchAPIKey(session: session, webClientURL: webClientURL)
        }
        self.inFlightResolve = task
        defer { self.inFlightResolve = nil }
        let key = try await task.value
        self.cachedAPIKey = key
        return key
    }

    nonisolated private static func fetchAPIKey(session: URLSession, webClientURL: URL) async throws -> String {
        do {
            var request = URLRequest(url: webClientURL)
            request.setValue(APISessionConfiguration.userAgent, forHTTPHeaderField: "User-Agent")
            // Public key: never send the user's cookies. A stale consent cookie lands on the EU
            // consent interstitial, whose HTML has no key. A pre-accepted SOCS cookie bypasses it.
            request.httpShouldHandleCookies = false
            request.setValue("SOCS=CAI", forHTTPHeaderField: "Cookie")
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200 ... 399).contains(http.statusCode) {
                throw YTMusicError.apiError(message: "Could not load YouTube Music web client configuration", code: http.statusCode)
            }
            guard let html = String(data: data, encoding: .utf8), let key = Self.extractInnertubeAPIKey(from: html) else {
                throw YTMusicError.parseError(message: "Could not resolve YouTube Music API configuration")
            }
            return key
        } catch let error as YTMusicError {
            throw error
        } catch {
            throw YTMusicError.networkError(underlying: error)
        }
    }

    nonisolated static func extractInnertubeAPIKey(from html: String) -> String? {
        let pattern = #""INNERTUBE_API_KEY"\s*:\s*"([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex ..< html.endIndex, in: html)),
              let range = Range(match.range(at: 1), in: html)
        else { return nil }
        return String(html[range])
    }
}

/// Result kinds the search screen can restrict to. The `params` strings are the ones kaset's
/// `YTMusicClient.SearchFilterParams` sends.
enum SearchFilter: String, CaseIterable, Identifiable {
    case all, songs, artists, albums, playlists, videos

    var id: String { self.rawValue }

    var params: String? {
        switch self {
        case .all: nil
        case .songs: "EgWKAQIIAWoMEA4QChADEAQQCRAF"
        case .videos: "EgWKAQIQAWoMEA4QChADEAQQCRAF"
        case .albums: "EgWKAQIYAWoMEA4QChADEAQQCRAF"
        case .artists: "EgWKAQIgAWoMEA4QChADEAQQCRAF"
        case .playlists: "EgWKAQIoAWoMEA4QChADEAQQCRAF"
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .all: "All"
        case .songs: "Songs"
        case .artists: "Artists"
        case .albums: "Albums"
        case .playlists: "Playlists"
        case .videos: "Videos"
        }
    }

    var symbol: String {
        switch self {
        case .all: "square.grid.2x2"
        case .songs: "music.note"
        case .artists: "music.mic"
        case .albums: "square.stack"
        case .playlists: "music.note.list"
        case .videos: "play.rectangle"
        }
    }
}
