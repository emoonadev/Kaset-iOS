import Foundation
import Observation

/// Whether YouTube Music offers the Podcasts discovery page to this account.
///
/// The page is not offered in every region: there, `FEmusic_podcasts` answers HTTP 404 and the
/// web client hides it. The region comes from YouTube (cookies, IP), not from the app, so the
/// page is probed once per account and launch, and the Podcasts entry (Discover segment on
/// iOS, sidebar row on macOS) is hidden after a 404. Search, artist pages and the library show
/// podcasts through other endpoints and stay available everywhere. Nothing is persisted: a
/// region change (VPN) is picked up at the next launch. Same approach as kaset (ADR-0019).
@MainActor
@Observable
final class PodcastsAvailability {
    enum State: Equatable {
        case unknown, available, unavailable
    }

    private(set) var state: State = .unknown

    /// The entry stays visible until a 404 says otherwise.
    var isHidden: Bool { self.state == .unavailable }

    /// Account the last probe ran for: a new sign-in, sign-out or account switch probes again.
    @ObservationIgnored private var probedScope: String?
    @ObservationIgnored private var generation = 0

    func probe(client: YTMusicClient, scope: String) async {
        guard self.probedScope != scope else { return }
        self.probedScope = scope
        self.generation &+= 1
        let generation = self.generation
        do {
            // Warms the cache, so opening Podcasts right after is instant.
            let page = try await client.getPodcasts()
            guard generation == self.generation else { return }
            // An empty page from a background probe is noise (cold cache, transient issue).
            if !page.sections.isEmpty { self.state = .available }
        } catch {
            guard generation == self.generation else { return }
            if Self.isRegionUnavailable(error) {
                self.state = .unavailable
            } else {
                // Transient failure: try again next time.
                self.probedScope = nil
            }
        }
    }

    /// Result of a load the user started on the Podcasts page.
    func record(sections: [PodcastSection]) {
        self.state = sections.isEmpty ? .unavailable : .available
    }

    func record(_ error: Error) {
        if Self.isRegionUnavailable(error) { self.state = .unavailable }
    }

    nonisolated static func isRegionUnavailable(_ error: Error) -> Bool {
        if case let .apiError(_, code) = error as? YTMusicError { return code == 404 }
        return false
    }
}
