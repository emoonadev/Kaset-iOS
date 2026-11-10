import Foundation

/// JavaScript for the playback page (`music.youtube.com`, full desktop player, hidden 1×1).
///
/// Evolved from the spike's `PageScript` (see `docs/spike-findings.md`): same Media Session
/// ownership and keep-alive, plus a structured `state` message the native side mirrors.
/// Player-bar selectors come from kaset `SingletonPlayerWebView+ObserverScript.swift`.
enum PlayerScripts {
    static let bridgeName = "kaset"

    static func literal(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let json = String(data: data, encoding: .utf8)
        else { return "\"\"" }
        return String(json.dropFirst().dropLast())
    }

    /// Locates the slotted player bar and its parts (kaset `playerBarLookupFunctionJS`).
    static let playerBarLookup = """
    const __kasetPlayerBarSelectors = {
        title: '.ytmusic-player-bar.title, .ytmusicTrackInfoTitle',
        byline: '.ytmusic-player-bar.byline, .ytmusicTrackInfoByline',
        thumbnail: '.ytmusic-player-bar .thumbnail img, ytmusic-player-bar .image, img.ytmusicTrackInfoThumbnail',
        playPause: '.play-pause-button.ytmusic-player-bar, .ytmusicPlayerControlsPlayPauseButton button',
        next: '.next-button.ytmusic-player-bar, .ytmusicPlayerControlsNextButton button',
        previous: '.previous-button.ytmusic-player-bar, .ytmusicPlayerControlsPreviousButton button',
        menu: '.middle-controls-buttons.ytmusic-player-bar ytmusic-menu-renderer button, '
            + '.ytMusicMiniPlayerMenuButton button',
        likeRenderer: 'ytmusic-like-button-renderer',
        likeButton: 'like-button-view-model button',
        dislikeButton: 'dislike-button-view-model button'
    };
    function __kasetPlayerBar() {
        return document.querySelector('[slot="player-bar"]') || document.querySelector('ytmusic-player-bar');
    }
    function __kasetPlayerBarElement(name, playerBar = __kasetPlayerBar()) {
        return playerBar ? playerBar.querySelector(__kasetPlayerBarSelectors[name]) : null;
    }
    """

    /// Starts a track inside the loaded web app, without a page load: through the router
    /// (`ytmusic-app.resolveCommand`, as kaset does) or, where that method is gone, by firing the
    /// app's own `yt-navigate` event. Returns the mechanism used, or `false` when neither exists;
    /// the caller checks that the track really changed.
    static func watchEndpointScript(videoId: String, playlistId: String?) -> String {
        let list = playlistId.map { ", playlistId: \(self.literal($0))" } ?? ""
        return """
        (function () {
          const app = document.querySelector('ytmusic-app');
          if (!app) { return false; }
          const endpoint = { watchEndpoint: { videoId: \(self.literal(videoId))\(list) } };
          try {
            if (typeof app.resolveCommand === 'function') { app.resolveCommand(endpoint); return 'resolveCommand'; }
          } catch (e) {}
          try {
            app.dispatchEvent(new CustomEvent('yt-navigate', { bubbles: true, composed: true, detail: { endpoint: endpoint } }));
            return 'yt-navigate';
          } catch (e) { return false; }
        })();
        """
    }

    /// Names on `ytmusic-app` that look like a navigation entry point; logged when the router
    /// is missing so a replacement can be found.
    static let routerCandidatesScript = """
    (function () {
      const app = document.querySelector('ytmusic-app');
      if (!app) { return 'no ytmusic-app'; }
      const names = new Set();
      let p = app;
      for (let d = 0; p && d < 6 && p !== HTMLElement.prototype; d += 1) {
        Object.getOwnPropertyNames(p).forEach((n) => names.add(n));
        p = Object.getPrototypeOf(p);
      }
      return Array.from(names).filter((n) => /command|navigat|resolve|endpoint|route/i.test(n)).slice(0, 40).join(',');
    })();
    """

