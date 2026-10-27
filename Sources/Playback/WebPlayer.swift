import AVFoundation
import CallKit
import MediaPlayer
import Network
import Observation
import UIKit
import WebKit

@MainActor
private final class MessageProxy: NSObject, WKScriptMessageHandler {
    weak var target: WebPlayer?

    func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        self.target?.handle(body)
    }
}

/// The playback engine: a hidden `music.youtube.com` web view that owns the queue.
///
/// Commands are forwarded to the page; `state` only changes when the page reports back.
/// Evolved from the spike's `PlayerModel` (evidence in `docs/spike-findings.md`).
@MainActor
@Observable
final class WebPlayer: NSObject {
    static let homeURL = URL(string: "https://music.youtube.com")!
    static let desktopUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    private(set) var webView: WKWebView
    private(set) var state = PlaybackState() {
        didSet { self.refreshIdentity() }
    }
    /// Changes only when the track, list or play state does (see `PlaybackIdentity`).
    private(set) var identity = PlaybackIdentity()
    /// Result of the last play-next attempt: `(videoId, success, reason)`.
    private(set) var lastQueueResult: (videoId: String, success: Bool, reason: String)?
    private(set) var generation = 0
    /// True while a queue reorder is rewriting the page's queue.
    private(set) var isReorderingQueue = false
    /// Short message about the last queue operation (shown briefly by the shell).
    private(set) var queueNotice: String?
    /// When the page last reported anything, and the page's address; for the debug readout.
    private(set) var lastMessageAt: Date?
    private(set) var pageURL: String?
    /// Last player health probe (run a few seconds after each track change, or on demand).
    private(set) var healthReport: PlayerHealthReport?
    /// Called with every state the page reports (the listening recap counts plays from it).
    @ObservationIgnored var onStateChange: ((PlaybackState, Date) -> Void)?

    @ObservationIgnored private let log = SpikeLog.shared
    @ObservationIgnored private let proxy = MessageProxy()
    @ObservationIgnored private let nowPlaying = NowPlayingPublisher()
    @ObservationIgnored private var lastBeat: Date?
    @ObservationIgnored private var lastRemoteCommand = Date.distantPast
    @ObservationIgnored private var queueAttempt = 0
    @ObservationIgnored private var pendingQueueResults: [Int: CheckedContinuation<(success: Bool, reason: String), Never>] = [:]
    /// Remaining automatic retries for user-initiated queue operations, by video id.
    @ObservationIgnored private var queueRetries: [String: Int] = [:]
    @ObservationIgnored private var lastRecovery = Date.distantPast
    @ObservationIgnored private var lastSavedAt = Date.distantPast
    @ObservationIgnored private var lastEvent = ""
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private let callObserver = CXCallObserver()
    @ObservationIgnored private var callDelegate: CallDelegate?
    /// A phone call is in progress and playback was paused for it.
    @ObservationIgnored private var isInCall = false
    @ObservationIgnored private var pausedForCall = false
    /// Set when the app goes to the background while playing: iOS/WebKit can pause the media at
    /// that moment even though background audio is allowed; we resume it right away.
    @ObservationIgnored private var playingWhenBackgrounded = false
    @ObservationIgnored private var backgroundedAt = Date.distantPast
    @ObservationIgnored private var resumedAfterBackgroundPause = false
    /// Increments on every page event; lets delayed checks know nothing newer happened.
    @ObservationIgnored private var eventSerial = 0
    /// The page was told to stand down for a call (`setInterrupted(true)`) and not yet released.
    @ObservationIgnored private var pageIsInterrupted = false
    @ObservationIgnored private var wasOffline = false
    @ObservationIgnored private var isOnline = true
    /// Playing when the network dropped: resume once it is back.
    @ObservationIgnored private var playingWhenWentOffline = false
    @ObservationIgnored private var wentOfflineAt = Date.distantPast
    /// A recovery was skipped because there was no network to reload with.
    @ObservationIgnored private var recoveryPendingNetwork = false
    @ObservationIgnored private var lastUserPause = Date.distantPast
    @ObservationIgnored private var lastSeekCommand = Date.distantPast
    /// Why the audio quality is temporarily lowered (`nil`: the user's setting applies).
    @ObservationIgnored private var lowQualityReason: String?
    @ObservationIgnored private var lastUnderrun = Date.distantPast
    /// The media element reported `error` (seen when the device locks while paused) and has
    /// not played since; play must reload the track instead of pressing play on it.
    @ObservationIgnored private var mediaFailed = false
    @ObservationIgnored private var lastBufferLog = Date.distantPast
    @ObservationIgnored private var positionBeforeError: TimeInterval = 0
    /// True while the mini player shows the last session and the page has no media yet.
    @ObservationIgnored private var isShowingRestoredSession = false
    /// A music.youtube.com document has finished loading in the current web view.
    @ObservationIgnored private var hasLoadedPage = false

    override init() {
        self.webView = Self.makeWebView(proxy: self.proxy)
        super.init()
        self.proxy.target = self
        self.attach(self.webView)
        self.configureAudioSession()
        self.observeAudioSession()
        self.observeLifecycle()
        self.configureRemoteCommands()
        self.webView.load(URLRequest(url: Self.homeURL))
        self.restoreSavedSession()
        self.startPathMonitor()
        if Self.handlesPhoneCalls { self.observeCalls() }
    }

    // MARK: - Web view

    private static func makeWebView(proxy: MessageProxy) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        // Without inline playback iOS promotes the video to full screen; without these two
        // it also starts Picture in Picture (spike findings).
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.allowsAirPlayForMediaPlayback = true
        configuration.allowsPictureInPictureMediaPlayback = false
        configuration.applicationNameForUserAgent = "Version/17.0 Mobile/15E148 Safari/604.1"

        let preferences = WKWebpagePreferences()
        preferences.preferredContentMode = .desktop
        configuration.defaultWebpagePreferences = preferences

