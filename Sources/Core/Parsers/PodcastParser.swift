import Foundation

// Ported from kaset: Services/API/Parsers/PodcastParser.swift, then checked against live
// responses (2026-11). Explore's "Podcasts" button now points at `FEmusic_non_music_audio`
// while kaset still uses `FEmusic_podcasts`; both are tried. On show pages the episode
// progress and duration sit inside
// `playbackProgress.musicPlaybackProgressRenderer`, the episode subtitle reads
// "<views> • <date>", the show's author is the header's `straplineTextOne` and its description
// is wrapped in a `musicDescriptionShelfRenderer`. The older flat shapes are still read.

/// Parses the podcasts discovery page (`FEmusic_podcasts`), show pages (`MPSPP…`) and their
/// episode continuations.
enum PodcastParser {
    private static let logger = DiagnosticsLogger.api

    /// Sections of a discovery page and the token of the next batch.
    struct DiscoveryPage {
        let sections: [PodcastSection]
        let continuationToken: String?
    }

    // MARK: - Where the discovery page is

    /// Browse endpoint of the Podcasts page.
    struct Endpoint: Equatable {
        let browseId: String
        let params: String?
    }

    /// Ids the Podcasts page has had, newest first; the Explore button is matched on these or
    /// on its icon.
    static let discoveryBrowseIds = ["FEmusic_non_music_audio", "FEmusic_podcasts"]
    static let knownDiscoveryBrowseIds = Set(discoveryBrowseIds)

    /// Endpoints to try for the Podcasts page: Explore's shortcut, then the known ids.
    static func discoveryCandidates(shortcut: Endpoint?) -> [Endpoint] {
        var candidates = shortcut.map { [$0] } ?? []
        for id in Self.discoveryBrowseIds where !candidates.contains(where: { $0.browseId == id }) {
            candidates.append(Endpoint(browseId: id, params: nil))
        }
        return candidates
    }

    /// The "Podcasts" shortcut of the Explore page. Not proof that the page exists: Explore
    /// keeps it in regions where the page answers 404.
    static func discoveryEndpoint(inExplore data: [String: Any]) -> Endpoint? {
        var found: Endpoint?
        Self.visit(data) { node in
            guard found == nil, let button = node["musicNavigationButtonRenderer"] as? [String: Any],
                  let command = button["clickCommand"] as? [String: Any],
                  let browse = command["browseEndpoint"] as? [String: Any],
                  let browseId = browse["browseId"] as? String
            else { return }
            let icon = ((button["iconStyle"] as? [String: Any])?["icon"] as? [String: Any])?["iconType"] as? String
            if Self.knownDiscoveryBrowseIds.contains(browseId) || icon == "BROADCAST" {
                found = Endpoint(browseId: browseId, params: browse["params"] as? String)
            }
        }
        return found
    }

    private static func visit(_ value: Any, _ body: ([String: Any]) -> Void) {
        if let dictionary = value as? [String: Any] {
            body(dictionary)
            for child in dictionary.values { Self.visit(child, body) }
        } else if let array = value as? [Any] {
            for child in array { Self.visit(child, body) }
        }
    }

    // MARK: - Discovery

    static func parseDiscovery(_ data: [String: Any]) -> DiscoveryPage {
        guard let contents = data["contents"] as? [String: Any],
              let singleColumn = contents["singleColumnBrowseResultsRenderer"] as? [String: Any],
              let sectionList = Self.firstTabSectionList(singleColumn)
        else {
            Self.logger.debug("PodcastParser: no discovery structure. Top keys: \(data.keys.sorted())")
            return DiscoveryPage(sections: [], continuationToken: nil)
        }
        let sections = (sectionList["contents"] as? [[String: Any]] ?? []).compactMap(Self.parseSection)
        return DiscoveryPage(sections: sections, continuationToken: Self.nextContinuationToken(in: sectionList))
    }

    static func parseDiscoveryContinuation(_ data: [String: Any]) -> DiscoveryPage {
        guard let continuationContents = data["continuationContents"] as? [String: Any] else {
            return DiscoveryPage(sections: [], continuationToken: nil)
        }
        if let sectionList = continuationContents["sectionListContinuation"] as? [String: Any] {
            let sections = (sectionList["contents"] as? [[String: Any]] ?? []).compactMap(Self.parseSection)
            return DiscoveryPage(sections: sections, continuationToken: Self.nextContinuationToken(in: sectionList))
        }
        return DiscoveryPage(sections: [], continuationToken: nil)
    }

