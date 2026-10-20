import Foundation
import HermesKit
import Observation
import SwiftUI
import WebKit

/// One Preview tab (`docs/inspector.md` §2, §3): the app's own web view, its URL bar's state, how
/// this device reaches a gateway's localhost, and Hermes's reads and actions in the page.
@MainActor
@Observable
final class PreviewController: NSObject {
    enum Reach: Equatable {
        case loading
        case loaded
        /// localhost on the gateway machine, which this device can't reach (`reachNote`).
        case unreachable(host: String)
        /// A page on this device's own network (a router, a NAS): it opens once the person says so.
        case asks(host: String)
        case failed(String)
    }

    @ObservationIgnored private weak var inspector: InspectorModel?
    let tabID: String
    private(set) var target: PreviewTarget
    private(set) var reach = Reach.loading
    /// What the URL bar shows: the page's own address as Hermes and the person call it.
    private(set) var address: String
    private(set) var pageTitle = ""
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var isLoading = false
    /// The URL actually loaded, after a localhost rewrite.
    private(set) var loadedURL: URL?
    /// "on Studio Mac": where a localhost page runs.
    var hostNote: String? {
        guard target.isLocalhost else { return nil }
        return String(localized: "on \(inspector?.gatewayMachineName ?? String(localized: "the gateway"))")
    }

    @ObservationIgnored private var webViewStorage: WKWebView?
    @ObservationIgnored private var triedRewrite = false
    @ObservationIgnored private var personObserver: PersonInput?
    @ObservationIgnored private var fileScheme: GatewayFileScheme?
    /// Hosts on this device's network the person opened or allowed in this tab.
    @ObservationIgnored private var allowedHosts: Set<String> = []

    init(inspector: InspectorModel, tabID: String, target: PreviewTarget) {
        self.inspector = inspector
        self.tabID = tabID
        self.target = target
        address = target.displayURL
        super.init()
    }