    /// Injected at document start into every document of the playback web view.
    static var page: String {
        """
        (function () {
          if (window.__kaset) { return; }
          \(self.playerBarLookup)

          const post = (o) => {
            try { o.t = Date.now(); window.webkit.messageHandlers.\(self.bridgeName).postMessage(o); } catch (e) {}
          };
          const visDesc = Object.getOwnPropertyDescriptor(Document.prototype, 'visibilityState');
          const realVis = () => { try { return visDesc.get.call(document); } catch (e) { return 'unknown'; } };
          const media = () => document.querySelector('video') || document.querySelector('audio');
          // The slotted-bar lookup (kaset) is tried first; the spike's plain selectors and the
          // player API are fallbacks so controls keep working if the DOM shape differs.
          const legacy = {
            playPause: '.play-pause-button.ytmusic-player-bar',
            next: '.next-button.ytmusic-player-bar',
            previous: '.previous-button.ytmusic-player-bar'
          };
          const control = (name) => {
            let b = null;
            try { b = __kasetPlayerBarElement(name); } catch (e) {}
            if (!b && legacy[name]) { b = document.querySelector(legacy[name]); }
            return b;
          };
          const playerApi = () => {
            const p = document.querySelector('ytmusic-player');
            if (p && p.playerApi) { return p.playerApi; }
            return document.getElementById('movie_player');
          };
          // When the user (or a command from the app) caused a pause, the guard below must not undo it.
          const markUserAction = () => { window.__kasetUserActionAt = Date.now(); };
          const click = (name) => {
            if (name === 'playPause') { markUserAction(); }
            const b = control(name);
            if (b) { b.click(); return 'clicked'; }
            const m = media();
            const api = playerApi();
            try {
              if (name === 'playPause' && m) { if (m.paused) { m.play(); } else { m.pause(); } return 'media-toggle'; }
              if (name === 'next' && api && api.nextVideo) { api.nextVideo(); return 'api-next'; }
              if (name === 'previous' && api && api.previousVideo) { api.previousVideo(); return 'api-previous'; }
            } catch (e) { return 'error:' + String(e); }
            return 'missing:' + name;
          };
          const enabled = (name) => {
            const b = control(name);
            if (!b) { return true; }
            return !b.disabled && b.getAttribute('aria-disabled') !== 'true';
          };

          const videoId = () => {
            try {
              const p = document.querySelector('ytmusic-player');
              if (p && p.playerApi && typeof p.playerApi.getVideoData === 'function') {
                const d = p.playerApi.getVideoData();
                const id = d && (d.video_id || d.videoId);
                if (id) { return id; }
              }
            } catch (e) {}
            try {
              const m = document.getElementById('movie_player');
              if (m && typeof m.getVideoData === 'function') {
                const d = m.getVideoData();
                const id = d && (d.video_id || d.videoId);
                if (id) { return id; }
              }
            } catch (e) {}
            return new URLSearchParams(location.search).get('v');
          };

          const metadata = () => {
            const m = navigator.mediaSession && navigator.mediaSession.metadata;
            if (!m) { return { title: null, artist: null, album: null, artwork: null }; }
            const art = m.artwork || [];
            return {
              title: m.title || null,
              artist: m.artist || null,
              album: m.album || null,
              artwork: art.length ? art[art.length - 1].src : null
            };
          };

          const text = (el, sel) => {
            const n = el.querySelector(sel);
            return n ? n.textContent.trim() : '';
          };
          // Same reading as kaset's queue injection: the video id sits at a varying depth.
          const firstVideoId = (root) => {
            const seen = new Set();
            const visit = (value, depth) => {
              if (!value || typeof value !== 'object' || depth > 7 || seen.has(value)) { return ''; }
              seen.add(value);
              for (const [key, child] of Object.entries(value)) {
                if ((key === 'videoId' || key === 'video_id') && typeof child === 'string' && child) { return child; }
              }
              for (const child of Object.values(value)) {
                const found = visit(child, depth + 1);
                if (found) { return found; }
              }
              return '';
            };
            return visit(root, 0);
          };
          const QUEUE_ITEMS = 'ytmusic-player-queue-item, ytmusic-player-queue-item-renderer, '
            + 'ytmusic-player-queue ytmusic-responsive-list-item-renderer';
          const queueItemIsCurrent = (el) => {
            if (el.__kasetIsCurrent === true) { return true; }
            if (el.hasAttribute('selected') || el.hasAttribute('is-playlist-panel-video-renderer-selected')) { return true; }
            const aria = el.getAttribute('aria-current');
            if (aria === 'true' || aria === 'page') { return true; }
            return el.classList.contains('selected');
          };
          const queue = () => {
            const items = Array.from(document.querySelectorAll(QUEUE_ITEMS));
            return items.slice(0, 200).map((el) => ({
              videoId: firstVideoId(el.data || el.__data || null),
              title: text(el, '.song-title') || text(el, 'yt-formatted-string.title'),
              artist: text(el, '.byline') || text(el, 'yt-formatted-string.byline'),
              current: queueItemIsCurrent(el)
            }));
          };

          // Shuffle / repeat live on the player bar. Selectors and attributes are best effort.
          const barEl = () => document.querySelector('ytmusic-player-bar');
          const shuffleButton = () => { const b = barEl(); return b ? b.querySelector('.shuffle') : null; };
          const repeatButton = () => { const b = barEl(); return b ? b.querySelector('.repeat') : null; };
          const shuffleOn = () => {
            const b = shuffleButton();
            if (!b) { return null; }
            return b.getAttribute('aria-pressed') === 'true' || b.hasAttribute('active') || b.classList.contains('active');
          };
          const repeatMode = () => {
            const b = barEl();
            const raw = b ? (b.getAttribute('repeat-mode_') || b.getAttribute('repeat-mode') || '') : '';
            const v = raw.toUpperCase();
            return v === 'ALL' ? 'all' : (v === 'ONE' ? 'one' : 'off');
          };

          \(AdDetectionScript.detection)
          window.__kasetAdAutoSkip = \(AdSkip.isEnabled ? "true" : "false");
          const adNow = () => { try { return !!isAdShowing(); } catch (e) { return false; } };

          \(DataSaver.script)

          // Seconds of the current track already loaded past the playhead (BufferScripts).
          const bufferAhead = () => {
            try { return window.__kasetBuffer ? window.__kasetBuffer.ahead() : null; } catch (e) { return null; }
          };

          let lastQueueKey = '';
          const state = (ev, withQueue) => {
            const m = media();
            const meta = metadata();
            const out = {
              kind: 'state', ev: ev,
              paused: m ? m.paused : null,
              ended: m ? m.ended : null,
              currentTime: m ? Math.round(m.currentTime * 10) / 10 : null,
              duration: (m && isFinite(m.duration)) ? Math.round(m.duration * 10) / 10 : null,
              videoId: videoId(),
              listId: new URLSearchParams(location.search).get('list'),
              title: meta.title, artist: meta.artist, album: meta.album, artwork: meta.artwork,
              canNext: enabled('next'), canPrevious: enabled('previous'),
              shuffle: shuffleOn(), repeat: repeatMode(), ad: adNow(),
              buf: bufferAhead(),
              vis: realVis()
            };
            if (withQueue) {
              const q = queue();
              const key = JSON.stringify(q.map((e) => e.videoId + (e.current ? '*' : '')));
              if (key !== lastQueueKey) { lastQueueKey = key; out.queue = q; }
            }
            return out;
          };

          ['play', 'playing', 'pause', 'ended', 'waiting', 'stalled', 'error', 'emptied', 'loadedmetadata', 'seeked'].forEach((ev) => {
            document.addEventListener(ev, (e) => {
              const t = e.target;
              if (t && t.tagName && /^(VIDEO|AUDIO)$/.test(t.tagName)) {
                post(state(ev, ev === 'playing' || ev === 'loadedmetadata' || ev === 'emptied'));
              }
            }, true);
          });
          // Backgrounding can make WebKit pause the media a few milliseconds after the app resigns
          // active. The app arms this guard just before that; the pause is undone inside the same
          // JS turn, so the gap is a few milliseconds instead of a round trip through Swift.
          document.addEventListener('pause', (e) => {
            const until = window.__kasetBackgroundGuardUntil || 0;
            if (Date.now() > until || window.__kasetInterrupted) { return; }
            const t = e.target;
            if (!t || !t.tagName || !/^(VIDEO|AUDIO)$/.test(t.tagName) || t.ended) { return; }
            if (Date.now() - (window.__kasetUserActionAt || 0) < 2000) { return; }
            const p = t.play();
            if (p && p.catch) { p.catch(() => {}); }
            post({ kind: 'bg', via: 'js-resume' });
          }, true);
          window.addEventListener('visibilitychange', () => {
            post(state('visibilitychange', false));
            keepAlive();
          }, true);

          // Position/heartbeat: 2 s while playing, 5 s otherwise. Gaps in these are how
          // throttling or suspension shows up natively.
          let lastBeat = 0;
          setInterval(() => {
            const m = media();
            const playing = !!m && !m.paused;
            const now = Date.now();
            if (now - lastBeat < (playing ? 1900 : 4900)) { return; }
            lastBeat = now;
            post(Object.assign(state('hb', true), { kind: 'state', hb: true }));
          }, 1000);

          // Optional ad skipping: when an ad is playing and the setting is on, press next (the
          // page then moves past the ad). A fallback seeks the ad to its end. Rate limited so a
          // wrong detection can never skip more than one item every few seconds.
          let lastAdSkip = 0;
          const skipAdIfNeeded = () => {
            if (!window.__kasetAdAutoSkip || !adNow()) { return; }
            const now = Date.now();
            if (now - lastAdSkip < 4000) { return; }
            lastAdSkip = now;
            const skipButton = document.querySelector('.ytp-ad-skip-button, .ytp-ad-skip-button-modern, .ytp-skip-ad-button');
            if (skipButton) { skipButton.click(); post({ kind: 'ad', via: 'skip-button' }); return; }
            const result = click('next');
            if (result === 'clicked') { post({ kind: 'ad', via: 'next' }); return; }
            const m = media();
            if (m && isFinite(m.duration) && m.duration > 0) {
              m.currentTime = m.duration;
              post({ kind: 'ad', via: 'seek-end' });
            }
          };
          setInterval(skipAdIfNeeded, 500);
          document.addEventListener('playing', skipAdIfNeeded, true);

          // "Are you still listening?" (ytmusic-you-there-renderer) after a long session without
          // touching the page. While it is open YouTube pauses every new track right after it
          // starts. 1) keep the page's last-activity stamp fresh so it does not come up,
          // 2) press its button if it does, 3) resume a track it paused.
          setInterval(() => { try { window._lact = Date.now(); } catch (e) {} }, 30000);
          const STILL_THERE = 'ytmusic-you-there-renderer, yt-confirm-dialog-renderer';
          let dialogPausedAt = 0;
          document.addEventListener('pause', (e) => {
            const t = e.target;
            if (!t || !t.tagName || !/^(VIDEO|AUDIO)$/.test(t.tagName) || t.ended) { return; }
            if (Date.now() - (window.__kasetUserActionAt || 0) < 2000) { return; }
            const dlg = document.querySelector(STILL_THERE);
            if (dlg && dlg.offsetParent !== null) { dialogPausedAt = Date.now(); }
          }, true);
          let lastDialogReport = '';
          const dismissStillThere = () => {
            const dlg = document.querySelector(STILL_THERE);
            // Only a dialog on screen: templates of closed dialogs stay in the page.
            if (!dlg || dlg.offsetParent === null) { return; }
            const b = dlg.querySelector('#confirm-button button, #confirm-button, yt-button-renderer button, '
              + 'button-view-model button, tp-yt-paper-button, button, [role="button"]');
            const label = b ? ((b.getAttribute('aria-label') || b.textContent || b.tagName).trim().slice(0, 30)) : '';
            const report = dlg.tagName + '|' + label;
            if (report !== lastDialogReport) {
              lastDialogReport = report;
              post({ kind: 'dialog', tag: dlg.tagName.toLowerCase(), clicked: !!b, button: label });
            }
            if (b) { b.click(); }
            try { window._lact = Date.now(); } catch (e) {}
            setTimeout(() => {
              const m = media();
              if (m && m.paused && !m.ended && Date.now() - dialogPausedAt < 15000) {
                dialogPausedAt = 0;
                const p = m.play();
                if (p && p.catch) { p.catch(() => {}); }
                post({ kind: 'dialog', tag: 'resumed', clicked: true, button: '' });
              }
            }, 600);
          };
          setInterval(dismissStillThere, 2000);
          document.addEventListener('playing', () => setTimeout(dismissStillThere, 300), true);

          // Lock screen: own next/previous, neutralise ±10 s seek handlers.
          (function () {
            const ms = navigator.mediaSession;
            if (!ms || !ms.setActionHandler) { return; }
            const orig = ms.setActionHandler.bind(ms);
            const ours = {
              nexttrack: () => { post({ kind: 'ms', action: 'nexttrack' }); click('next'); },
              previoustrack: () => { post({ kind: 'ms', action: 'previoustrack' }); click('previous'); }
            };
            const apply = () => {
              try {
                orig('nexttrack', ours.nexttrack);
                orig('previoustrack', ours.previoustrack);
                orig('seekforward', null);
                orig('seekbackward', null);
              } catch (e) { post({ kind: 'ms', action: 'apply-failed', msg: String(e) }); }
            };
            ms.setActionHandler = (name, handler) => {
              if (name === 'nexttrack' || name === 'previoustrack') { return; }
              if (name === 'seekforward' || name === 'seekbackward') { return orig(name, null); }
              return orig(name, handler);
            };
            apply();
            document.addEventListener('playing', apply, true);
            setInterval(apply, 5000);
          })();

          // Keep the page alive while paused: an inaudible AudioContext that is never torn
          // down and is resumed whenever it is interrupted/suspended (spike findings §2).
          let ctx = null;
          function keepAlive() {
            // While a phone call (or other takeover) owns the audio, stay out of the way.
            if (window.__kasetInterrupted) { return; }
            try {
              if (!ctx) {
                const AC = window.AudioContext || window.webkitAudioContext;
                if (!AC) { return; }
                ctx = new AC();
                const gain = ctx.createGain();
                gain.gain.value = 0.00001;
                const osc = ctx.createOscillator();
                osc.frequency.value = 20;
                osc.connect(gain);
                gain.connect(ctx.destination);
                osc.start();
                ctx.onstatechange = () => {
                  post({ kind: 'ka', state: ctx.state });
                  if (window.__kasetInterrupted) { return; }
                  if (ctx.state === 'interrupted' || ctx.state === 'suspended') { ctx.resume().catch(() => {}); }
                };
              }
              if (ctx.state !== 'running') { ctx.resume().catch(() => {}); }
            } catch (e) { post({ kind: 'ka', state: 'error ' + String(e) }); }
          }
          document.addEventListener('playing', keepAlive, true);
          document.addEventListener('pause', keepAlive, true);

          window.__kaset = {
            state: () => state('poll', true),
            play: () => {
              const m = media();
              if (!m) { return 'no-media'; }
              const p = m.play();
              if (p && p.catch) { p.catch((err) => post({ kind: 'playerr', msg: String(err) })); }
              return 'play()';
            },
            pause: () => { const m = media(); if (!m) { return 'no-media'; } markUserAction(); m.pause(); return 'pause()'; },
            toggle: () => click('playPause'),
            next: () => click('next'),
            previous: () => click('previous'),
            // Queue editing goes through the page's own queue items (selectors best effort).
            playQueueIndex: (i) => {
              const items = Array.from(document.querySelectorAll(QUEUE_ITEMS));
              const el = items[i];
              if (!el) { return 'missing:queue-item'; }
              const play = el.querySelector('ytmusic-play-button-renderer') || el;
              play.click();
              return 'clicked';
            },
            removeQueueIndex: (i) => {
              const items = Array.from(document.querySelectorAll(QUEUE_ITEMS));
              const el = items[i];
              if (!el) { return 'missing:queue-item'; }
              const menuButton = el.querySelector('ytmusic-menu-renderer button, ytmusic-menu-renderer tp-yt-paper-icon-button');
              if (!menuButton) { return 'missing:menu'; }
              menuButton.click();
              let tries = 0;
              const timer = setInterval(() => {
                tries += 1;
                const entries = Array.from(document.querySelectorAll('ytmusic-menu-popup-renderer ytmusic-menu-service-item-renderer'));
                const target = entries.find((e) => /remove from queue|retirer de la file|remove/i.test(e.textContent || ''));
                if (target) { clearInterval(timer); target.click(); return; }
                if (tries > 20) { clearInterval(timer); document.body.click(); }
              }, 100);
              return 'menu-opened';
            },
            // Awaitable removal used by queue editing: opens the entry's own menu, presses
            // "Remove from queue" and resolves once the queue shrank. On failure the result
            // carries what was found, so the app can show *why*.
            removeQueueIndexAsync: (i) => new Promise((resolve) => {
              const items = Array.from(document.querySelectorAll(QUEUE_ITEMS));
              const before = items.length;
              const el = items[i];
              if (!el) { return resolve('missing:queue-item(' + i + '/' + before + ')'); }

              const describe = (n) => n ? (n.tagName.toLowerCase() + (n.className ? '.' + String(n.className).split(' ').join('.') : '')) : 'none';
              const candidates = [
                'ytmusic-menu-renderer button',
                'ytmusic-menu-renderer tp-yt-paper-icon-button',
                'ytmusic-menu-renderer yt-icon-button',
                'ytmusic-menu-renderer',
                '[aria-label*="menu" i]',
                '[aria-label*="action" i]',
                '.menu button',
                '.menu'
              ];
              let menuButton = null;
              for (const sel of candidates) {
                menuButton = el.querySelector(sel);
                if (menuButton) { break; }
              }
              if (!menuButton) {
                return resolve('missing:menu in ' + describe(el) + ' children=' +
                  Array.from(el.children).map(describe).join(',').slice(0, 140));
              }
              // Menus can be hidden until hover/selection; make the row "active" first.
              try { el.dispatchEvent(new MouseEvent('mouseover', { bubbles: true })); } catch (e) {}
              menuButton.click();

              const isRemoveEntry = (e) => {
                try {
                  const d = e.data || e.__data || null;
                  if (d && JSON.stringify(d).indexOf('removeFromQueue') !== -1) { return true; }
                } catch (err) {}
                return /remove from queue|retirer de la file|remove|supprimer|retirer|quitar|entfernen/i.test(e.textContent || '');
              };

              let tries = 0;
              const poll = setInterval(() => {
                tries += 1;
                const entries = Array.from(document.querySelectorAll(
                  'ytmusic-menu-popup-renderer ytmusic-menu-service-item-renderer, '
                  + 'tp-yt-paper-listbox ytmusic-menu-service-item-renderer, '
                  + 'ytmusic-menu-service-item-renderer'
                ));
                const target = entries.find(isRemoveEntry);
                if (target) {
                  clearInterval(poll);
                  target.click();
                  let checks = 0;
                  const verify = setInterval(() => {
                    checks += 1;
                    if (document.querySelectorAll(QUEUE_ITEMS).length < before) {
                      clearInterval(verify);
                      resolve('removed');
                    } else if (checks > 30) {
                      clearInterval(verify);
                      resolve('readback-timeout(' + before + ')');
                    }
                  }, 100);
                } else if (tries > 25) {
                  clearInterval(poll);
                  try { document.body.click(); } catch (e) {}
                  resolve('menu-timeout entries=[' +
                    entries.map((e) => (e.textContent || '').trim().slice(0, 18)).join('|').slice(0, 120) + ']');
                }
              }, 100);
            }),
            inspectQueue: () => {
              const out = [];
              // The unified log truncates long lines: emit long values in pieces.
              const chunk = (label, value) => {
                const text = String(value === undefined ? 'undefined' : value).replace(/\\s+/g, ' ');
                for (let i = 0; i < text.length && i < 1500; i += 500) {
                  out.push(label + '[' + (i / 500) + ']: ' + text.slice(i, i + 500));
                }
              };
              const interesting = /reorder|move|drag|drop|swap|insert|remove|splice|queue|shuffle|index/i;
              const names = (o) => {
                const set = new Set();
                let p = o;
                for (let depth = 0; p && depth < 6 && p !== Object.prototype && p !== HTMLElement.prototype; depth += 1) {
                  Object.getOwnPropertyNames(p).forEach((n) => set.add(n));
                  p = Object.getPrototypeOf(p);
                }
                return Array.from(set).filter((n) => interesting.test(n)).slice(0, 60);
              };
              const targets = ['ytmusic-player-queue', 'ytmusic-queue', 'ytmusic-player-page', 'ytmusic-app', 'ytmusic-player-bar'];
              targets.forEach((tag) => {
                const el = document.querySelector(tag);
                out.push(tag + ': ' + (el ? names(el).join(',') : 'absent'));
              });
              const item = document.querySelector(QUEUE_ITEMS);
              if (item) {
                out.push('item: ' + item.tagName.toLowerCase() + ' attrs=' + Array.from(item.attributes).map((a) => a.name).join(','));
                out.push('item.methods: ' + names(item).join(','));
                const d = item.data || item.__data;
                out.push('item.data keys: ' + (d ? Object.keys(d).join(',') : 'none'));
                out.push('draggable=' + item.getAttribute('draggable') + ' handle=' + (item.querySelector('.drag-handle, [draggable], #drag-handle') ? 'yes' : 'no'));
                try {
                  out.push('item.data.canReorder=' + d.canReorder + ' playlistSetVideoId=' + (d.playlistSetVideoId ? 'yes' : 'no')
                    + ' playlistEditParams=' + (d.playlistEditParams ? 'yes' : 'no'));
                  chunk('item.data.queueNavigationEndpoint', JSON.stringify(d.queueNavigationEndpoint));
                } catch (e) { out.push('item.data error ' + e); }
              } else { out.push('no queue item'); }

              // What the queue component does on a drop, and what its queue object offers.
              const q = document.querySelector('ytmusic-player-queue');
              if (q) {
                const src = (name, f) => { if (typeof f === 'function') { chunk(name, Function.prototype.toString.call(f)); } else { out.push(name + ': ' + typeof f); } };
                src('q.onDrop', q.onDrop);
                out.push('q.selectedQueueItemIndex=' + q.selectedQueueItemIndex);
                const qq = q.queue;
                out.push('q.queue: ' + typeof qq + ' ctor=' + (qq && qq.constructor && qq.constructor.name)
                  + ' keys=' + Object.keys(qq || {}).slice(0, 40).join(','));
                if (qq && typeof qq === 'object') {
                  const all = new Set();
                  let p = qq;
                  for (let depth = 0; p && depth < 4 && p !== Object.prototype; depth += 1) {
                    Object.getOwnPropertyNames(p).forEach((n) => all.add(n));
                    p = Object.getPrototypeOf(p);
                  }
                  out.push('q.queue.members: ' + Array.from(all).slice(0, 90).join(','));
                }
                // The Polymer wrappers above are opaque proxies; the queue class's own methods and the
                // APIs behind it are plain code, so read those.
                if (qq && typeof qq === 'object') {
                  src('q.queue.removeItem', qq.removeItem);
                  src('q.queue.selectQueueItem', qq.selectQueueItem);
                  src('q.queue.shuffle', qq.shuffle);
                  src('q.queue.getItems', qq.getItems);
                  const interesting2 = /move|reorder|insert|add|swap|splice|update|replace|set.*items/i;
                  Object.keys(qq).filter((k) => /queueApi|serverQueueApi|store/i.test(k)).forEach((k) => {
                    const obj = qq[k];
                    if (!obj || typeof obj !== 'object') { out.push('q.queue.' + k + ': ' + typeof obj); return; }
                    const names = new Set();
                    let o = obj;
                    for (let depth = 0; o && depth < 4 && o !== Object.prototype; depth += 1) {
                      Object.getOwnPropertyNames(o).forEach((n) => names.add(n));
                      o = Object.getPrototypeOf(o);
                    }
                    const list = Array.from(names);
                    out.push('q.queue.' + k + ' ctor=' + (obj.constructor && obj.constructor.name) + ' members: ' + list.slice(0, 100).join(','));
                    list.filter((n) => interesting2.test(n) && typeof obj[n] === 'function').slice(0, 6).forEach((n) => {
                      src('q.queue.' + k + '.' + n, obj[n]);
                    });
                  });
                }
              } else { out.push('no ytmusic-player-queue'); }
              return out.join('\\n');
            },
            // A phone call (or similar) takes the audio: pause the media and the keep-alive
            // context, and keep the page from resuming either until it is over.
            setBackgroundGuard: (ms) => {
              window.__kasetBackgroundGuardUntil = Date.now() + ms;
              return 'armed';
            },
            setInterrupted: (flag) => {
              window.__kasetInterrupted = !!flag;
              const m = media();
              if (flag) {
                if (m && !m.paused) { m.pause(); }
                if (ctx && ctx.state === 'running') { ctx.suspend().catch(() => {}); }
              } else if (ctx && ctx.state !== 'running') {
                ctx.resume().catch(() => {});
              }
              return flag ? 'interrupted' : 'cleared';
            },
            // Read-only probe of every page part the app drives, for the player health screen.
            // Nothing is clicked; `track` marks checks that only make sense with a track loaded.
            health: () => {
              const checks = [];
              const add = (id, ok, detail, track) => checks.push({ id: id, ok: !!ok, detail: detail || '', track: !!track });
              const m = media();
              const hasTrack = !!m && isFinite(m.duration) && m.duration > 0;
              add('media', m, m ? m.tagName.toLowerCase() + ' readyState=' + m.readyState : 'no video/audio element', false);
              const api = playerApi();
              const apiOk = !!api && typeof api.seekTo === 'function' && typeof api.getVideoData === 'function';
              add('playerApi', apiOk, api ? (api.id || api.tagName || 'playerApi') + (apiOk ? '' : ' without seekTo/getVideoData') : 'absent', false);
              const app = document.querySelector('ytmusic-app');
              add('router', app && typeof app.resolveCommand === 'function',
                app ? (typeof app.resolveCommand === 'function' ? '' : 'resolveCommand missing (yt-navigate fallback)') : 'no ytmusic-app', false);
              const md = navigator.mediaSession && navigator.mediaSession.metadata;
              add('mediaSession', md && md.title, md && md.title ? md.title : 'no metadata', true);
              let bar = null;
              try { bar = __kasetPlayerBar(); } catch (e) {}
              add('playerBar', bar, bar ? bar.tagName.toLowerCase() : 'absent', false);
              ['playPause', 'next', 'previous'].forEach((name) => {
                let el = null;
                try { el = __kasetPlayerBarElement(name); } catch (e) {}
                const fallback = !el && legacy[name] ? document.querySelector(legacy[name]) : null;
                add(name, el || fallback, el ? '' : (fallback ? 'legacy selector only' : 'not found'), false);
              });
              const sb = shuffleButton();
              add('shuffle', sb, sb ? 'on=' + shuffleOn() : 'not found', false);
              const repeatAttr = bar && (bar.hasAttribute('repeat-mode_') || bar.hasAttribute('repeat-mode'));
              add('repeat', repeatButton() && repeatAttr, (repeatButton() ? 'button' : 'no button') + ', ' + (repeatAttr ? 'mode=' + repeatMode() : 'no repeat-mode attribute'), false);
              let menu = null;
              try { menu = __kasetPlayerBarElement('menu'); } catch (e) {}
              if (!menu && bar) {
                menu = Array.from(bar.querySelectorAll('button')).find((b) => (b.getAttribute('aria-label') || '').toLowerCase() === 'action menu') || null;
              }
              add('menu', menu, menu ? '' : 'not found', true);
              const queueEl = document.querySelector('ytmusic-player-queue');
              const items = queue();
              add('queue', queueEl && items.length > 0, (queueEl ? 'component ok' : 'no ytmusic-player-queue') + ', ' + items.length + ' items', true);
              const withIds = items.filter((e) => e.videoId).length;
              add('queueIds', items.length > 0 && withIds === items.length, withIds + '/' + items.length + ' with a video id', true);
              const current = items.filter((e) => e.current).length;
              add('queueCurrent', current === 1, current + ' marked current', true);
              let summary = 'buffer script not loaded';
              try { if (window.__kasetBuffer) { summary = window.__kasetBuffer.summary(); } } catch (e) {}
              const ahead = bufferAhead();
              // Informational: an empty buffer at the end of a track is normal; only a missing readout fails.
              add('buffer', ahead !== null, (ahead === null ? '?' : ahead) + ' s ahead · ' + summary, true);
              return { hasTrack: hasTrack, checks: checks };
            },
            shuffle: () => { const b = shuffleButton(); if (!b) { return 'missing:shuffle'; } b.click(); return 'clicked'; },
            repeat: () => { const b = repeatButton(); if (!b) { return 'missing:repeat'; } b.click(); return 'clicked'; },
            seek: (t) => {
              const api = playerApi();
              try {
                if (api && typeof api.seekTo === 'function') { api.seekTo(t, true); return 'api-seek'; }
              } catch (e) {}
              const m = media();
              if (!m) { return 'no-media'; }
              m.currentTime = t;
              return 'media-seek';
            }
          };
          post({ kind: 'boot', path: location.pathname + location.search.slice(0, 40), vis: realVis() });
        })();
        """
    }
}
