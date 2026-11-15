import HermesKit
import SwiftUI
import WebKit

// The access gateway's sign-in page (`docs/connecting-and-voice.md` §11.10), in a sheet of its own.
// The page is untrusted content: it loads the gateway's address and the sign-in addresses the
// access gateway sends it through (`AccessSignInPolicy`), keeps its cookies in a store that is
// thrown away with the sheet, and gives the app nothing but the session cookie it sets for the
// gateway. It never reaches a chat or the clipboard, and nothing from it is logged.

extension View {
    /// Presents the sign-in page for `gateway`. `finished` gets the session the page gave, or nil
    /// when it closed without one (the page failed to load, or the gateway let it through without
    /// a sign-in); Cancel calls nothing.
    func accessSignIn(
        isPresented: Binding<Bool>, gateway: URL?, identity: ClientIdentity? = nil,
        finished: @escaping (AccessSession?) -> Void
    ) -> some View {
        sheet(isPresented: isPresented) {
            if let gateway {
                AccessSignInSheet(gateway: gateway, identity: identity) { session in
                    isPresented.wrappedValue = false
                    finished(session)
                } cancel: {
                    isPresented.wrappedValue = false
                }
            }
        }
    }
}

struct AccessSignInSheet: View {
    let gateway: URL
    let identity: ClientIdentity?
    let finished: (AccessSession?) -> Void
    let cancel: () -> Void
    @State private var page: AccessSignInPage?

    var body: some View {
        NavigationStack {
            ZStack {
                if let page {
                    WebViewHost(webView: page.webView)
                        .opacity(page.hasContent ? 1 : 0)
                    if !page.hasContent {
                        Spinner()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.sheetBackground)
            .navigationTitle(page?.host ?? gateway.host() ?? "")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: cancel)
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 520, minHeight: 600, idealHeight: 680)
        #endif
        .task {
            guard page == nil else { return }
            let page = AccessSignInPage(gateway: gateway, identity: identity, finished: finished)
            self.page = page
            page.start()
        }
        .onDisappear { page?.stop() }
    }
}

/// The web view and what it may do. Every navigation goes through `AccessSignInPolicy`; the
/// gateway answering past the access gateway ends the sign-in.
@Observable
final class AccessSignInPage: NSObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    /// The address the page is on, for the sheet's title: the person sees whose page this is.
    private(set) var host: String?
    /// A page has drawn, so the spinner gives way to it.
    private(set) var hasContent = false
    @ObservationIgnored private var policy: AccessSignInPolicy
    @ObservationIgnored private let identity: ClientIdentity?
    @ObservationIgnored private var finished: ((AccessSession?) -> Void)?

    init(gateway: URL, identity: ClientIdentity?, finished: @escaping (AccessSession?) -> Void) {
        policy = AccessSignInPolicy(gateway: gateway)
        self.identity = identity
        self.finished = finished
        let configuration = WKWebViewConfiguration()
        // Its own jar, gone with the sheet: nothing carries over from a sign-in to the next, or
        // into anything else the app shows.
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.addUserScript(
            WKUserScript(source: Self.noClipboard, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )
        #if os(iOS)
        configuration.dataDetectorTypes = []
        #endif
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.allowsLinkPreview = false
        webView.navigationDelegate = self
        webView.uiDelegate = self
        host = gateway.host()
    }

    /// The page can't write to the clipboard or change what the person copies.
    private static let noClipboard = """
    (() => {
      try { Object.defineProperty(navigator, 'clipboard', { get: () => undefined }); } catch (e) {}
      const exec = Document.prototype.execCommand;
      Document.prototype.execCommand = function (command, ...rest) {
        return /^(copy|cut)$/i.test(String(command)) ? false : exec.call(this, command, ...rest);
      };
      for (const kind of ['copy', 'cut']) {
        window.addEventListener(kind, event => event.stopImmediatePropagation(), true);
      }
    })();
    """

    func start() {
        webView.load(URLRequest(url: policy.start))
    }

    func stop() {
        finished = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    private func finish(_ session: AccessSession?) {
        guard let finished else { return }
        stop()
        finished(session)
    }

    private static func navigation(_ type: WKNavigationType) -> AccessSignInPolicy.Navigation {
        switch type {
        case .linkActivated: .link
        case .formSubmitted, .formResubmitted: .form
        default: .other
        }
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = action.request.url else { return decisionHandler(.cancel) }
        let decision = policy.decide(
            url, navigation: Self.navigation(action.navigationType),
            isMainFrame: action.targetFrame?.isMainFrame ?? true, isNewWindow: action.targetFrame == nil
        )
        switch decision {
        case .allow:
            decisionHandler(.allow)
        case .openOutside(let url):
            decisionHandler(.cancel)
            Self.openOutside(url)
        case .cancel:
            decisionHandler(.cancel)
        }
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
        decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void
    ) {
        let status = (response.response as? HTTPURLResponse)?.statusCode ?? 0
        if let url = response.response.url, policy.isThrough(url, status: status, isMainFrame: response.isForMainFrame) {
            // Hermes answered: the access gateway let the page through, so its cookies for the
            // gateway are the session. The gateway's own answer isn't shown.
            decisionHandler(.cancel)
            let gateway = policy.gateway
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                self?.finish(AccessSession.from(cookies, for: gateway))
            }
            return
        }
        // Nothing is downloaded from the page.
        decisionHandler(response.canShowMIMEType ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        hasContent = true
        host = webView.url?.host() ?? host
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        failed(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        failed(error)
    }

    /// A load that stopped because the policy cancelled it is no failure. Anything else closes
    /// the sheet, and Check Again says what's wrong.
    private func failed(_ error: any Error) {
        let error = error as NSError
        if error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled { return }
        if error.domain == "WebKitErrorDomain", error.code == 102 { return } // Frame load interrupted.
        finish(nil)
    }

    /// The proxy's certificate challenge on the gateway, answered with the gateway's own client
    /// certificate when it has one. Server trust is the system's.
    func webView(
        _ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @MainActor (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodClientCertificate else {
            return completionHandler(.performDefaultHandling, nil)
        }
        if let identity, policy.isGatewayHandshake(host: space.host, port: space.port) {
            completionHandler(.useCredential, identity.credential)
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    /// A page asking for a new window: it opens in the browser instead, through the policy.
    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for action: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = action.request.url,
           case .openOutside(let url) = policy.decide(url, navigation: .link, isMainFrame: true, isNewWindow: true) {
            Self.openOutside(url)
        }
        return nil
    }

    /// A link off the sign-in, in the browser (`WebLink`): http and https only.
    private static func openOutside(_ url: URL) {
        guard WebLink.isWeb(url) else { return }
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }
}