    var webView: WKWebView {
        if let webViewStorage { return webViewStorage }
        let configuration = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: PreviewEngine.source, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let observer = PersonInput { [weak self] in self?.personTouchedPage() }
        controller.add(observer, name: "hermesPerson")
        personObserver = observer
        configuration.userContentController = controller
        if let backend = inspector?.backend {
            let scheme = GatewayFileScheme(backend: backend, profile: inspector?.profile)
            configuration.setURLSchemeHandler(scheme, forURLScheme: GatewayFileScheme.scheme)
            fileScheme = scheme
        }
        // Each gateway keeps its own cookies and storage: one gateway's pages never see another's.
        if let id = inspector?.gatewayID {
            configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: id)
        }
        #if os(iOS)
        configuration.allowsInlineMediaPlayback = true
        #endif
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.allowsBackForwardNavigationGestures = true
        #if DEBUG
        view.isInspectable = true
        #endif
        #if os(macOS)
        view.setValue(false, forKey: "drawsBackground")
        #else
        view.isOpaque = false
        view.backgroundColor = .clear
        #endif
        webViewStorage = view
        load()
        return view
    }

    func tearDown() {
        webViewStorage?.stopLoading()
        webViewStorage?.configuration.userContentController.removeAllScriptMessageHandlers()
        webViewStorage = nil
    }

    // MARK: Loading

    /// Points the tab somewhere else (`preview.open` for a tab that's already open, the URL bar).
    /// An address the person typed counts as their say-so for a page on this device's network.
    func open(_ raw: String, byPerson: Bool = false) {
        target = PreviewTarget(raw)
        address = target.displayURL
        triedRewrite = false
        if byPerson, let host = target.url?.host()?.lowercased() { allowedHosts.insert(host) }
        load()
    }

    /// The person let a page on this device's network open (`Reach.asks`).
    func allowLocalPage() {
        guard case .asks(let host) = reach else { return }
        allowedHosts.insert(host)
        if let askedURL, let webView = webViewStorage {
            self.askedURL = nil
            reach = .loading
            webView.load(URLRequest(url: askedURL))
        } else {
            load()
        }
    }

    /// A page on this device's network (not the gateway itself) that nobody here has allowed:
    /// Hermes shouldn't reach a router or a NAS through this device on its own, by opening it or by
    /// following a link to it. This device's own loopback counts too, unless the gateway is this
    /// machine (then it's the gateway's dev servers).
    /// A name is looked up too: a public name can point at a private or loopback address.
    private func asksFirst(_ url: URL) async -> String? {
        guard WebLink.isWeb(url), let host = url.host()?.lowercased() else { return nil }
        let gateway = inspector?.gatewayHost?.lowercased()
        if host == gateway || allowedHosts.contains(host) { return nil }
        if PreviewTarget.isLocalHost(host), let gateway, GatewayHost.isThisMachine(gateway) { return nil }
        if BotConfiguration.looksLocal(host) { return host }
        return await HostAddresses.resolvesLocal(host) ? host : nil
    }

    /// The page a navigation wanted when it stopped to ask (`Reach.asks`).
    @ObservationIgnored private var askedURL: URL?
    /// Counts loads, so a lookup that finishes after a newer load gives up (`asksFirst`).
    @ObservationIgnored private var loadGeneration = 0

    func load() {
        guard let webView = webViewStorage else { return }
        reach = .loading
        loadGeneration += 1
        guard let url = urlToLoad() else {
            reach = .failed(String(localized: "This address can't be opened."))
            return
        }
        let generation = loadGeneration
        Task { [weak self] in
            let host = await self?.asksFirst(url)
            guard let self, generation == self.loadGeneration, webView === self.webViewStorage else { return }
            if let host {
                askedURL = nil
                reach = .asks(host: host)
                return
            }
            if url.scheme == GatewayFileScheme.scheme { fileScheme?.allowFolder(of: url) }
            loadedURL = url
            webView.load(URLRequest(url: url))
        }
    }

    func reload() {
        guard let webView = webViewStorage else { return }
        if case .unreachable = reach {
            triedRewrite = false
            load()
        } else if webView.url == nil {
            load()
        } else {
            webView.reload()
        }
    }

    func goBack() { webViewStorage?.goBack() }
    func goForward() { webViewStorage?.goForward() }

    /// A turn changed files: a localhost page picks the change up.
    func reloadIfLocal() {
        guard target.isLocalhost, reach == .loaded else { return }
        webViewStorage?.reload()
    }

    /// localhost on this Mac when the gateway is this Mac; otherwise the gateway machine's host
    /// name, tried once. A gateway file through the app's scheme (relative assets follow).
    private func urlToLoad() -> URL? {
        switch target.kind {
        case .web:
            // Web pages only: not this app's links, files or other apps.
            return target.url.flatMap { WebLink.isWeb($0) ? $0 : nil }
        case .gatewayFile(let path):
            return GatewayFileScheme.url(for: path)
        case .localhost:
            guard let host = inspector?.gatewayHost else { return target.url }
            if GatewayHost.isThisMachine(host) { return target.url }
            triedRewrite = true
            return target.rewritten(toHost: host)
        }
    }

    // MARK: Hermes reading and acting (`preview.read`, `preview.act`)

    /// The page's visible text, paged.
    func read(start: Int?, count: Int?) async -> JSONValue {
        let kind: String
        switch target.kind {
        case .gatewayFile: kind = "file"
        default: kind = "browser"
        }
        guard let webView = webViewStorage, reach == .loaded,
              let read = await Self.withTimeout(.seconds(8), { try await webView.evaluateJavaScript("window.__hermesApp ? window.__hermesApp.read() : ''") as? String }),
              let raw = read,
              let data = raw.data(using: .utf8),
              let page = JSONValue.parse(data) else {
            var answer: [String: JSONValue] = ["kind": .string(kind), "url": .string(address), "title": .string(pageTitle), "text": .string(""),
                                               "start": .number(0), "end": .number(0), "total_chars": .number(0)]
            answer["note"] = .string(reachNote)
            return PreviewBridge.answer(answer)
        }
        return PreviewBridge.readAnswer(kind: kind, url: page["url"]?.stringValue ?? address, title: page["title"]?.stringValue ?? pageTitle,
                                        text: page["text"]?.stringValue ?? "", start: start, count: count)
    }

    private var reachNote: String {
        switch reach {
        case .unreachable(let host): "The page isn't reachable from this device: \(target.displayURL) only listens on \(host)."
        case .failed(let message): message
        default: "The page has not finished loading. Retry in a moment."
        }
    }

    /// One action in the page. Navigation verbs are the web view's; the rest run in the page.
    func act(_ action: PreviewAction) async -> JSONValue {
        guard let webView = webViewStorage else {
            return PreviewBridge.answer(["success": .bool(false), "error": .string("No live page is open in the preview. Open one with desktop_preview first.")])
        }
        switch action.verb {
        case .back, .forward, .reload:
            switch action.verb {
            case .back: webView.goBack()
            case .forward: webView.goForward()
            default: webView.reload()
            }
            try? await Task.sleep(for: .milliseconds(600))
            return PreviewBridge.answer([
                "success": .bool(true), "acted": .string(action.verb.rawValue),
                "url": .string(webView.url?.absoluteString ?? ""), "title": .string(webView.title ?? ""),
            ])
        default:
            break
        }
        let result = await Self.withTimeout(.seconds(8)) {
            try await webView.callAsyncJavaScript(
                "if (!window.__hermesApp) { return JSON.stringify({success: false, error: 'The page is still loading. Call elements again in a moment.'}); } return JSON.stringify(await window.__hermesApp.run(JSON.parse(args)));",
                arguments: ["args": action.engineArguments], in: nil, contentWorld: .page
            ) as? String
        }
        guard let result else {
            return PreviewBridge.answer(["success": .bool(false), "error": .string("The page did not answer in time, so it may not have acted. Call elements to see where it is.")])
        }
        guard let text = result, let data = text.data(using: .utf8),
              case .object(let object)? = JSONValue.parse(data) else {
            // A click that navigates tears the page down mid-answer.
            return PreviewBridge.answer([
                "success": .bool(true), "note": .string("The page stopped answering right after; it is probably navigating. Call elements to see where you landed."),
                "url": .string(webView.url?.absoluteString ?? ""),
            ])
        }
        return PreviewBridge.answer(object)
    }

    /// Runs a page call, giving up after `limit` (a navigation can leave it hanging): nil when it
    /// timed out, `.some(nil)` when the page threw or answered nothing.
    private static func withTimeout(_ limit: Duration, _ work: @escaping @MainActor () async throws -> String?) async -> String?? {
        await withCheckedContinuation { (done: CheckedContinuation<String??, Never>) in
            let once = Once()
            Task { @MainActor in
                let value = try? await work()
                if once.take() { done.resume(returning: .some(value ?? nil)) }
            }
            Task { @MainActor in
                try? await Task.sleep(for: limit)
                if once.take() { done.resume(returning: .none) }
            }
        }
    }

    @MainActor
    private final class Once {
        private var taken = false

        func take() -> Bool {
            guard !taken else { return false }
            taken = true
            return true
        }
    }

    /// Rings what Hermes is about to touch (`agentHighlight`), labelled with the verb.
    func ring(_ action: PreviewAction, ink: String, onInk: String) async {
        guard let webView = webViewStorage else { return }
        var target: [String: String] = [:]
        if let ref = action.ref { target["ref"] = ref }
        if let selector = action.selector { target["selector"] = selector }
        guard !target.isEmpty, let data = try? JSONEncoder().encode(target), let json = String(data: data, encoding: .utf8) else { return }
        _ = try? await webView.callAsyncJavaScript(
            "return window.__hermesApp ? window.__hermesApp.ring(JSON.parse(target), label, ink, onInk) : false",
            arguments: ["target": json, "label": action.label, "ink": ink, "onInk": onInk], in: nil, contentWorld: .page
        )
    }

    func unring() async {
        _ = try? await webViewStorage?.evaluateJavaScript("window.__hermesApp && window.__hermesApp.unring(); true")
    }

    private func personTouchedPage() {
        inspector?.personTouchedPreview(tabID: tabID)
    }
}

