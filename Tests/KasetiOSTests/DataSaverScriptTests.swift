import JavaScriptCore
import Testing

@testable import KasetiOS

/// Runs `DataSaver.script` against a fake page: the Song/Video toggle, the player element and
/// the `movie_player` API, with the attributes music.youtube.com uses.
struct DataSaverScriptTests {
    private static let prelude = """
    var __posts = [];
    var __clicks = 0;
    var __range = null;
    function post(o) { __posts.push(o); }
    function setInterval() { return 0; }
    function el(attrs) {
      return {
        attrs: attrs,
        getAttribute: function (n) { return n in this.attrs ? this.attrs[n] : null; },
        hasAttribute: function (n) { return n in this.attrs; },
        querySelector: function () { return { click: function () { __clicks += 1; } }; }
      };
    }
    var player = el({ 'playback-mode': 'OMV_PREFERRED' });
    var toggle = el({ 'selected-queue-item-has-counterpart': '' });
    var video = { videoHeight: 360 };
    var api = {
      quality: 'medium',
      getPlaybackQuality: function () { return this.quality; },
      setPlaybackQualityRange: function (a) { __range = a; this.quality = a; }
    };
    function media() { return video; }
    var window = {};
    var document = {
      querySelector: function (s) { return s === 'ytmusic-player' ? player : (s === 'ytmusic-av-toggle' ? toggle : null); },
      getElementById: function (id) { return id === 'movie_player' ? api : null; },
      addEventListener: function () {}
    };
    """

    private func context(enabled: Bool = true) -> JSContext {
        let context = JSContext()!
        context.exceptionHandler = { context, exception in context?.exception = exception }
        context.evaluateScript(Self.prelude)
        context.evaluateScript(DataSaver.script)
        context.evaluateScript("window.__kasetDataSaver = \(enabled);")
        return context
    }

    private func value(_ js: String, in context: JSContext) -> String {
        context.evaluateScript(js).toString()
    }

    @Test func switchesAMusicVideoToItsSongVersionAndCapsTheVideo() {
        let context = self.context()
        context.evaluateScript("window.__kasetApplyDataSaver();")

        #expect(context.exception == nil, "script threw: \(context.exception?.toString() ?? "")")
        #expect(self.value("__clicks", in: context) == "1")
        #expect(self.value("__range", in: context) == "tiny")
        #expect(self.value("__posts.map(function (p) { return p.action; }).join(',')", in: context)
            == "song-version,video-144p")
    }

    @Test func leavesTheToggleAloneWhenItIsDisabledOrHasNoSongVersion() {
        let context = self.context()
        context.evaluateScript("toggle.attrs['toggle-disabled'] = ''; window.__kasetApplyDataSaver();")
        #expect(self.value("__clicks", in: context) == "0")

        context.evaluateScript("delete toggle.attrs['toggle-disabled']; delete toggle.attrs['selected-queue-item-has-counterpart']; window.__kasetApplyDataSaver();")
        #expect(self.value("__clicks", in: context) == "0")
    }

    @Test func doesNothingInSongModeOrWithoutAVideoTrack() {
        let context = self.context()
        context.evaluateScript("player.attrs['playback-mode'] = 'ATV_PREFERRED'; video.videoHeight = 0; window.__kasetApplyDataSaver();")

        #expect(self.value("__clicks", in: context) == "0")
        #expect(self.value("__range", in: context) == "null")
        #expect(self.value("__posts.length", in: context) == "0")
    }

    @Test func turningItOffRestoresAutomaticVideoQuality() {
        let context = self.context(enabled: false)
        context.evaluateScript("window.__kasetApplyDataSaver();")
        #expect(self.value("__clicks", in: context) == "0")
        #expect(self.value("__range", in: context) == "null")

        context.evaluateScript("window.__kasetSetDataSaver(true); window.__kasetSetDataSaver(false);")
        #expect(self.value("__range", in: context) == "auto")
    }
}
