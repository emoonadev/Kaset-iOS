import JavaScriptCore
import Testing

@testable import KasetiOS

/// The page scripts are Swift string literals holding JavaScript: an escape such as `\n`
/// becomes a real newline inside a JS string and silently breaks the whole script on a device.
/// These tests run the scripts through JavaScriptCore (the same engine as the web view).
struct PageScriptTests {
    /// A tiny stand-in for the browser objects the page script touches at load time.
    private static let prelude = """
    var __posts = [];
    function setInterval() { return 0; }
    function setTimeout() { return 0; }
    function clearInterval() {}
    function clearTimeout() {}
    var document = {
      querySelector: function () { return null; },
      querySelectorAll: function () { return []; },
      getElementById: function () { return null; },
      addEventListener: function () {},
      body: { click: function () {} },
      hasFocus: function () { return true; }
    };
    function Document() {}
    Object.defineProperty(Document.prototype, 'visibilityState', { get: function () { return 'visible'; }, configurable: true });
    var HTMLElement = function () {};
    var MutationObserver = function () { this.observe = function () {}; this.disconnect = function () {}; };
    var navigator = { mediaSession: { setActionHandler: function () {}, metadata: null } };
    var location = { pathname: '/', search: '' };
    var window = {
      webkit: { messageHandlers: { kaset: { postMessage: function (o) { __posts.push(o); } } } },
      addEventListener: function () {},
      location: location,
      navigator: navigator
    };
    """

    private func makeContext() -> JSContext {
        let context = JSContext()!
        context.exceptionHandler = { context, exception in context?.exception = exception }
        context.evaluateScript(Self.prelude)
        return context
    }