extension PreviewController: WKNavigationDelegate {
    /// A link, a redirect or a script can't take the page to this device's network without asking,
    /// any more than opening an address can; nor can a frame inside the page, which just doesn't
    /// load (only the page itself asks).
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = action.request.url, let host = await asksFirst(url) else { return .allow }
        guard action.targetFrame?.isMainFrame ?? true else { return .cancel }
        askedURL = url
        reach = .asks(host: host)
        return .cancel
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        syncState(webView, loading: true)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        reach = .loaded
        syncState(webView, loading: false)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        failed(webView, error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        failed(webView, error)
    }

    private func failed(_ webView: WKWebView, _ error: any Error) {
        syncState(webView, loading: false)
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return }
        if target.isLocalhost, nsError.domain == NSURLErrorDomain,
           [NSURLErrorCannotConnectToHost, NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorCannotFindHost, NSURLErrorNotConnectedToInternet].contains(nsError.code) {
            reach = .unreachable(host: inspector?.gatewayMachineName ?? String(localized: "the gateway"))
            return
        }
        reach = .failed(nsError.localizedDescription)
    }

    private func syncState(_ webView: WKWebView, loading: Bool) {
        isLoading = loading
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        if let title = webView.title, !title.isEmpty { pageTitle = title }
        if let url = webView.url, reach == .loaded || !loading {
            address = displayAddress(for: url)
        }
        inspector?.previewChanged(tabID: tabID, title: pageTitle)
    }

    /// The address as the person knows it: `localhost:5173/beta`, not the tailnet rewrite.
    private func displayAddress(for url: URL) -> String {
        if url.scheme == GatewayFileScheme.scheme { return target.displayURL }
        if target.isLocalhost, let loaded = loadedURL, url.host() == loaded.host(), url.port == loaded.port {
            var shown = "localhost" + (url.port.map { ":\($0)" } ?? "")
            if !url.path().isEmpty, url.path() != "/" { shown += url.path() }
            return shown
        }
        return PreviewTarget(url.absoluteString).displayURL
    }
}