    private static func parseSection(_ data: [String: Any]) -> PodcastSection? {
        if let carousel = data["musicCarouselShelfRenderer"] as? [String: Any] {
            let header = (carousel["header"] as? [String: Any])?["musicCarouselShelfBasicHeaderRenderer"] as? [String: Any]
            let title = header.flatMap { ParsingHelpers.extractTitle(from: $0) } ?? ""
            return Self.makeSection(title: title, contents: carousel["contents"] as? [[String: Any]])
        }
        if let shelf = data["musicShelfRenderer"] as? [String: Any] {
            let title = ParsingHelpers.extractTitle(from: shelf) ?? ""
            return Self.makeSection(title: title, contents: shelf["contents"] as? [[String: Any]])
        }
        if let grid = data["gridRenderer"] as? [String: Any] {
            let header = (grid["header"] as? [String: Any])?["gridHeaderRenderer"] as? [String: Any]
            let title = header.flatMap { ParsingHelpers.extractTitle(from: $0) } ?? ""
            return Self.makeSection(title: title, contents: grid["items"] as? [[String: Any]])
        }
        if let itemSection = data["itemSectionRenderer"] as? [String: Any],
           let contents = itemSection["contents"] as? [[String: Any]]
        {
            return contents.lazy.compactMap(Self.parseSection).first
        }
        return nil
    }

    private static func makeSection(title: String, contents: [[String: Any]]?) -> PodcastSection? {
        let items = (contents ?? []).compactMap(Self.parseItem)
        guard let first = items.first else { return nil }
        return PodcastSection(id: ParsingHelpers.stableId(title: title, components: first.id), title: title, items: items)
    }

    // MARK: - Podcast shelves of other pages

    /// The podcast shelves of a mixed page (Home, Explore): only shows and podcast episodes are
    /// kept, and a shelf left with nothing is dropped. Music items never count as episodes.
    static func parsePodcastShelves(_ data: [String: Any]) -> [PodcastSection] {
        guard let contents = data["contents"] as? [String: Any],
              let singleColumn = contents["singleColumnBrowseResultsRenderer"] as? [String: Any],
              let sectionList = Self.firstTabSectionList(singleColumn)
        else { return [] }
        return (sectionList["contents"] as? [[String: Any]] ?? []).compactMap { section in
            guard let carousel = section["musicCarouselShelfRenderer"] as? [String: Any] else { return nil }
            let header = (carousel["header"] as? [String: Any])?["musicCarouselShelfBasicHeaderRenderer"] as? [String: Any]
            let title = header.flatMap { ParsingHelpers.extractTitle(from: $0) } ?? ""
            let podcastItems = (carousel["contents"] as? [[String: Any]] ?? []).filter(Self.isPodcastItem)
            return Self.makeSection(title: title, contents: podcastItems)
        }
    }

    /// A show (`MPSPP…`) or an episode: multi-row items are episode rows, other items count
    /// only when their watch endpoint says podcast episode.
    static func isPodcastItem(_ data: [String: Any]) -> Bool {
        if data["musicMultiRowListItemRenderer"] != nil { return true }
        guard let renderer = (data["musicTwoRowItemRenderer"] ?? data["musicResponsiveListItemRenderer"]) as? [String: Any] else {
            return false
        }
        if let browseId = ParsingHelpers.extractBrowseId(from: renderer), Self.isPodcastShow(browseId) {
            return true
        }
        return ParsingHelpers.extractMusicVideoType(from: renderer) == .podcastEpisode
    }

    // MARK: - Items

    static func parseItem(_ data: [String: Any]) -> PodcastSectionItem? {
        if let twoRow = data["musicTwoRowItemRenderer"] as? [String: Any] {
            return Self.parseTwoRowItem(twoRow)
        }
        if let multiRow = data["musicMultiRowListItemRenderer"] as? [String: Any] {
            return Self.parseMultiRowEpisode(multiRow).map(PodcastSectionItem.episode)
        }
        if let responsive = data["musicResponsiveListItemRenderer"] as? [String: Any] {
            return Self.parseResponsiveListItem(responsive)
        }
        return nil
    }

    private static func parseTwoRowItem(_ data: [String: Any]) -> PodcastSectionItem? {
        guard let title = ParsingHelpers.extractTitle(from: data),
              let navigation = data["navigationEndpoint"] as? [String: Any]
        else { return nil }
        let thumbnailURL = ParsingHelpers.extractThumbnailURL(from: data)
        let subtitle = ParsingHelpers.extractSubtitle(from: data)

        if let browse = navigation["browseEndpoint"] as? [String: Any],
           let browseId = browse["browseId"] as? String, Self.isPodcastShow(browseId)
        {
            return .show(PodcastShow(
                id: browseId, title: title, author: subtitle, description: nil,
                thumbnailURL: thumbnailURL, episodeCount: nil, authorId: Self.channelId(in: data["subtitle"])
            ))
        }
        if let watch = navigation["watchEndpoint"] as? [String: Any], let videoId = watch["videoId"] as? String {
            return .episode(PodcastEpisode(
                id: videoId, title: title, showTitle: subtitle, showBrowseId: nil, description: nil,
                thumbnailURL: thumbnailURL, publishedDate: nil, duration: nil, durationSeconds: nil,
                playbackProgress: 0, isPlayed: false
            ))
        }
        return nil
    }