    @Test func pageScriptBootsAndExposesTheCommandAPI() {
        let context = self.makeContext()
        context.evaluateScript(PlayerScripts.page)

        #expect(context.exception == nil, "page script threw: \(context.exception?.toString() ?? "")")
        #expect(context.evaluateScript("typeof window.__kaset").toString() == "object")
        #expect(context.evaluateScript("__posts.length > 0 && __posts[0].kind").toString() == "boot")
        for command in ["play", "pause", "toggle", "next", "previous", "seek", "state",
                        "playQueueIndex", "removeQueueIndexAsync", "inspectQueue", "health", "shuffle", "repeat", "setInterrupted", "setBackgroundGuard"]
        {
            #expect(
                context.evaluateScript("typeof window.__kaset.\(command)").toString() == "function",
                "missing command \(command)"
            )
        }
    }

    @Test func commandsDegradeGracefullyWithoutADOM() {
        let context = self.makeContext()
        context.evaluateScript(PlayerScripts.page)
        #expect(context.evaluateScript("window.__kaset.toggle()").toString() == "missing:playPause")
        #expect(context.evaluateScript("window.__kaset.seek(10)").toString() == "no-media")
        #expect(context.evaluateScript("typeof window.__kaset.inspectQueue()").toString() == "string")
        #expect(context.exception == nil)
    }

    @Test func healthProbeReportsMissingPartsWithoutADOM() throws {
        let context = self.makeContext()
        context.evaluateScript(PlayerScripts.page)
        let json = try #require(context.evaluateScript("JSON.stringify(window.__kaset.health())").toString())
        #expect(context.exception == nil, "health() threw: \(context.exception?.toString() ?? "")")

        let report = try #require(PlayerHealthReport.parse(json))
        #expect(report.hasTrack == false)
        #expect(report.checks.first?.id == "page")
        #expect(report.checks.first?.status == .ok)
        let byId = Dictionary(uniqueKeysWithValues: report.checks.map { ($0.id, $0) })
        #expect(byId["media"]?.status == .failing)
        #expect(byId["next"]?.status == .failing)
        // Track-only checks wait for a track instead of failing.
        #expect(byId["queue"]?.status == .needsTrack)
        #expect(byId["menu"]?.status == .needsTrack)
        #expect(report.failing.allSatisfy { !$0.needsTrack })
    }

    /// The player switches video before the web app updates the Media Session: the state must
    /// never pair the new video with the previous track's title or artwork.
    @Test func stateNeverPairsANewVideoWithThePreviousTracksMetadata() throws {
        let context = self.makeContext()
        context.evaluateScript("""
        function URLSearchParams() { this.get = function () { return null; }; }
        var __video = { video_id: 'A', title: 'Song A', author: 'Artist A - Topic' };
        var __player = { getVideoData: function () { return __video; } };
        document.getElementById = function (id) { return id === 'movie_player' ? __player : null; };
        navigator.mediaSession.metadata = {
          title: 'Song A', artist: 'Artist A', album: 'Album A', artwork: [{ src: 'https://example.com/a.jpg' }]
        };
        """)
        context.evaluateScript(PlayerScripts.page)
        func state() throws -> PlaybackState {
            let json = try #require(context.evaluateScript("JSON.stringify(window.__kaset.state())").toString())
            let message = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            return PlaybackState().applying(message)
        }

        let first = try state()
        #expect(first.videoId == "A" && first.title == "Song A" && first.album == "Album A")
        #expect(first.isMetadataCurrent)

        // Next song: the player has B, the Media Session still describes A.
        context.evaluateScript("__video = { video_id: 'B', title: 'Song B', author: 'Artist B - Topic' };")
        let switching = try state()
        #expect(switching.videoId == "B")
        #expect(!switching.isMetadataCurrent)
        #expect(switching.title == "Song B" && switching.artist == "Artist B")
        #expect(switching.album == nil && switching.artworkURL == nil)

        // The web app sets B's metadata.
        context.evaluateScript("""
        navigator.mediaSession.metadata = {
          title: 'Song B', artist: 'Artist B', album: 'Album B', artwork: [{ src: 'https://example.com/b.jpg' }]
        };
        """)
        let settled = try state()
        #expect(settled.isMetadataCurrent && settled.title == "Song B" && settled.album == "Album B")
        #expect(settled.artworkURL?.absoluteString == "https://example.com/b.jpg")

        // Titles that differ between the player and the Media Session: replacing the metadata
        // after the video changed is enough.
        context.evaluateScript("__video = { video_id: 'C', title: 'Song C (Official Audio)', author: 'Artist C' };")
        #expect(try !state().isMetadataCurrent)
        context.evaluateScript("navigator.mediaSession.metadata = { title: 'Song C', artist: 'Artist C', album: '', artwork: [] };")
        let renamed = try state()
        #expect(renamed.isMetadataCurrent && renamed.title == "Song C")
        #expect(context.exception == nil, "page script threw: \(context.exception?.toString() ?? "")")
    }

    @Test func injectedScriptsAreSyntacticallyValid() {
        let scripts: [(String, String)] = [
            ("playNext", PlayerScripts.playNext(videoId: "abc", afterVideoId: "def", attempt: 1)),
            ("addToQueue", PlayerScripts.addToQueue(videoId: "abc", attempt: 2)),
            ("watchEndpoint", PlayerScripts.watchEndpointScript(videoId: "abc", playlistId: "RDAMVMabc")),
            ("audioQualityOverride", PlaybackAudioQualityScripts.playbackAudioQualityOverrideScript),
            ("bufferBootstrap", BufferScripts.bootstrap(extended: true)),
            ("audioQualityBootstrap", PlaybackAudioQualityScripts.playbackAudioQualityBootstrapScript(quality: .high)),
        ]
        for (name, source) in scripts {
            let context = JSContext()!
            context.exceptionHandler = { context, exception in context?.exception = exception }
            // `new Function` parses without running it.
            context.evaluateScript("new Function(\(PlayerScripts.literal(source)))")
            #expect(context.exception == nil, "\(name) is not valid JavaScript: \(context.exception?.toString() ?? "")")
        }
    }
}
