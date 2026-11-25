import Foundation

/// Ad signal detection, copied from kaset `Services/WebKit/PlaybackAdDetectionScript.swift`
/// (`detection`; the observation hook is not needed: the page script polls instead).
enum AdDetectionScript {
    nonisolated static var detection: String {
        """
        function adPlayerAPIs() {
            const moviePlayer = document.getElementById('movie_player');
            const musicPlayer = document.querySelector('ytmusic-player');
            const musicAPI = musicPlayer && musicPlayer.playerApi;
            return [moviePlayer, musicAPI].filter(function(api, index, apis) {
                return api && apis.indexOf(api) === index;
            });
        }

        function hasAdPlayerSignal() {
            const moviePlayer = document.getElementById('movie_player');
            if (moviePlayer && moviePlayer.classList
                && (moviePlayer.classList.contains('ad-showing')
                    || moviePlayer.classList.contains('ad-interrupting'))) {
                return true;
            }
            for (const api of adPlayerAPIs()) {
                try {
                    // Player type 2 is ad media. Passing true also includes
                    // server-stitched segments when supported by the player.
                    if (typeof api.getPresentingPlayerType === 'function'
                        && api.getPresentingPlayerType(true) === 2) {
                        return true;
                    }
                } catch (e) {}
            }
            return false;
        }

        function isAdShowing() {
            const isAd = hasAdPlayerSignal();
            let contentVideoId = '';
            try {
                contentVideoId = new URL(window.location.href).searchParams.get('v') || '';
            } catch (e) {}

            let videoId = '';
            // Match the bridges' metadata preference: Music API, then movie player.
            for (const api of adPlayerAPIs().reverse()) {
                try {
                    const data = typeof api.getVideoData === 'function' ? api.getVideoData() : null;
                    const id = data && (data.video_id || data.videoId);
                    if (typeof id === 'string' && id) {
                        videoId = id;
                        break;
                    }
                } catch (e) {}
            }
            if (isAd && contentVideoId && videoId && videoId !== contentVideoId) {
                window.__kasetAdVideoId = videoId;
            }
            // Ad-end signals can precede the return of content media. Share the
            // known creative ID with end-event and recovery-seek scripts too.
            const adVideoId = window.__kasetAdVideoId || '';
            const video = document.querySelector('#movie_player video') || document.querySelector('video');
            const boundVideoId = video && video.__kasetBoundVideoId;
            // An ad pod can change creatives while ad signals briefly clear.
            // Wait for the requested content's metadata and physical media.
            const awaitingContent = adVideoId !== ''
                && adVideoId !== contentVideoId
                && (videoId !== contentVideoId
                    || (!!boundVideoId && boundVideoId !== contentVideoId));
            if (!isAd && !awaitingContent) delete window.__kasetAdVideoId;
            return isAd || awaitingContent;
        }
        """
    }
}

/// "Skip ads automatically" preference. Off by default: skipping ads may go against
/// YouTube's terms, so it is an explicit opt-in.
enum AdSkip {
    static let storageKey = "settings.adAutoSkip"

    /// On unless the user turned it off.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: self.storageKey) as? Bool ?? true
    }
}