    /// The episode rows of show pages and of the discovery page.
    static func parseMultiRowEpisode(_ data: [String: Any]) -> PodcastEpisode? {
        guard let onTap = data["onTap"] as? [String: Any],
              let watch = onTap["watchEndpoint"] as? [String: Any],
              let videoId = watch["videoId"] as? String
        else { return nil }

        let title = Self.runsText(data["title"]) ?? ""
        let subtitleRuns = Self.runs(data["subtitle"])
        // Explore and Home name the show in `secondTitle`; mixed lists link it in the subtitle.
        let showRun = Self.runs(data["secondTitle"]).first { Self.showBrowseId(in: $0) != nil }
            ?? subtitleRuns.first { Self.showBrowseId(in: $0) != nil }
        let progress = Self.progress(from: data)

        let otherRuns = subtitleRuns
            .filter { ($0["text"] as? String).map(Self.isMeaningful) ?? false }
            .filter { Self.showBrowseId(in: $0) == nil }

        return PodcastEpisode(
            id: videoId,
            title: title,
            showTitle: showRun?["text"] as? String,
            showBrowseId: showRun.flatMap(Self.showBrowseId),
            description: Self.runsText(data["description"]),
            thumbnailURL: ParsingHelpers.extractThumbnailURL(from: data),
            // "22K views • 17h ago": the date is the last part.
            publishedDate: (otherRuns.last?["text"] as? String).flatMap(Self.trimmed),
            duration: progress.duration,
            durationSeconds: progress.duration.flatMap(Self.parseDurationToSeconds),
            playbackProgress: progress.fraction,
            isPlayed: progress.fraction >= 0.95
        )
    }

    private static func parseResponsiveListItem(_ data: [String: Any]) -> PodcastSectionItem? {
        let thumbnailURL = ParsingHelpers.extractThumbnailURL(from: data)
        let subtitle = ParsingHelpers.extractSubtitleFromFlexColumns(data)
        if let videoId = ParsingHelpers.extractVideoId(from: data) {
            return .episode(PodcastEpisode(
                id: videoId, title: ParsingHelpers.extractTitleFromFlexColumns(data) ?? "",
                showTitle: subtitle, showBrowseId: nil, description: nil, thumbnailURL: thumbnailURL,
                publishedDate: nil, duration: nil, durationSeconds: nil, playbackProgress: 0, isPlayed: false
            ))
        }
        if let browseId = ParsingHelpers.extractBrowseId(from: data), Self.isPodcastShow(browseId) {
            return .show(PodcastShow(
                id: browseId, title: ParsingHelpers.extractTitleFromFlexColumns(data) ?? "",
                author: subtitle, description: nil, thumbnailURL: thumbnailURL, episodeCount: nil
            ))
        }
        return nil
    }

    // MARK: - Show page