        configuration.userContentController.addUserScript(WKUserScript(
            source: BufferScripts.bootstrap(extended: BufferPolicy.isExtended),
            injectionTime: .atDocumentStart, forMainFrameOnly: true
        ))
        configuration.userContentController.addUserScript(WKUserScript(
            source: PlayerScripts.page, injectionTime: .atDocumentStart, forMainFrameOnly: true
        ))
        configuration.userContentController.addUserScript(WKUserScript(
            source: PlaybackAudioQualityScripts.playbackAudioQualityBootstrapScript(quality: .current),
            injectionTime: .atDocumentStart, forMainFrameOnly: true
        ))
        configuration.userContentController.addUserScript(WKUserScript(
            source: PlaybackAudioQualityScripts.playbackAudioQualityOverrideScript,
            injectionTime: .atDocumentEnd, forMainFrameOnly: true
        ))
        configuration.userContentController.add(proxy, name: PlayerScripts.bridgeName)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = Self.desktopUserAgent
        #if DEBUG
            webView.isInspectable = true
        #endif
        return webView
    }

    private func attach(_ webView: WKWebView) {
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    /// Rebuilds the web view (e.g. after sign-in so the page picks up the session).
    ///
    /// Also drops everything that outlives the old page: the system Now Playing entry (lock
    /// screen / Control Center), its media playback, and optionally the saved session (sign-out).
    func reload(clearingSession: Bool = false) {
        let old = self.webView
        Task { await old.pauseAllMediaPlayback() }
        old.stopLoading()
        old.configuration.userContentController.removeScriptMessageHandler(forName: PlayerScripts.bridgeName)
        old.load(URLRequest(url: URL(string: "about:blank")!))

        let fresh = Self.makeWebView(proxy: self.proxy)
        self.attach(fresh)
        self.webView = fresh
        self.generation += 1
        self.state = PlaybackState()
        self.isShowingRestoredSession = false
        self.lastBeat = nil
        self.lastEvent = ""
        self.hasLoadedPage = false
        self.nowPlaying.clear()
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        if clearingSession {
            UserDefaults.standard.removeObject(forKey: Self.savedSessionKey)
        }
        fresh.load(URLRequest(url: Self.homeURL))
        self.log.log("web", "reloaded (clearingSession=\(clearingSession))")
    }

    // MARK: - Commands (forwarded to the page)

    /// Starts a song, optionally inside a playlist/radio so the page owns a real queue.
    func play(videoId: String?, playlistId: String? = nil) {
        guard videoId != nil || playlistId != nil else { return }
        self.playRequest &+= 1
        let request = self.playRequest
        var components = URLComponents(string: "https://music.youtube.com/watch")!
        var items: [URLQueryItem] = []
        if let videoId { items.append(URLQueryItem(name: "v", value: videoId)) }
        if let playlistId { items.append(URLQueryItem(name: "list", value: playlistId)) }
        components.queryItems = items
        guard let url = components.url else { return }
        // With a document already loaded, navigate inside it through the web app's own router
        // (as kaset does): no new document to download, boot and run, so playback starts much
        // sooner than with a full page load. Falls back to the load if the router is missing.
        if let videoId, self.hasLoadedPage {
            let endpoint = PlayerScripts.watchEndpointScript(videoId: videoId, playlistId: playlistId)
            self.webView.evaluateJavaScript(endpoint) { [weak self] result, _ in
                Task { @MainActor in
                    guard let self else { return }
                    guard let via = result as? String else {
                        self.log.log("cmd", "no in-page navigation, loading the watch page")
                        self.webView.load(URLRequest(url: url))
                        return
                    }
                    self.log.log("cmd", "\(via) watch v=\(videoId) list=\(playlistId ?? "-")")
                    if via != "resolveCommand" { self.logRouterCandidatesOnce() }
                    // An event nobody handles fails silently: load the page if the track did not change.
                    try? await Task.sleep(for: .seconds(3))
                    // A newer play request owns the page now; checking this one would reload a stale track.
                    guard request == self.playRequest, self.state.videoId != videoId else { return }
                    self.log.log("cmd", "\(via) did not start \(videoId), loading the watch page")
                    self.webView.load(URLRequest(url: url))
                }
            }
            return
        }
        self.log.log("cmd", "load watch v=\(videoId ?? "-") list=\(playlistId ?? "-")")
        self.webView.load(URLRequest(url: url))
    }

    @ObservationIgnored private var loggedRouterCandidates = false
    /// Increments on every `play`; lets the delayed navigation check tell it was superseded.
    @ObservationIgnored private var playRequest = 0

    private func logRouterCandidatesOnce() {
        guard !self.loggedRouterCandidates else { return }
        self.loggedRouterCandidates = true
        self.webView.evaluateJavaScript(PlayerScripts.routerCandidatesScript) { [weak self] result, _ in
            Task { @MainActor in self?.log.log("router", "ytmusic-app: \((result as? String) ?? "?")") }
        }
    }

    /// Plays the song followed by its radio (YouTube Music's endless queue of similar songs).
    func startRadio(videoId: String) {
        self.play(videoId: videoId, playlistId: "RDAMVM\(videoId)")
    }

    /// Jumps to / removes an entry of the page's queue by its position.
    func playQueueEntry(at index: Int) { self.command("playQueueIndex", argument: String(index)) }
    func removeQueueEntry(at index: Int) {
        Task {
            if let reason = await self.removeQueueEntryAndWait(at: index) {
                self.postNotice("Couldn't remove from the queue (\(reason.prefix(90)))")
            }
            self.refreshState()
        }
    }

    /// Dumps what the page's queue component exposes (methods, data keys) into the log, to look
    /// for a real reorder primitive. Diagnostics only.
    func inspectQueue() {
        self.webView.evaluateJavaScript("window.__kaset ? window.__kaset.inspectQueue() : 'no-page'") { [weak self] result, error in
            Task { @MainActor in
                let text = (result as? String) ?? error?.localizedDescription ?? "nil"
                for line in text.split(separator: "\n") { self?.log.log("inspect", String(line)) }
            }
        }
    }

    /// Probes the page parts the app drives (read-only) and keeps the result in `healthReport`.
    /// Checks that start failing are written to the log.
    @discardableResult
    func checkHealth() async -> PlayerHealthReport {
        let js = "JSON.stringify(window.__kaset && window.__kaset.health ? window.__kaset.health() : null)"
        let report: PlayerHealthReport
        do {
            let text = try await self.webView.evaluateJavaScript(js) as? String ?? "null"
            report = PlayerHealthReport.parse(text) ?? .unreachable(self.hasLoadedPage ? "page script not running" : "page not loaded")
        } catch {
            report = .unreachable(error.localizedDescription)
        }
        let previouslyFailing = Set(self.healthReport?.failing.map(\.id) ?? [])
        for check in report.failing where !previouslyFailing.contains(check.id) {
            self.log.log("health", "FAILING \(check.id): \(check.detail)")
        }
        self.healthReport = report
        return report
    }

    /// Runs the probe once the new track has had time to fill the player bar and queue.
    private func scheduleHealthCheck() {
        guard let videoId = self.state.videoId else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard let self, self.state.videoId == videoId else { return }
            await self.checkHealth()
        }
    }

    func toggleShuffle() { self.command("shuffle") }
    func cycleRepeat() { self.command("repeat") }

    /// Starts a playlist and turns the page's shuffle on once the player has loaded.
    func playShuffled(videoId: String?, playlistId: String) {
        self.play(videoId: videoId, playlistId: playlistId)
        Task {
            for _ in 0 ..< 20 {
                try? await Task.sleep(for: .seconds(1))
                guard self.state.hasMedia, self.state.isPlaying || self.state.duration > 0 else { continue }
                if !self.state.isShuffleEnabled { self.toggleShuffle() }
                return
            }
        }
    }

    func resume() {
        if !self.state.hasMedia, self.resumeSavedSession() { return }
        if self.recoverFailedMedia() { return }
        self.command("play")
    }
    func pause() {
        self.lastUserPause = Date()
        self.command("pause")
    }
    func togglePlayPause() {
        if !self.state.hasMedia, self.resumeSavedSession() { return }
        if self.recoverFailedMedia() { return }
        if self.state.isPlaying { self.lastUserPause = Date() }
        self.command("toggle")
    }
    func next() { self.command("next") }
    func previous() { self.command("previous") }

    func seek(to seconds: TimeInterval) {
        self.lastSeekCommand = Date()
        self.command("seek", argument: String(max(0, seconds)))
    }

    /// Asks the page to insert `videoId` right after the current track. The outcome comes back
    /// asynchronously in `lastQueueResult`; returns `false` if nothing is playing.
    @discardableResult
    func playNext(videoId: String) -> Bool {
        guard let source = self.state.videoId else {
            // Nothing is playing: "play next" is just "play".
            self.play(videoId: videoId, playlistId: "RDAMVM\(videoId)")
            return true
        }
        self.queueAttempt += 1
        self.queueRetries[videoId] = 2
        let script = PlayerScripts.playNext(videoId: videoId, afterVideoId: source, attempt: self.queueAttempt)
        self.log.log("cmd", "playNext \(videoId) after \(source)")
        self.webView.evaluateJavaScript(script, completionHandler: nil)
        return true
    }

    private static let transientQueueFailures: Set<String> = [
        "play-next-item-not-found", "add-to-queue-item-not-found", "menu-timeout",
        "player-bar-menu-not-found", "queue-source-not-ready", "menu-source-mismatch",
    ]

    private func refreshIdentity() {
        let next = PlaybackIdentity(
            videoId: self.state.hasMedia ? self.state.videoId : nil,
            listId: self.state.listId,
            album: self.state.album,
            isPlaying: self.state.isPlaying
        )
        if next != self.identity { self.identity = next }
    }

    /// Shows a short message in the banner the shell uses for queue notices.
    func showNotice(_ text: String) { self.postNotice(text) }

    private func postNotice(_ text: String) {
        self.queueNotice = text
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3.5))
            if self?.queueNotice == text { self?.queueNotice = nil }
        }
    }

    /// A queue insertion that waits for the page's readback, retrying transient menu failures.
    private func insertAndWait(videoId: String, mode: QueueReorderPlan.Mode, after sourceVideoId: String) async -> Bool {
        for attempt in 1 ... 3 {
            self.queueAttempt += 1
            let id = self.queueAttempt
            let script = switch mode {
            case .front: PlayerScripts.playNext(videoId: videoId, afterVideoId: sourceVideoId, attempt: id)
            case .end: PlayerScripts.addToQueue(videoId: videoId, attempt: id)
            }
            let result = await withCheckedContinuation { (continuation: CheckedContinuation<(success: Bool, reason: String), Never>) in
                self.pendingQueueResults[id] = continuation
                self.webView.evaluateJavaScript(script, completionHandler: nil)
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(12))
                    self?.pendingQueueResults.removeValue(forKey: id)?.resume(returning: (false, "timeout"))
                }
            }
            if result.success { return true }
            self.log.log("queue", "insert \(videoId) attempt \(attempt): \(result.reason)")
            guard Self.transientQueueFailures.contains(result.reason) else { return false }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return false
    }

    /// Returns `nil` on success, or what the page reported.
    private func removeQueueEntryAndWait(at index: Int) async -> String? {
        let js = "return await window.__kaset.removeQueueIndexAsync(index);"
        let result = (try? await self.webView.callAsyncJavaScript(
            js, arguments: ["index": index], in: nil, contentWorld: .page
        ) as? String) ?? "no-result"
        self.log.log("queue", "remove[\(index)] → \(result)")
        return result == "removed" ? nil : result
    }

    /// Moves an Up Next entry. The page exposes no reorder primitive, so the cheaper side of
    /// Up Next (front or tail, see `QueueReorderPlan`) is removed and re-inserted in its new order.
    ///
    /// - Parameters are positions in the queue snapshot (`state.queue`); `destination` is the
    ///   position the entry must end at.
    func moveQueueEntry(from source: Int, to destination: Int) async {
        guard !self.isReorderingQueue else { return }
        let queue = self.state.queue
        guard let current = queue.firstIndex(where: \.isCurrent) else {
            self.log.log("queue", "reorder skipped: the page reports no current queue entry")
            self.postNotice("Couldn't reorder: current track not found in the queue")
            return
        }
        let currentVideoId = queue[current].videoId.isEmpty ? (self.state.videoId ?? "") : queue[current].videoId
        guard !currentVideoId.isEmpty,
              let plan = QueueReorderPlan.make(
                  ids: queue.map(\.videoId), current: current, source: source, destination: destination
              ),
              !plan.insertions.contains(where: \.isEmpty)
        else {
            self.log.log("queue", "reorder skipped: source=\(source) dest=\(destination) current=\(current) count=\(queue.count)")
            self.postNotice("Couldn't reorder this entry")
            return
        }

        self.isReorderingQueue = true
        defer { self.isReorderingQueue = false }
        self.log.log("queue", "reorder \(source)→\(destination): \(plan.mode) · \(plan.operationCount) operations")

        // Remove back to front so earlier indices stay valid.
        for index in plan.removeIndices {
            if let reason = await self.removeQueueEntryAndWait(at: index) {
                self.log.log("queue", "reorder aborted while removing index \(index): \(reason)")
                self.postNotice("Reorder stopped: couldn't remove an entry (\(reason.prefix(90)))")
                self.refreshState()
                return
            }
        }
        for videoId in plan.insertions {
            guard await self.insertAndWait(videoId: videoId, mode: plan.mode, after: currentVideoId) else {
                self.log.log("queue", "reorder aborted while re-inserting \(videoId)")
                self.postNotice("Reorder stopped: couldn't re-insert an entry")
                self.refreshState()
                return
            }
        }
        self.refreshState()
    }

    /// Appends `videoId` to the end of the page's queue (outcome in `lastQueueResult`).
    @discardableResult
    func addToQueue(videoId: String) -> Bool {
        guard self.state.videoId != nil else {
            self.play(videoId: videoId, playlistId: "RDAMVM\(videoId)")
            return true
        }
        self.queueRetries[videoId] = 2
        self.log.log("cmd", "addToQueue \(videoId)")
        self.webView.evaluateJavaScript(PlayerScripts.addToQueue(videoId: videoId), completionHandler: nil)
        return true
    }

    /// Pushes the ad auto-skip preference to the live page.
    func applyAdSkipSetting() {
        let js = "window.__kasetAdAutoSkip = \(AdSkip.isEnabled ? "true" : "false");"
        self.webView.evaluateJavaScript(js, completionHandler: nil)
    }

    /// Applies the stored audio-quality preference to the live page.
    /// The user's quality, or low while the network is weak (see `lowQualityReason`).
    var effectiveAudioQuality: PlaybackAudioQuality {
        self.lowQualityReason != nil && BufferPolicy.adaptsQuality ? .low : .current
    }

    func applyAudioQuality() {
        let script = PlaybackAudioQualityScripts.playbackAudioQualitySyncScript(quality: self.effectiveAudioQuality)
        self.webView.evaluateJavaScript(script, completionHandler: nil)
    }

    func refreshState() {
        Task {
            let js = "JSON.stringify(window.__kaset ? window.__kaset.state() : null)"
            guard let text = try? await self.webView.evaluateJavaScript(js) as? String,
                  let data = text.data(using: .utf8),
                  let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }
            if self.isShowingRestoredSession, !self.carriesTrack(message) { return }
            self.isShowingRestoredSession = false
            self.state = self.state.applying(message)
            self.publishNowPlaying()
        }
    }

    private func command(_ name: String, argument: String? = nil) {
        if name == "play" || name == "toggle", !self.isInCall { self.releasePageInterruption() }
        let call = "\(name)(\(argument ?? ""))"
        let js = "window.__kaset ? String(window.__kaset.\(call)) : 'no-page'"
        Task {
            let result: String
            do {
                result = (try await self.webView.evaluateJavaScript(js) as? String) ?? "nil"
            } catch {
                result = "error: \(error.localizedDescription)"
            }
            self.log.log("cmd", "\(call) → \(result)")
        }
    }

    // MARK: - Page messages

    fileprivate func handle(_ message: [String: Any]) {
        guard let kind = message["kind"] as? String else { return }
        self.lastMessageAt = Date()
        switch kind {
        case "state":
            let now = Date()
            if message["hb"] as? Bool == true {
                if let previous = self.lastBeat, now.timeIntervalSince(previous) > 12 {
                    self.log.log("js", "GAP \(Int(now.timeIntervalSince(previous)))s between heartbeats")
                }
                self.lastBeat = now
            }
            if self.isShowingRestoredSession {
                // Keep the restored track on screen until the page really has a track. The
                // home page already has a (paused, empty) <video>, so `paused` alone proves nothing.
                guard self.carriesTrack(message) else { return }
                self.isShowingRestoredSession = false
            }
            let previousID = self.state.videoId
            let wasPlaying = self.state.isPlaying
            let event = message["ev"] as? String ?? ""
            if event == "error", !self.mediaFailed, self.state.videoId != nil {
                self.mediaFailed = true
                self.positionBeforeError = self.state.position(at: now)
                self.log.log("media", "error: keeping \(Int(self.positionBeforeError))s for the next play")
            } else if event == "playing" {
                self.mediaFailed = false
            }
            self.lastEvent = event
            self.eventSerial += 1
            self.state = self.state.applying(message, at: now)
            self.onStateChange?(self.state, now)
            // Playback started again (lock-screen / widget play, user tap) while no call is
            // active: the page must never stay in its "stand down" mode.
            if self.pageIsInterrupted, !self.isInCall, self.state.isPlaying { self.releasePageInterruption() }
            self.persistSession(at: now)
            if event == "error" || event == "stalled" || event == "emptied" { self.scheduleRecoveryCheck(after: event) }
            if event == "pause" { self.resumeIfPausedByBackgrounding() }
            if event == "waiting" || event == "stalled" { self.noteBufferStarvation(event: event, wasPlaying: wasPlaying, at: now) }
            if message["hb"] as? Bool == true, self.state.isPlaying, now.timeIntervalSince(self.lastBufferLog) >= 30 {
                self.lastBufferLog = now
                let buffered = self.state.bufferedAhead.map { "\(Int($0))s" } ?? "?"
                self.log.log("buffer", "t=\(Int(self.state.position))/\(Int(self.state.duration))s ahead=\(buffered)")
            }
            if message["hb"] as? Bool == true, self.lowQualityReason == "underrun",
               now.timeIntervalSince(self.lastUnderrun) > 10 * 60
            {
                self.setLowQuality(reason: nil)
            }
            if message["ad"] as? Bool == true, event != "hb" || self.state.isAd == false {
                self.log.log("ad", "ad playing (autoSkip=\(AdSkip.isEnabled))")
            }
            if self.state.videoId != previousID {
                self.log.log("track", "\(self.state.title ?? "?") — \(self.state.artist ?? "?") [\(self.state.videoId ?? "-")]")
                self.scheduleHealthCheck()
            }
            if message["hb"] as? Bool != true {
                let buffered = self.state.bufferedAhead.map { "\(Int($0))s" } ?? "?"
                self.log.log("media", "\(message["ev"] as? String ?? "?") playing=\(self.state.isPlaying) "
                    + "\(Int(self.state.position))/\(Int(self.state.duration))s buf=\(buffered) vis=\(self.state.visibility ?? "?")")
            }
            self.publishNowPlaying()
        case "queueResult":
            if let attempt = message["attemptGeneration"] as? Int,
               let continuation = self.pendingQueueResults.removeValue(forKey: attempt)
            {
                // Awaited by an internal sequence (reorder): the caller decides about retries
                // and what the user sees.
                continuation.resume(returning: (
                    message["success"] as? Bool ?? false, message["reason"] as? String ?? ""
                ))
                self.log.log("queue", "\(message["op"] as? String ?? "playNext") \(message["videoId"] as? String ?? "") "
                    + "success=\(message["success"] as? Bool ?? false) \(message["reason"] as? String ?? "") [awaited]")
                return
            }
            let id = message["videoId"] as? String ?? ""
            let success = message["success"] as? Bool ?? false
            let reason = message["reason"] as? String ?? ""
            self.lastQueueResult = (id, success, reason)
            self.log.log("queue", "\(message["op"] as? String ?? "playNext") \(id) success=\(success) \(reason)")
            let isAdd = (message["op"] as? String) == "add"
            // The player-bar menu is populated lazily: the first attempt can find it without the
            // entry yet. Retry once or twice before telling the user.
            if !success, Self.transientQueueFailures.contains(reason),
               self.queueAttempt == (message["attemptGeneration"] as? Int ?? -1) || isAdd,
               let left = self.queueRetries[id], left > 0
            {
                self.queueRetries[id] = left - 1
                self.log.log("queue", "retrying \(id) after \(reason) (\(left - 1) left)")
                Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(600))
                    guard let self else { return }
                    if isAdd {
                        self.webView.evaluateJavaScript(PlayerScripts.addToQueue(videoId: id), completionHandler: nil)
                    } else if let source = self.state.videoId {
                        self.queueAttempt += 1
                        let script = PlayerScripts.playNext(videoId: id, afterVideoId: source, attempt: self.queueAttempt)
                        self.webView.evaluateJavaScript(script, completionHandler: nil)
                    }
                }
                return
            }
            self.queueRetries[id] = nil
            if success {
                self.postNotice(isAdd ? "Added to the queue" : "Playing next")
            } else {
                self.postNotice("Couldn't \(isAdd ? "add to the queue" : "queue next"): \(reason)")
            }
        case "ka":
            self.log.log("keepalive", "AudioContext \(message["state"] as? String ?? "?")")
        case "ms":
            self.log.log("remote", "mediaSession \(message["action"] as? String ?? "?") \(message["msg"] as? String ?? "")")
        case "bg":
            self.log.log("bg", "page undid a pause caused by backgrounding (\(message["via"] as? String ?? "?"))")
        case "ad":
            self.log.log("ad", "skip via \(message["via"] as? String ?? "?")")
        case "dialog":
            self.log.log("js", "dialog \(message["tag"] as? String ?? "?") clicked=\(message["clicked"] as? Bool ?? false) "
                + "button=\(message["button"] as? String ?? "")")
        case "playerr":
            self.log.log("js", "play() rejected: \(message["msg"] as? String ?? "?")")
        case "boot":
            self.log.log("js", "page script booted \(message["path"] as? String ?? "")")
        default:
            break
        }
    }

    // MARK: - Recovery and session restore

    /// What is needed to bring the player back to where it was.
    private struct SavedSession: Codable {
        var videoId: String
        var listId: String?
        var position: TimeInterval
        var title: String?
        var artist: String?
        var artworkURL: URL?
    }

    private static let savedSessionKey = "playback.savedSession"

    private var savedSession: SavedSession? {
        UserDefaults.standard.data(forKey: Self.savedSessionKey)
            .flatMap { try? JSONDecoder().decode(SavedSession.self, from: $0) }
    }

    /// Throttled: at most every 5 s, so a kill loses only a few seconds of position.
    private func persistSession(at date: Date) {
        // After a media error the page reports 0/0: keep the last good position saved.
        guard let videoId = self.state.videoId, self.state.hasMedia, !self.mediaFailed else { return }
        guard date.timeIntervalSince(self.lastSavedAt) >= 5 else { return }
        self.lastSavedAt = date
        let session = SavedSession(
            videoId: videoId, listId: self.state.listId, position: self.state.position,
            title: self.state.title, artist: self.state.artist, artworkURL: self.state.artworkURL
        )
        if let data = try? JSONEncoder().encode(session) {
            UserDefaults.standard.set(data, forKey: Self.savedSessionKey)
        }
    }

    /// Shows the last track in the mini player after a cold start, without playing anything.
    private func restoreSavedSession() {
        guard let saved = self.savedSession else { return }
        var restored = PlaybackState()
        restored.videoId = saved.videoId
        restored.listId = saved.listId
        restored.title = saved.title
        restored.artist = saved.artist
        restored.artworkURL = saved.artworkURL
        restored.position = saved.position
        self.state = restored
        self.isShowingRestoredSession = true
    }

    /// Loads the saved track at its saved position (user pressed play on a restored mini player).
    @discardableResult
    private func resumeSavedSession() -> Bool {
        guard let saved = self.savedSession else { return false }
        self.log.log("restore", "resume \(saved.videoId) list=\(saved.listId ?? "-") at \(Int(saved.position))s")
        self.load(videoId: saved.videoId, listId: saved.listId, at: saved.position)
        return true
    }

    private func load(videoId: String, listId: String?, at position: TimeInterval) {
        var components = URLComponents(string: "https://music.youtube.com/watch")!
        var items = [URLQueryItem(name: "v", value: videoId)]
        if let listId { items.append(URLQueryItem(name: "list", value: listId)) }
        if position > 3 { items.append(URLQueryItem(name: "t", value: "\(Int(position))s")) }
        components.queryItems = items
        if let url = components.url { self.webView.load(URLRequest(url: url)) }
    }

    /// Play after a media error: reload the track where it was. `false` when there was no error.
    private func recoverFailedMedia() -> Bool {
        guard self.mediaFailed, let videoId = self.state.videoId else { return false }
        self.mediaFailed = false
        self.log.log("recover", "play after media error: reload \(videoId) at \(Int(self.positionBeforeError))s")
        self.lastRecovery = Date()
        self.load(videoId: videoId, listId: self.state.listId, at: self.positionBeforeError)
        return true
    }

    /// Brings playback back after a page failure: same track, same list, same position.
    /// Rate limited so a persistent failure cannot loop.
    func recover(reason: String) {
        let now = Date()
        // Reloading without a network fails and throws away what the page had buffered; wait for
        // the network instead (`networkReturned`).
        guard self.isOnline else {
            self.log.log("recover", "\(reason): offline, waiting for the network")
            self.recoveryPendingNetwork = true
            return
        }
        guard now.timeIntervalSince(self.lastRecovery) > 15 else { return }
        guard let videoId = self.state.videoId else {
            self.webView.reload()
            return
        }
        self.lastRecovery = now
        self.log.log("recover", "\(reason): reload \(videoId) at \(Int(self.state.position(at: now)))s")
        self.load(videoId: videoId, listId: self.state.listId, at: self.state.position(at: now))
    }

    /// An `error`/`stalled` event is only a problem if playback has not come back shortly after.
    private func scheduleRecoveryCheck(after event: String) {
        let serial = self.eventSerial
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self else { return }
            // Any newer page event (e.g. the next track starting to load) cancels the check:
            // skipping quickly through tracks emits `emptied` repeatedly and is not a failure.
            guard self.eventSerial == serial, self.lastEvent == event,
                  !self.state.isPlaying, self.state.hasMedia else { return }
            // Paused by the user is not a failure: only recover when it looks stuck.
            if event == "error" || event == "stalled" || event == "emptied" {
                self.recover(reason: "stuck after \(event)")
            }
        }
    }

    /// Whether a page `state` message describes an actual track.
    private func carriesTrack(_ message: [String: Any]) -> Bool {
        if let id = message["videoId"] as? String, !id.isEmpty { return true }
        if let duration = message["duration"] as? Double, duration > 0 { return true }
        return false
    }

    private func startPathMonitor() {
        self.pathMonitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let constrained = path.isConstrained
            let wifi = path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.log.log("network", online
                    ? "online (\(wifi ? "wifi" : "cellular")\(constrained ? ", low data" : ""))"
                    : "offline (buf=\(self.state.bufferedAhead.map { "\(Int($0))s" } ?? "?"))")
                if !online, self.isOnline {
                    self.playingWhenWentOffline = self.state.isPlaying
                    self.wentOfflineAt = Date()
                }
                self.isOnline = online
                if online {
                    if constrained {
                        self.setLowQuality(reason: "low data mode")
                    } else if wifi {
                        self.setLowQuality(reason: nil)
                    }
                }
                if online, self.wasOffline { self.networkReturned() }
                self.wasOffline = !online
            }
        }
        self.pathMonitor.start(queue: DispatchQueue(label: "dev.emoona.kaset.path"))
    }

    /// The page usually picks up again by itself once it can load; give it a moment, then nudge
    /// it with `play`, and only reload (losing the buffer) if that did not work either.
    private func networkReturned() {
        let wasPlaying = self.playingWhenWentOffline && self.lastUserPause < self.wentOfflineAt
        let pending = self.recoveryPendingNetwork
        self.playingWhenWentOffline = false
        self.recoveryPendingNetwork = false
        guard self.state.hasMedia, wasPlaying || pending else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, !self.state.isPlaying, self.lastUserPause < self.wentOfflineAt else { return }
            self.log.log("network", "back, playback still stopped: play")
            self.command("play")
            try? await Task.sleep(for: .seconds(6))
            guard !self.state.isPlaying, self.lastUserPause < self.wentOfflineAt else { return }
            self.recover(reason: "network back")
        }
    }

    /// A `waiting`/`stalled` while playing with nothing left in the buffer (not a seek, not a
    /// track start) means the network cannot keep up: drop to low quality for a while.
    private func noteBufferStarvation(event: String, wasPlaying: Bool, at date: Date) {
        guard wasPlaying, self.state.position > 5, (self.state.bufferedAhead ?? 0) < 1,
              date.timeIntervalSince(self.lastSeekCommand) > 3
        else { return }
        self.log.log("network", "underrun (\(event)) at \(Int(self.state.position))s, online=\(self.isOnline)")
        guard self.isOnline else { return }
        self.lastUnderrun = date
        self.setLowQuality(reason: "underrun")
    }

    private func setLowQuality(reason: String?) {
        guard reason != self.lowQualityReason else { return }
        // A data-saver reason is not replaced by an underrun, only cleared.
        if reason == "underrun", self.lowQualityReason == "low data mode" { return }
        self.lowQualityReason = reason
        guard BufferPolicy.adaptsQuality, PlaybackAudioQuality.current != .low else { return }
        self.log.log("quality", reason.map { "lowered (\($0))" } ?? "back to \(PlaybackAudioQuality.current.rawValue)")
        self.applyAudioQuality()
    }

    /// Turns the longer buffer on or off in the live page; flag overrides apply on the next load.
    func applyBufferSetting() {
        let js = "window.__kasetExtendedBuffer = \(BufferPolicy.isExtended ? "true" : "false");"
        self.webView.evaluateJavaScript(js, completionHandler: nil)
    }

    /// Writes what the page buffers and which read-ahead flags it uses into the log.
    func inspectBuffer() {
        let js = "window.__kasetBuffer ? window.__kasetBuffer.inspect() : 'buffer script not loaded'"
        self.webView.evaluateJavaScript(js) { [weak self] result, error in
            Task { @MainActor in
                let text = (result as? String) ?? error?.localizedDescription ?? "nil"
                for line in text.split(separator: "\n") { self?.log.log("buffer", String(line)) }
            }
        }
    }

    // MARK: - Now Playing / remote commands

    var publishesNowPlaying: Bool {
        UserDefaults.standard.object(forKey: "nativeNowPlaying") as? Bool ?? true
    }

    private func publishNowPlaying() {
        guard self.publishesNowPlaying else {
            self.nowPlaying.clear()
            return
        }
        self.nowPlaying.update(from: self.state)
    }

    /// WebKit exposes ±10 s skips because the page registers no next/previous handlers.
    /// Register real commands that click the page's own buttons.
    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.nextTrackCommand.addTarget { [weak self] _ in self?.remote("next") ?? .commandFailed }
        center.previousTrackCommand.addTarget { [weak self] _ in self?.remote("previous") ?? .commandFailed }
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
    }

    private func remote(_ command: String) -> MPRemoteCommandHandlerStatus {
        // Guard against WebKit also forwarding the same press.
        guard Date().timeIntervalSince(self.lastRemoteCommand) > 0.6 else { return .success }
        self.lastRemoteCommand = Date()
        self.log.log("remote", "lock screen \(command)")
        if command == "play" || command == "toggle", self.recoverFailedMedia() { return .success }
        self.command(command)
        return .success
    }

    // MARK: - Audio session

    /// Category and activation run off the main thread: `setActive` can block for a while and
    /// AVAudioSession warns about calling it on the main thread.
    private func configureAudioSession() {
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = Self.activateAudioSession(configuring: true)
            await self?.log.log("audio", result)
        }
    }

    nonisolated private static func activateAudioSession(configuring: Bool) -> String {
        let session = AVAudioSession.sharedInstance()
        do {
            if configuring {
                try session.setCategory(.playback, mode: .default, options: [])
            }
            try session.setActive(true)
            return "session active"
        } catch {
            return "session setup FAILED: \(error.localizedDescription)"
        }
    }

    private func outputs() -> String {
        AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType.rawValue).joined(separator: ",")
    }

    private func observeAudioSession() {
        Task { [weak self] in
            for await note in NotificationCenter.default.notifications(named: AVAudioSession.interruptionNotification) {
                let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
                self?.interruption(type: type, options: options)
            }
        }
        Task { [weak self] in
            for await note in NotificationCenter.default.notifications(named: AVAudioSession.routeChangeNotification) {
                let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
                self?.log.log("audio", "routeChange reason=\(reason) outputs=\(self?.outputs() ?? "?")")
            }
        }
    }

    private func interruption(type: UInt?, options: UInt?) {
        guard let type, let kind = AVAudioSession.InterruptionType(rawValue: type) else { return }
        switch kind {
        case .began:
            self.log.log("audio", "interruption BEGAN")
        case .ended:
            let resume = AVAudioSession.InterruptionOptions(rawValue: options ?? 0).contains(.shouldResume)
            self.log.log("audio", "interruption ENDED shouldResume=\(resume)")
            // The page's own media playback interrupts this session (BEGAN right after each
            // `playing`), and iOS ends that interruption when the app comes to the foreground,
            // e.g. from the lock screen player. Reactivating then takes the audio back from the
            // page: device logs show a `pause` ~800 ms later, and once the page resumed on its
            // own into a silent output (position frozen, then advancing with no sound).
            if self.state.isPlaying, !resume {
                self.log.log("audio", "page is playing: leaving the session to it")
                return
            }
            Task.detached(priority: .userInitiated) { _ = Self.activateAudioSession(configuring: false) }
            if resume { self.resume() }
        @unknown default:
            break
        }
    }

    // MARK: - Pause caused by backgrounding

    /// When the app was playing as it went to the background and the media pauses within a few
    /// seconds, that pause was not the user's: resume it (and keep trying briefly). Logs from a
    /// device show `didEnterBackground` followed by a `pause` while the page still reports
    /// itself visible, and on some runs nothing resumed it until the app came back.
    private func resumeIfPausedByBackgrounding() {
        guard self.playingWhenBackgrounded, !self.resumedAfterBackgroundPause, !self.isInCall,
              Date().timeIntervalSince(self.backgroundedAt) < 4
        else { return }
        self.resumedAfterBackgroundPause = true
        self.log.log("bg", "paused by backgrounding: resuming")

        var task = UIBackgroundTaskIdentifier.invalid
        task = UIApplication.shared.beginBackgroundTask(withName: "resume-after-background-pause") {
            UIApplication.shared.endBackgroundTask(task)
        }
        Task {
            _ = await Task.detached(priority: .userInitiated) { Self.activateAudioSession(configuring: false) }.value
            for attempt in 1 ... 4 {
                self.releasePageInterruption()
                self.command("play")
                try? await Task.sleep(for: .milliseconds(900))
                if self.state.isPlaying {
                    self.log.log("bg", "resumed (attempt \(attempt))")
                    break
                }
            }
            if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
        }
    }

    // MARK: - Phone calls

    /// Pauses when a call rings or connects and resumes after it ends, if it was playing.
    /// `CXCallObserver` needs no permission or entitlement. Relying only on the audio session
    /// interruption was not enough: the page's keep-alive audio kept the session busy and the
    /// music stayed audible during the call.
    /// Settings → Diagnostics. Needs a relaunch to take effect.
    static var handlesPhoneCalls: Bool {
        UserDefaults.standard.object(forKey: "settings.handlePhoneCalls") as? Bool ?? true
    }

    private func observeCalls() {
        let delegate = CallDelegate { [weak self] in
            Task { @MainActor in self?.callStateChanged() }
        }
        self.callDelegate = delegate
        self.callObserver.setDelegate(delegate, queue: .main)
    }

    private func callStateChanged() {
        let calls = self.callObserver.calls
        let summary = calls.map {
            "connected=\($0.hasConnected) ended=\($0.hasEnded) outgoing=\($0.isOutgoing) hold=\($0.isOnHold)"
        }.joined(separator: " | ")
        self.log.log("call", "changed: \(calls.count) call(s) [\(summary)]")

        let active = calls.contains { !$0.hasEnded }
        guard active != self.isInCall else { return }
        self.isInCall = active
        if active {
            // Nothing to pause when nothing plays: leave the page alone (no stuck flags).
            guard self.state.isPlaying else {
                self.log.log("call", "call started while not playing: ignoring")
                return
            }
            self.pausedForCall = true
            self.pageIsInterrupted = true
            self.log.log("call", "call started while playing: pausing")
            self.webView.evaluateJavaScript("window.__kaset ? window.__kaset.setInterrupted(true) : 'no-page'", completionHandler: nil)
        } else {
            let shouldResume = self.pausedForCall
            self.pausedForCall = false
            self.log.log("call", "call ended (resume=\(shouldResume))")
            Task {
                // Give the system a moment to hand the audio route back before playing.
                try? await Task.sleep(for: .milliseconds(800))
                _ = await Task.detached(priority: .userInitiated) { Self.activateAudioSession(configuring: false) }.value
                self.releasePageInterruption()
                if shouldResume { self.command("play") }
            }
        }
    }

    /// Lets the page's keep-alive and media run again.
    private func releasePageInterruption() {
        guard self.pageIsInterrupted else { return }
        self.pageIsInterrupted = false
        self.webView.evaluateJavaScript("window.__kaset ? window.__kaset.setInterrupted(false) : 'no-page'", completionHandler: nil)
    }

    // MARK: - Lifecycle

    private func observeLifecycle() {
        let names: [(Notification.Name, String)] = [
            (UIApplication.willResignActiveNotification, "willResignActive"),
            (UIApplication.didEnterBackgroundNotification, "didEnterBackground"),
            (UIApplication.willEnterForegroundNotification, "willEnterForeground"),
            (UIApplication.protectedDataWillBecomeUnavailableNotification, "deviceLocking"),
            (UIApplication.didReceiveMemoryWarningNotification, "memoryWarning"),
        ]
        for (name, label) in names {
            Task { [weak self] in
                for await _ in NotificationCenter.default.notifications(named: name) {
                    self?.log.log("app", label)
                    if label == "willResignActive", let self, self.state.isPlaying, !self.isInCall {
                        // Arm the page's guard before iOS gets the chance to pause the media.
                        self.webView.evaluateJavaScript(
                            "window.__kaset ? window.__kaset.setBackgroundGuard(6000) : 'no-page'",
                            completionHandler: nil
                        )
                    }
                    if label == "didEnterBackground", let self {
                        self.playingWhenBackgrounded = self.state.isPlaying && !self.isInCall
                        self.backgroundedAt = Date()
                        self.resumedAfterBackgroundPause = false
                    }
                    if label == "willEnterForeground" {
                        self?.playingWhenBackgrounded = false
                        self?.refreshState()
                        self?.callStateChanged()
                    }
                }
            }
        }
    }
}

