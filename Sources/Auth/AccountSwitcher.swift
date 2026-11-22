import Foundation
import WebKit

/// Re-points a Google account's web session at another of its identities (personal or brand
/// channel).
///
/// Each identity carries a server-issued sign-in URL; loading it in a web view that shares the
/// account's data store switches the active delegated identity for every web view on that store,
/// including playback. API calls additionally send `onBehalfOfUser` (see
/// `YTMusicClient.brandIdProvider`). The chosen brand id is kept on the `GoogleAccount`.
@MainActor
final class AccountSwitcher: NSObject, WKNavigationDelegate {
    /// Where single-account versions kept the brand id (read once by the migration).
    static let legacyBrandIdKey = "settings.brandAccountId"

    private var continuation: CheckedContinuation<Void, Never>?
    private var webView: WKWebView?

    /// Loads the identity's sign-in URL and waits for the navigation to settle (or time out).
    func switchSession(to account: UserAccount, in dataStore: WKWebsiteDataStore) async {
        guard let url = account.signinURL else { return }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.applicationNameForUserAgent = "Version/17.0 Mobile/15E148 Safari/604.1"
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        self.webView = webView

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.continuation = continuation
            webView.load(URLRequest(url: url))
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                self?.finish()
            }
        }
    }

    private func finish() {
        self.webView?.stopLoading()
        self.webView = nil
        self.continuation?.resume()
        self.continuation = nil
    }

    func webView(_: WKWebView, didFinish _: WKNavigation!) { self.finish() }
    func webView(_: WKWebView, didFail _: WKNavigation!, withError _: Error) { self.finish() }
    func webView(_: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError _: Error) { self.finish() }
}
