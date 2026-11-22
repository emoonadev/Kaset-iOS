import SwiftUI
import WebKit

// Adapted from kaset: Views/LoginWebView.swift, Services/WebKit/LoginPasskeySuppression.swift
// (ADR-0033). Without the restricted passkey entitlement every WebAuthn ceremony dead-ends,
// so the API is hidden and Google falls back to the password flow.

enum LoginPasskeySuppression {
    static let scriptSource = """
    (function () {
        "use strict";
        try {
            delete window.PublicKeyCredential;
            Object.defineProperty(window, "PublicKeyCredential", {
                value: undefined, writable: false, configurable: false,
            });
        } catch (error) {}
        try {
            var credentials = window.navigator && window.navigator.credentials;
            if (!credentials) { return; }
            var prototype = Object.getPrototypeOf(credentials);
            var wrap = function (original) {
                if (typeof original !== "function") { return original; }
                return function (options) {
                    if (options && options.publicKey) {
                        return Promise.reject(new DOMException(
                            "Passkeys are not available in this app.", "NotAllowedError"));
                    }
                    return original.apply(this, arguments);
                };
            };
            prototype.get = wrap(prototype.get);
            prototype.create = wrap(prototype.create);
        } catch (error) {}
    })();
    """

    static func makeUserScript() -> WKUserScript {
        WKUserScript(source: self.scriptSource, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }
}

/// Google sign-in. Cookies land in the shared default data store, which `AuthStore` reads.
@MainActor
struct LoginView {
    static let url = URL(string: "https://accounts.google.com/ServiceLogin?service=youtube&uilel=3&passive=true&continue=https%3A%2F%2Fwww.youtube.com%2Fsignin%3Faction_handle_signin%3Dtrue%26app%3Ddesktop%26hl%3Den%26next%3Dhttps%253A%252F%252Fmusic.youtube.com%252F")!

    let onReachedMusic: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onReachedMusic: self.onReachedMusic) }

    fileprivate func makeWebView(coordinator: Coordinator) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        #if os(iOS)
        // Google rejects the desktop UA used for playback; the iOS UA plus this suffix signs in.
        configuration.applicationNameForUserAgent = "Version/17.0 Mobile/15E148 Safari/604.1"
        #endif
        configuration.userContentController.addUserScript(LoginPasskeySuppression.makeUserScript())
        let webView = WKWebView(frame: .zero, configuration: configuration)
        #if os(macOS)
        // Same as Kaset for macOS: the desktop Safari UA signs in on the Mac.
        webView.customUserAgent = WebPlayer.desktopUserAgent
        #endif
        webView.navigationDelegate = coordinator
        #if DEBUG
            webView.isInspectable = true
        #endif
        webView.load(URLRequest(url: Self.url))
        return webView
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onReachedMusic: () -> Void

        init(onReachedMusic: @escaping () -> Void) { self.onReachedMusic = onReachedMusic }

        func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
            if webView.url?.host?.contains("music.youtube.com") == true {
                self.onReachedMusic()
            }
        }
    }
}

#if os(iOS)
extension LoginView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { self.makeWebView(coordinator: context.coordinator) }
    func updateUIView(_: WKWebView, context _: Context) {}
}
#else
extension LoginView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { self.makeWebView(coordinator: context.coordinator) }
    func updateNSView(_: WKWebView, context _: Context) {}
}
#endif