    static func parseShowDetail(_ data: [String: Any], showId: String) -> PodcastShowDetail {
        var title = ""
        var author: String?
        var description: String?
        var thumbnailURL: URL?
        var authorId: String?
        var isSubscribed = false
        var episodes: [PodcastEpisode] = []
        var token: String?

        // Older layout: a detail header at the top level.
        if let header = (data["header"] as? [String: Any])?["musicDetailHeaderRenderer"] as? [String: Any] {
            title = ParsingHelpers.extractTitle(from: header) ?? ""
            author = ParsingHelpers.extractSubtitle(from: header)
            description = Self.description(from: header)
            thumbnailURL = ParsingHelpers.extractThumbnailURL(from: header)
        }

        let contents = data["contents"] as? [String: Any]
        if let twoColumn = contents?["twoColumnBrowseResultsRenderer"] as? [String: Any] {
            let headerSections = Self.firstTabSectionList(twoColumn)?["contents"] as? [[String: Any]] ?? []
            for section in headerSections {
                guard let header = section["musicResponsiveHeaderRenderer"] as? [String: Any] else { continue }
                title = ParsingHelpers.extractTitle(from: header) ?? title
                author = Self.runsText(header["straplineTextOne"]) ?? ParsingHelpers.extractSubtitle(from: header) ?? author
                authorId = Self.channelId(in: header["straplineTextOne"]) ?? authorId
                description = Self.description(from: header) ?? description
                thumbnailURL = ParsingHelpers.extractThumbnailURL(from: header) ?? thumbnailURL
                isSubscribed = Self.isSaved(header) ?? isSubscribed
            }
            let secondary = (twoColumn["secondaryContents"] as? [String: Any])?["sectionListRenderer"] as? [String: Any]
            Self.collectEpisodes(from: secondary, into: &episodes, token: &token)
        }

        // Single-column fallback.
        if episodes.isEmpty, let singleColumn = contents?["singleColumnBrowseResultsRenderer"] as? [String: Any] {
            Self.collectEpisodes(from: Self.firstTabSectionList(singleColumn), into: &episodes, token: &token)
        }

        let show = PodcastShow(
            id: showId, title: title, author: author, description: description,
            thumbnailURL: thumbnailURL, episodeCount: nil, authorId: authorId
        )
        // The show is the context of every episode on its page.
        let attributed = episodes.map { $0.withShow(title: title.isEmpty ? nil : title, browseId: showId) }
        return PodcastShowDetail(show: show, episodes: attributed, continuationToken: token, isSubscribed: isSubscribed)
    }

    static func parseEpisodesContinuation(_ data: [String: Any]) -> PodcastEpisodesContinuation {
        var episodes: [PodcastEpisode] = []
        var token: String?
        if let continuation = data["continuationContents"] as? [String: Any],
           let shelf = continuation["musicShelfContinuation"] as? [String: Any]
        {
            episodes = (shelf["contents"] as? [[String: Any]] ?? []).compactMap(Self.episode)
            token = Self.nextContinuationToken(in: shelf)
        } else {
            // 2025-style continuations: items appended through response actions.
            let actions = data["onResponseReceivedActions"] as? [[String: Any]] ?? []
            for action in actions {
                let append = action["appendContinuationItemsAction"] as? [String: Any]
                for item in append?["continuationItems"] as? [[String: Any]] ?? [] {
                    if let episode = Self.episode(item) {
                        episodes.append(episode)
                    } else if let next = Self.continuationItemToken(item) {
                        token = next
                    }
                }
            }
        }
        return PodcastEpisodesContinuation(episodes: episodes, continuationToken: token)
    }

    private static func collectEpisodes(
        from sectionList: [String: Any]?,
        into episodes: inout [PodcastEpisode],
        token: inout String?
    ) {
        for section in sectionList?["contents"] as? [[String: Any]] ?? [] {
            guard let shelf = section["musicShelfRenderer"] as? [String: Any] else { continue }
            let items = shelf["contents"] as? [[String: Any]] ?? []
            episodes += items.compactMap(Self.episode)
            if token == nil {
                token = Self.nextContinuationToken(in: shelf)
                    ?? items.lazy.compactMap(Self.continuationItemToken).first
            }
        }
    }

    private static func episode(_ item: [String: Any]) -> PodcastEpisode? {
        if case let .episode(episode) = Self.parseItem(item) { return episode }
        return nil
    }

    // MARK: - Library

    /// The playlist behind a show (`MPSPPL…` → `PL…`): saving that playlist to the library is
    /// what YouTube Music's "Save to library" does for a podcast.
    static func playlistId(forShow browseId: String) -> String? {
        guard Self.isPodcastShow(browseId) else { return nil }
        let id = String(browseId.dropFirst("MPSP".count))
        return id.isEmpty ? nil : id
    }

    static func isPodcastShow(_ browseId: String) -> Bool {
        browseId.hasPrefix("MPSPP")
    }

    // MARK: - Helpers

    private static func firstTabSectionList(_ renderer: [String: Any]) -> [String: Any]? {
        guard let tabs = renderer["tabs"] as? [[String: Any]],
              let tab = tabs.first?["tabRenderer"] as? [String: Any],
              let content = tab["content"] as? [String: Any]
        else { return nil }
        return content["sectionListRenderer"] as? [String: Any]
    }

    private static func nextContinuationToken(in renderer: [String: Any]) -> String? {
        guard let continuations = renderer["continuations"] as? [[String: Any]] else { return nil }
        for continuation in continuations {
            for key in ["nextContinuationData", "reloadContinuationData"] {
                if let data = continuation[key] as? [String: Any], let token = data["continuation"] as? String {
                    return token
                }
            }
        }
        return nil
    }

    private static func continuationItemToken(_ item: [String: Any]) -> String? {
        guard let renderer = item["continuationItemRenderer"] as? [String: Any],
              let endpoint = renderer["continuationEndpoint"] as? [String: Any],
              let command = endpoint["continuationCommand"] as? [String: Any]
        else { return nil }
        return command["token"] as? String
    }