/// The page's own touches and keys reach the app here (a weak hop, so the controller isn't
/// retained by the web view's content controller).
private final class PersonInput: NSObject, WKScriptMessageHandler {
    let onInput: () -> Void

    init(_ onInput: @escaping () -> Void) {
        self.onInput = onInput
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        onInput()
    }
}

/// Gateway files in a Preview (`hermes-fs://gateway/<path>`): HTML renders, and its relative
/// images, scripts and styles load the same way, through `/api/fs/download`.
///
/// A page reads only from the folders of the files opened in its tab, and nothing hidden below
/// them: its script can't fetch `~/.ssh` or another project's files and send them away.
final class GatewayFileScheme: NSObject, WKURLSchemeHandler {
    static let scheme = "hermes-fs"

    private let backend: BackendClient
    private let profile: String?
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var access = PreviewFileAccess()

    init(backend: BackendClient, profile: String?) {
        self.backend = backend
        self.profile = profile
    }

    static func url(for path: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "gateway"
        components.path = path.hasPrefix("/") ? path : "/" + path
        return components.url
    }

    /// The tab opened this file: its folder (and what's below it) can be read.
    func allowFolder(of url: URL) {
        access.allowFolder(ofFile: url.path(percentEncoded: false))
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else { return }
        let path = url.path(percentEncoded: false)
        guard url.host() == "gateway", access.allows(path) else {
            urlSchemeTask.didFailWithError(URLError(.noPermissionsToReadFile))
            return
        }
        let backend = backend
        let profile = profile
        let key = ObjectIdentifier(urlSchemeTask)
        let task = urlSchemeTask
        tasks[key] = Task { [weak self] in
            defer { self?.tasks[key] = nil }
            do {
                // The gateway follows symlinks, so where the path really leads (`read-text` says)
                // must stay inside the opened folder too (`PreviewFileAccess`). A small text file
                // comes whole with that answer; anything else is downloaded from where it leads.
                let text = try await backend.readText(path, profile: profile)
                guard !Task.isCancelled else { return }
                guard self?.access.allows(path, resolvedTo: text.path) == true else { throw URLError(.noPermissionsToReadFile) }
                let data: Data
                var type: String?
                if !text.binary, !text.truncated {
                    data = Data(text.text.utf8)
                    type = text.mimeType
                } else {
                    (data, type) = try await backend.downloadFile(text.path, profile: profile)
                }
                guard !Task.isCancelled else { return }
                let mime = type?.split(separator: ";").first.map(String.init).flatMap { $0 == "application/octet-stream" ? nil : $0 }
                    ?? Self.mimeType(for: path)
                task.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: mime.hasPrefix("text") ? "utf-8" : nil))
                task.didReceive(data)
                task.didFinish()
            } catch {
                guard !Task.isCancelled else { return }
                task.didFailWithError(error)
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        tasks.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.cancel()
    }

    static func mimeType(for path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "html", "htm": "text/html"
        case "css": "text/css"
        case "js", "mjs": "text/javascript"
        case "json": "application/json"
        case "svg": "image/svg+xml"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "webp": "image/webp"
        case "pdf": "application/pdf"
        case "txt", "md": "text/plain"
        default: "application/octet-stream"
        }
    }
}

/// Whether a gateway runs on this very machine (its localhost is ours).
enum GatewayHost {
    static func isThisMachine(_ host: String) -> Bool {
        if PreviewTarget.isLocalHost(host) { return true }
        #if os(macOS)
        let lowered = host.lowercased()
        let names = Host.current().names.map { $0.lowercased() }
        if names.contains(lowered) { return true }
        // A tailnet name starts with the machine's own name (`studio-mac.tail1234.ts.net`).
        let mine = ProcessInfo.processInfo.hostName.lowercased().split(separator: ".").first.map(String.init) ?? ""
        let theirs = lowered.split(separator: ".").first.map(String.init) ?? ""
        if !mine.isEmpty, mine == theirs { return true }
        return Host.current().addresses.contains(lowered)
        #else
        return false
        #endif
    }
}
