import SwiftUI
import WebKit

/// In-app Google account connection.
///
/// Hosts Google's `EmbeddedSetup` flow in a `WKWebView` the app owns, then reads
/// the HttpOnly `oauth_token` cookie straight from that view's own cookie store.
/// `WKHTTPCookieStore.getAllCookies` returns HttpOnly cookies on every supported
/// iOS version — unlike a Safari web extension's `browser.cookies`, which cannot
/// see HttpOnly cookies on iOS 17. That difference is the whole reason this
/// replaces the Safari extension + handoff path; see docs/ADR-001-auth-route.md.
struct AccountConnectView: View {
    /// Delivered once, with the captured `oauth_token` value.
    var onCaptured: (String) -> Void
    var onCancel: () -> Void

    @State private var loading = true
    @State private var didCapture = false

    var body: some View {
        NavigationRoot {
            ZStack {
                EmbeddedSetupWebView(loading: $loading) { token in
                    guard !didCapture else { return }
                    didCapture = true
                    onCaptured(token)
                }
                if loading {
                    BackupTheme.background.opacity(0.001) // keep taps flowing to the web view
                    ProgressView("Loading Google sign-in…")
                        .controlSize(.large)
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
            .ignoresSafeArea(.container, edges: .bottom)
            .navigationTitle("Connect Google Account")
            .inlineNavigationTitleCompat()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                }
            }
        }
    }
}

private let embeddedSetupURL = URL(string: "https://accounts.google.com/EmbeddedSetup")!

/// Shared setup for the `WKWebView` both platform wrappers below create: a
/// non-persistent data store, the mobile/desktop Safari user agent, and the
/// coordinator wired up as both navigation delegate and cookie-store observer.
private func configureEmbeddedSetupWebView(_ webView: WKWebView, coordinator: EmbeddedSetupCoordinator) {
    webView.customUserAgent = EmbeddedSetupCoordinator.safariUserAgent
    webView.navigationDelegate = coordinator
    webView.allowsBackForwardNavigationGestures = false

    let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
    coordinator.cookieStore = cookieStore
    cookieStore.add(coordinator)
    // The observer alone is not enough: after "I agree" the EmbeddedSetup page
    // just spins (it waits for a native Android consumer that never arrives in
    // a browser), and cookiesDidChange does not reliably fire for a cookie set
    // via an HTTP Set-Cookie header. So poll the store too.
    coordinator.startPolling()

    webView.load(URLRequest(url: embeddedSetupURL))
}

#if os(iOS)
/// The `WKWebView` and the cookie-store observer that watches for `oauth_token`.
private struct EmbeddedSetupWebView: UIViewRepresentable {
    @Binding var loading: Bool
    var onToken: (String) -> Void

    func makeCoordinator() -> EmbeddedSetupCoordinator { EmbeddedSetupCoordinator(loading: $loading, onToken: onToken) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Non-persistent: the Google session and the captured token never touch
        // disk and are gone the moment this view is torn down.
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: config)
        configureEmbeddedSetupWebView(webView, coordinator: context.coordinator)
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: EmbeddedSetupCoordinator) {
        coordinator.stop()
    }
}
#elseif os(macOS)
/// The `WKWebView` and the cookie-store observer that watches for `oauth_token`.
private struct EmbeddedSetupWebView: NSViewRepresentable {
    @Binding var loading: Bool
    var onToken: (String) -> Void

    func makeCoordinator() -> EmbeddedSetupCoordinator { EmbeddedSetupCoordinator(loading: $loading, onToken: onToken) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Non-persistent: the Google session and the captured token never touch
        // disk and are gone the moment this view is torn down.
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: config)
        configureEmbeddedSetupWebView(webView, coordinator: context.coordinator)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    static func dismantleNSView(_ nsView: WKWebView, coordinator: EmbeddedSetupCoordinator) {
        coordinator.stop()
    }
}
#endif

final class EmbeddedSetupCoordinator: NSObject, WKNavigationDelegate, WKHTTPCookieStoreObserver {
    private static let cookieName = "oauth_token"
    private let loading: Binding<Bool>
    private let onToken: (String) -> Void
    private var captured = false
    private var pollTimer: Timer?
    weak var cookieStore: WKHTTPCookieStore?

    init(loading: Binding<Bool>, onToken: @escaping (String) -> Void) {
        self.loading = loading
        self.onToken = onToken
    }

    /// Poll the cookie store until `oauth_token` shows up. Runs on the main
    /// run loop; self-cancels on capture or when `stop()` tears the view down.
    func startPolling() {
        let timer = Timer(timeInterval: 0.6, repeats: true) { [weak self] _ in
            self?.checkForToken()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        cookieStore?.remove(self)
    }

    private func checkForToken() {
        guard !captured, let store = cookieStore else { return }
        store.getAllCookies { [weak self] cookies in self?.capture(from: cookies) }
    }

    private func capture(from cookies: [HTTPCookie]) {
        guard !captured else { return }
        guard let cookie = cookies.first(where: {
            $0.name == Self.cookieName
                && $0.domain.contains("accounts.google.com")
                && !$0.value.isEmpty
        }) else { return }
        captured = true
        pollTimer?.invalidate()
        pollTimer = nil
        let value = cookie.value
        DispatchQueue.main.async { self.onToken(value) }
    }

    /// The full Safari UA for the running OS version: mobile Safari on iOS,
    /// desktop Safari on macOS. A bare `WKWebView` user agent omits the
    /// "Version/x … Safari/x" tokens that Google's "browser may not be
    /// secure" check keys on; presenting a full Safari UA makes EmbeddedSetup
    /// behave exactly as it does in Safari itself, which is the configuration
    /// proven to work.
    static var safariUserAgent: String {
#if os(iOS)
        let version = UIDevice.current.systemVersion            // e.g. "17.2"
        let underscored = version.replacingOccurrences(of: ".", with: "_")
        return "Mozilla/5.0 (iPhone; CPU iPhone OS \(underscored) like Mac OS X) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(version) Mobile/15E148 Safari/604.1"
#else
        let os = ProcessInfo.processInfo.operatingSystemVersion   // e.g. 14.5.0
        let underscored = "\(os.majorVersion)_\(os.minorVersion)_\(os.patchVersion)"
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X \(underscored)) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(os.majorVersion).\(os.minorVersion) Safari/605.1.15"
#endif
    }

    // MARK: WKHTTPCookieStoreObserver

    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        cookieStore.getAllCookies { [weak self] cookies in self?.capture(from: cookies) }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        loading.wrappedValue = false
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loading.wrappedValue = false
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loading.wrappedValue = false
    }
}