    private struct Progress {
        let fraction: Double
        let duration: String?
    }

    private static func progress(from data: [String: Any]) -> Progress {
        let container = data["playbackProgress"] as? [String: Any]
        let renderer = container?["musicPlaybackProgressRenderer"] as? [String: Any] ?? container ?? [:]
        let percentage = (renderer["playbackProgressPercentage"] as? NSNumber)?.doubleValue ?? 0
        let durationRuns = Self.runs(renderer["durationText"]).isEmpty
            ? Self.runs(data["durationText"]) : Self.runs(renderer["durationText"])
        let duration = durationRuns
            .compactMap { $0["text"] as? String }
            .filter(Self.isMeaningful)
            .last
            .flatMap(Self.trimmed)
        return Progress(fraction: min(max(percentage / 100, 0), 1), duration: duration)
    }

    /// The "Save to library" toggle's state, when the header has one.
    private static func isSaved(_ header: [String: Any]) -> Bool? {
        for button in header["buttons"] as? [[String: Any]] ?? [] {
            if let toggle = button["toggleButtonRenderer"] as? [String: Any], let isToggled = toggle["isToggled"] as? Bool {
                return isToggled
            }
        }
        return nil
    }

    private static func description(from header: [String: Any]) -> String? {
        guard let description = header["description"] as? [String: Any] else { return nil }
        if let shelf = description["musicDescriptionShelfRenderer"] as? [String: Any] {
            return Self.runsText(shelf["description"])
        }
        return Self.runsText(description)
    }

    /// The first channel (`UC…`) linked from a text's runs.
    private static func channelId(in value: Any?) -> String? {
        for run in Self.runs(value) {
            let navigation = run["navigationEndpoint"] as? [String: Any]
            if let browseId = (navigation?["browseEndpoint"] as? [String: Any])?["browseId"] as? String,
               Artist.isNavigableId(browseId)
            {
                return browseId
            }
        }
        return nil
    }

    private static func showBrowseId(in run: [String: Any]) -> String? {
        guard let navigation = run["navigationEndpoint"] as? [String: Any],
              let browse = navigation["browseEndpoint"] as? [String: Any],
              let browseId = browse["browseId"] as? String, Self.isPodcastShow(browseId)
        else { return nil }
        return browseId
    }

    private static func runs(_ value: Any?) -> [[String: Any]] {
        (value as? [String: Any])?["runs"] as? [[String: Any]] ?? []
    }

    private static func runsText(_ value: Any?) -> String? {
        let runs = Self.runs(value)
        guard !runs.isEmpty else { return nil }
        return Self.trimmed(ParsingHelpers.joinedRunText(runs))
    }

    /// Separators (" • ") carry no information.
    private static func isMeaningful(_ text: String) -> Bool {
        let stripped = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !stripped.isEmpty && stripped != "•" && stripped != "·"
    }

    private static func trimmed(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// "36 min", "1 hr 5 min", "1:11:19" or "42:10" → seconds.
    static func parseDurationToSeconds(_ text: String) -> Int? {
        let parts = text.split(separator: ":")
        if parts.count >= 2, parts.count <= 3 {
            let numbers = parts.compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard numbers.count == parts.count else { return nil }
            return numbers.reduce(0) { $0 * 60 + $1 }
        }
        var seconds = 0
        var matched = false
        let tokens = text.lowercased().split(separator: " ")
        var index = 0
        while index < tokens.count {
            if let value = Int(tokens[index]), index + 1 < tokens.count {
                let unit = tokens[index + 1]
                if unit.hasPrefix("h") {
                    seconds += value * 3600
                    matched = true
                } else if unit.hasPrefix("min") {
                    seconds += value * 60
                    matched = true
                } else if unit.hasPrefix("s") {
                    seconds += value
                    matched = true
                }
                index += 2
            } else {
                index += 1
            }
        }
        return matched ? seconds : nil
    }
}

extension PodcastEpisode {
    /// The same episode, credited to the show it was listed under.
    func withShow(title: String?, browseId: String) -> PodcastEpisode {
        PodcastEpisode(
            id: self.id, title: self.title, showTitle: self.showTitle ?? title,
            showBrowseId: self.showBrowseId ?? browseId, description: self.description,
            thumbnailURL: self.thumbnailURL, publishedDate: self.publishedDate, duration: self.duration,
            durationSeconds: self.durationSeconds, playbackProgress: self.playbackProgress, isPlayed: self.isPlayed
        )
    }
}
