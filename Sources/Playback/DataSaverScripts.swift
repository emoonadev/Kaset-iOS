import Foundation

/// "Save data on music videos" preference. On by default: the app never shows the video,
/// so downloading it only costs data.
enum DataSaver {
    static let storageKey = "settings.dataSaver"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: self.storageKey) as? Bool ?? true
    }

    /// Embedded in `PlayerScripts.page` (needs its `post` and `media` helpers).
    ///
    /// Measured on music.youtube.com (2026-11-10): a music video at the default 360p downloads
    /// more video than audio (3.2 MB of video next to 2.1 MB of audio in its first minute).
    /// 1) The page's own Song/Video toggle (Premium accounts) swaps a music video for its song
    ///    version at the same position, and then streams audio only. The choice lasts until the
    ///    document reloads, so it is re-applied whenever the page is back in video mode.
    /// 2) Any video still playing (no song version, or the toggle is disabled) is capped at
    ///    144p. The cap is stored by the player (`yt-player-quality`), so later tracks start at
    ///    144p; only the track playing when it is first set re-picks its audio format once.
    static var script: String {
        """
        window.__kasetDataSaver = \(self.isEnabled ? "true" : "false");
        (function () {
          let lastSongSwitch = 0;
          const applyDataSaver = () => {
            if (!window.__kasetDataSaver) { return; }
            try {
              const player = document.querySelector('ytmusic-player');
              const toggle = document.querySelector('ytmusic-av-toggle');
              const now = Date.now();
              if (player && toggle
                  && player.getAttribute('playback-mode') === 'OMV_PREFERRED'
                  && !toggle.hasAttribute('toggle-disabled')
                  && toggle.hasAttribute('selected-queue-item-has-counterpart')
                  && now - lastSongSwitch > 5000) {
                const song = toggle.querySelector('.song-button');
                if (song) {
                  lastSongSwitch = now;
                  song.click();
                  post({ kind: 'datasaver', action: 'song-version' });
                }
              }
            } catch (e) {}
            try {
              const api = document.getElementById('movie_player');
              const m = media();
              if (api && m && m.videoHeight > 144
                  && typeof api.setPlaybackQualityRange === 'function'
                  && typeof api.getPlaybackQuality === 'function'
                  && api.getPlaybackQuality() !== 'tiny') {
                api.setPlaybackQualityRange('tiny', 'tiny');
                post({ kind: 'datasaver', action: 'video-144p', from: m.videoHeight });
              }
            } catch (e) {}
          };
          window.__kasetApplyDataSaver = applyDataSaver;
          window.__kasetSetDataSaver = (on) => {
            window.__kasetDataSaver = !!on;
            if (on) { applyDataSaver(); return; }
            try {
              const api = document.getElementById('movie_player');
              if (api && typeof api.setPlaybackQualityRange === 'function') { api.setPlaybackQualityRange('auto', 'auto'); }
            } catch (e) {}
          };
          document.addEventListener('loadedmetadata', applyDataSaver, true);
          document.addEventListener('playing', applyDataSaver, true);
          setInterval(applyDataSaver, 2000);
        })();
        """
    }
}