extension WebPlayer: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
        self.pageURL = webView.url?.absoluteString
        self.hasLoadedPage = webView.url?.host?.hasSuffix("music.youtube.com") == true
        // A fresh document starts from the user's quality; keep it low while the network is weak.
        if self.lowQualityReason != nil { self.applyAudioQuality() }
        self.log.log("nav", "didFinish \(webView.url?.absoluteString.prefix(80) ?? "")")
    }

    func webView(_: WKWebView, didFail _: WKNavigation!, withError error: Error) {
        self.log.log("nav", "didFail \(error.localizedDescription)")
    }

    func webView(_: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error) {
        self.log.log("nav", "didFailProvisional \(error.localizedDescription)")
    }

    /// iOS killed the page's process: reload the same track, list and position.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        self.log.log("nav", "WEBCONTENT PROCESS TERMINATED")
        self.lastRecovery = .distantPast
        self.recover(reason: "web content terminated")
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith _: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures _: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }
}

/// `CXCallObserverDelegate` is an Objective-C protocol, so it needs an NSObject.
private final class CallDelegate: NSObject, CXCallObserverDelegate {
    private let onChange: @Sendable () -> Void

    init(onChange: @escaping @Sendable () -> Void) { self.onChange = onChange }

    func callObserver(_: CXCallObserver, callChanged _: CXCall) { self.onChange() }
}
