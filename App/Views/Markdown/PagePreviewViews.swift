import HermesKit
import HermesPush
import OSLog
import SwiftUI
import WebKit

/// A page a reply shows with `::preview{file="…"}` (`docs/chat.md` §3c): a card with the page's
/// title, its file and Open. In the newest reply Open shows the page live in the reply, sandboxed
/// (no network, no cookies or storage, an origin of its own), where its buttons can send Hermes a
/// message once the person allows it. In an older reply, or for a file that isn't a page, Open
/// shows it in the chat's Inspector.
struct PagePreviewCard: View {
    let directive: PreviewDirective
    /// The reply it's in (its turn's id).
    let owner: String
    /// The reply is still arriving: the file may still be being written, so nothing is read yet.
    let streaming: Bool

    @Environment(\.references) private var references
    @Environment(\.livePageReplies) private var livePageReplies
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var title: String?
    @State private var readFailed = false

    private var live: PagePreviewLive { PagePreviewLive.shared }

    private var location: ReferenceContext.GatewayPicture {
        guard references.isBotModeOn else { return .needsBotMode }
        let folder = references.conversation?.inspector.workingFolder ?? references.workspace?.projects.defaultFolder
        guard let path = directive.path(in: folder) else { return .unreadable }
        return .file(path: path, profile: references.conversation?.gatewayProfileForCheckpoints)
    }

    private var key: String? {
        if case .file(let path, let profile) = location { "\(owner)\u{0}\(path)\u{0}\(profile ?? "")" } else { nil }
    }

    /// Only a page in the newest reply, or one a page in it brought, opens live.
    private var opensLive: Bool {
        directive.isPage && livePageReplies.contains(owner) && references.conversation != nil && !readFailed
    }

    private var isOpen: Bool { key != nil && live.openKey == key && opensLive }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isOpen, case .file(let path, let profile) = location, let key {
                Rectangle().fill(Theme.hairline).frame(height: 0.5)
                LivePage(directive: directive, path: path, profile: profile, key: key,
                         onUnreadable: { readFailed = true; live.close(key) })
            }
        }
        .frame(maxWidth: isOpen ? CGFloat(PreviewDirective.maxWidth) : 480, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .task(id: streaming ? nil : key) { await readTitle() }
        .onChange(of: opensLive) { _, opens in
            // A message the person sent since: the page goes back to its card.
            if !opens, let key { live.close(key) }
        }
    }

    private var header: some View {
        Button(action: perform) {
            Group {
                if typeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) { glyph; words }
                        actionLabel
                    }
                } else {
                    HStack(spacing: 10) {
                        glyph
                        words
                        Spacer(minLength: 8)
                        actionLabel
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(action == .none)
        .contextMenu {
            if case .file(let path, _) = location {
                if opensLive {
                    Button(isOpen ? "Close" : "Open", systemImage: isOpen ? "xmark" : "play.rectangle") { perform() }
                }
                Button("Open in Preview Tab", systemImage: "sidebar.right") { references.openInInspector(path) }
                Button("Copy Path", systemImage: "square.on.square") { Pasteboard.copy(path) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([directive.isPage ? String(localized: "Page") : String(localized: "File"), title ?? directive.fileName, detail].joined(separator: ", "))
        .accessibilityHint(hint)
        .accessibilityAddTraits(action == .none ? [] : .isButton)
    }

    private var glyph: some View {
        Image(systemName: directive.isPage ? "macwindow" : "doc")
            .font(.system(size: 17, weight: .regular))
            .foregroundStyle(action == .none ? Theme.tertiaryText : Theme.primaryText)
            .frame(width: 36, height: 36)
            .background(Theme.controlFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .accessibilityHidden(true)
    }

    private var words: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: title ?? directive.fileName)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.primaryText)
                .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                .truncationMode(.tail)
            Text(detail)
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var actionLabel: some View {
        if action != .none {
            Text(isOpen ? String(localized: "Close") : String(localized: "Open"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.primaryText)
                .padding(.horizontal, 12)
                .frame(minHeight: 30)
                .background(Theme.controlFill, in: Capsule())
                .accessibilityHidden(true)
        }
    }

    private enum Action { case live, inspector, none }

    private var action: Action {
        guard !streaming, case .file = location else { return .none }
        return opensLive ? .live : .inspector
    }

    /// "board.html" below the page's title, the folder below a file's own name, or why it can't open.
    private var detail: String {
        switch location {
        case .needsBotMode: return String(localized: "Turn on Bot Mode to open it")
        case .unreadable: return String(localized: "This page's file can't be found")
        case .file(let path, _):
            let folder = (path as NSString).deletingLastPathComponent
            var parts = title == nil ? [(folder as NSString).lastPathComponent].filter { !$0.isEmpty && $0 != "/" } : [directive.fileName]
            if streaming {
                parts.append(String(localized: "opens when the reply is done"))
            } else if readFailed {
                parts.append(String(localized: "couldn't be read here"))
            }
            return parts.isEmpty ? directive.file : parts.joined(separator: " · ")
        }
    }

    private var hint: String {
        switch action {
        case .live: isOpen ? String(localized: "Closes the page") : String(localized: "Shows the page here")
        case .inspector: String(localized: "Opens in a Preview tab")
        case .none: ""
        }
    }

    private func perform() {
        guard case .file(let path, _) = location, let key else { return }
        switch action {
        case .live:
            if isOpen { live.close(key) } else { live.open(key) }
        case .inspector:
            references.openInInspector(path)
        case .none:
            break
        }
    }

    /// The page's title, read once per file and kept for the run: a card names its page, not its
    /// file, and scrolling back reads nothing again.
    private func readTitle() async {
        guard !streaming, directive.isPage, case .file(let path, let profile) = location,
              let client = references.roster?.boardClient else { return }
        let cacheKey = "\(path)\u{0}\(profile ?? "")"
        if let known = PagePreviewLive.shared.titles[cacheKey] {
            title = known
            return
        }
        guard let text = try? await client.readText(path, profile: profile), !text.binary else { return }
        let found = PageFrame.title(of: text.text)
        PagePreviewLive.shared.titles[cacheKey] = found
        title = found
    }
}

/// Which page is live: one at a time in the app, so a long chat never holds more than one web
/// page (`docs/chat.md` §3c). What the person allowed each page to do lasts while it is open.
@MainActor @Observable
final class PagePreviewLive {
    static let shared = PagePreviewLive()

    /// The card whose page is open: its reply, path and profile.
    private(set) var openKey: String?
    /// Page titles by path and profile, read once.
    @ObservationIgnored var titles: [String: String?] = [:]
    /// What the person said when the open page first asked to send a message.
    @ObservationIgnored var consent: [String: Bool] = [:]
    /// When the open page's last message went, in milliseconds.
    @ObservationIgnored var lastSent: [String: Double] = [:]

    func open(_ key: String) {
        if let openKey { forget(openKey) }
        openKey = key
    }

    func close(_ key: String) {
        guard openKey == key else { return }
        forget(key)
        openKey = nil
    }

    private func forget(_ key: String) {
        consent[key] = nil
        lastSent[key] = nil
    }
}

/// The open page: read from the gateway, framed in the app's look, and as tall as it measures
/// (`docs/chat.md` §3c). Off screen it lets its web page go and loads it again when it's back.
private struct LivePage: View {
    let directive: PreviewDirective
    let path: String
    let profile: String?
    let key: String
    let onUnreadable: () -> Void

    @Environment(\.references) private var references
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var html: String?
    @State private var height: Int
    @State private var onScreen = true
    @State private var asking: Ask?

    init(directive: PreviewDirective, path: String, profile: String?, key: String, onUnreadable: @escaping () -> Void) {
        self.directive = directive
        self.path = path
        self.profile = profile
        self.key = key
        self.onUnreadable = onUnreadable
        _height = State(initialValue: directive.startHeight)
    }

    /// The page asked to send a message the first time: the person says whether it may.
    struct Ask: Identifiable {
        let id = UUID()
        let prompt: String
        let answer: CheckedContinuation<Bool, Never>
    }

    var body: some View {
        Group {
            if let html, onScreen {
                PageWebView(html: framed(html), onHeight: resize, onSend: send)
                    .accessibilityLabel(Text("Page, \(directive.fileName)"))
            } else {
                // Its space kept, quiet, while it loads or is off screen.
                Color.clear
                    .accessibilityHidden(true)
            }
        }
        .frame(height: CGFloat(height))
        .frame(maxWidth: .infinity)
        .onScrollVisibilityChange(threshold: 0.01) { visible in
            onScreen = visible
        }
        .task(id: key) { await read() }
        .alert(String(localized: "Let this page send messages?"), isPresented: Binding(get: { asking != nil }, set: { if !$0 { answer(false) } }),
               presenting: asking) { _ in
            Button("Don't Allow", role: .cancel) { answer(false) }
            Button("Allow") { answer(true) }
        } message: { ask in
            Text("“\(directive.fileName)” wants to send Hermes “\(VisibleText.of(ask.prompt))”. Its messages go as yours and don't show in the chat.")
        }
        .onDisappear {
            // A consent still asked is refused: the page is gone.
            answer(false)
        }
    }

    private func read() async {
        guard let client = references.roster?.boardClient,
              let text = try? await client.readText(path, profile: profile),
              !text.binary, !text.truncated else {
            onUnreadable()
            return
        }
        html = text.text
    }

    private func framed(_ html: String) -> String {
        let dark = colorScheme == .dark
        let highContrast = contrast == .increased
        func hex(_ color: Color) -> String { DrawnBlockRenderer.Look.hex(color, dark: dark, highContrast: highContrast) }
        let prelude = PageFrame.prelude(dark: dark, variables: [
            ("--foreground", hex(Theme.primaryText)), ("--muted-foreground", hex(Theme.tertiaryText)),
            ("--accent", hex(Theme.link)), ("--border", hex(Theme.hairline)), ("--card", hex(Theme.surface)),
        ], font: "-apple-system,system-ui,sans-serif")
        let head = html.range(of: "name=\"viewport\"", options: .caseInsensitive) == nil
            ? "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">" : ""
        return PageFrame.assemble(html, prelude: head + prelude)
    }

    private func resize(_ measured: Double) {
        guard let next = PreviewDirective.measured(measured), abs(next - height) > PreviewDirective.resizeTolerance else { return }
        height = next
    }

    private func send(_ prompt: Any?) async -> [String: JSONValue] {
        let live = PagePreviewLive.shared
        guard live.openKey == key else { return PageIntent.ack(.undelivered) }
        let now = Date.now.timeIntervalSince1970 * 1000
        switch PageIntent.evaluate(prompt, now: now, lastAccepted: live.lastSent[key]) {
        case .reject(let refusal):
            return PageIntent.ack(refusal)
        case .accept(let text):
            if live.consent[key] == nil {
                guard asking == nil else { return PageIntent.ack(.throttled(retryAfterMilliseconds: PageIntent.throttleMilliseconds)) }
                let allowed = await withCheckedContinuation { continuation in
                    asking = Ask(prompt: text, answer: continuation)
                }
                guard live.openKey == key else { return PageIntent.ack(.undelivered) }
                live.consent[key] = allowed
            }
            guard live.consent[key] == true else { return PageIntent.ack(.declined) }
            guard references.conversation?.sendFromPage(text) == true else { return PageIntent.ack(.undelivered) }
            live.lastSent[key] = Date.now.timeIntervalSince1970 * 1000
            return PageIntent.ack(nil)
        }
    }

    private func answer(_ allowed: Bool) {
        guard let ask = asking else { return }
        asking = nil
        ask.answer.resume(returning: allowed)
    }
}

/// The page's own web view: a data store that keeps nothing, an origin of its own that never
/// resolves, a policy (sent as the response's header) that lets nothing load from anywhere, and
/// every navigation cancelled but its own load; links the person taps open in the browser. The
/// page can say how tall it is and `hermes.send` a sentence, and nothing else.
private struct PageWebView {
    let html: String
    let onHeight: (Double) -> Void
    let onSend: (Any?) async -> [String: JSONValue]

    static let policy = "default-src 'none'; img-src data: blob:; media-src data: blob:; style-src 'unsafe-inline' data:; script-src 'unsafe-inline'; font-src data:; frame-src 'none'; form-action 'none'"

    /// Reports the page's height: its body's, so a short page can shrink below its frame.
    static let measure = """
    (function(){var last=0;function post(){var b=document.body,d=document.documentElement;\
    var h=b?Math.max(b.scrollHeight,b.offsetHeight,Math.ceil(b.getBoundingClientRect().height)):(d?d.scrollHeight:0);\
    if(Math.abs(h-last)>1){last=h;window.webkit.messageHandlers.hermesSize.postMessage(h)}}\
    if(typeof ResizeObserver==="function"){var ro=new ResizeObserver(post);ro.observe(document.documentElement);if(document.body)ro.observe(document.body)}\
    addEventListener("load",post);post()})()
    """

    /// `hermes.send(prompt)` and `data-hermes-send`, as Hermes Desktop gives a page: a Promise of
    /// `{ok: true}` or why not.
    static let intents = """
    (function(){var h=window.webkit.messageHandlers.hermesPage;\
    function send(p){if(typeof p!=="string"||!p.trim())return Promise.resolve({ok:false,error:"invalid"});\
    return h.postMessage({prompt:p}).catch(function(){return {ok:false,error:"undelivered"}})}\
    Object.defineProperty(window,"hermes",{value:Object.freeze({send:send,maxLength:\(PageIntent.maxLength)}),writable:false,configurable:false});\
    addEventListener("click",function(e){var el=e.target&&e.target.closest?e.target.closest("[data-hermes-send]"):null;\
    if(el)send(el.getAttribute("data-hermes-send")||"")},true)})()
    """

    func makeWebView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        // The policy says nothing of calls (WebRTC), which would reach the network: Lockdown Mode
        // turns them off for this page, with the parts of WebKit a small page has no use for.
        configuration.defaultWebpagePreferences.isLockdownModeEnabled = true
        let controller = configuration.userContentController
        let relay = Relay(coordinator: context.coordinator)
        controller.add(relay, contentWorld: .page, name: "hermesSize")
        controller.addScriptMessageHandler(relay, contentWorld: .page, name: "hermesPage")
        controller.addUserScript(WKUserScript(source: Self.intents, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        controller.addUserScript(WKUserScript(source: Self.measure, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .page))
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        #if os(macOS)
        view.setValue(false, forKey: "drawsBackground")
        #else
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.bounces = false
        #endif
        context.coordinator.parent = self
        load(view, context: context)
        return view
    }

    func load(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self
        guard context.coordinator.loaded != html else { return }
        context.coordinator.loaded = html
        let headers = ["Content-Type": "text/html; charset=utf-8", "Content-Security-Policy": Self.policy]
        let origin = context.coordinator.origin
        guard let response = HTTPURLResponse(url: origin, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers) else { return }
        context.coordinator.expectsLoad = true
        view.loadSimulatedRequest(URLRequest(url: origin), response: response, responseData: Data(html.utf8))
    }

    static func dismantle(_ view: WKWebView) {
        let controller = view.configuration.userContentController
        controller.removeAllScriptMessageHandlers()
        controller.removeAllUserScripts()
        view.navigationDelegate = nil
        view.uiDelegate = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: PageWebView?
        var loaded: String?
        var expectsLoad = false
        /// An origin of its own for each page shown: nothing of one page is another's.
        let origin = URL(string: "https://page-\(UUID().uuidString.prefix(8).lowercased()).hermes.invalid/")!

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            let url = action.request.url
            if action.targetFrame?.isMainFrame ?? true {
                if expectsLoad, url == origin {
                    expectsLoad = false
                    return .allow
                }
                if let url, url.fragment() != nil, url.host() == origin.host(), url.path() == origin.path() {
                    return .allow
                }
            }
            if action.navigationType == .linkActivated, let url, WebLink.isWeb(url), url.host() != origin.host() {
                #if os(macOS)
                NSWorkspace.shared.open(url)
                #else
                await UIApplication.shared.open(url)
                #endif
            }
            return .cancel
        }

        /// A page never gets the camera or the microphone, and the person is never asked.
        func webView(_ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin, initiatedBy frame: WKFrameInfo,
                     type: WKMediaCaptureType) async -> WKPermissionDecision {
            .deny
        }

        func height(_ body: Any) {
            guard let value = body as? Double else { return }
            parent?.onHeight(value)
        }

        func send(_ body: Any) async -> [String: JSONValue] {
            guard let parent else { return PageIntent.ack(.undelivered) }
            return await parent.onSend((body as? [String: Any])?["prompt"])
        }
    }

    /// The handlers the page talks to, holding the coordinator weakly: the content controller
    /// keeps its handlers, and the coordinator keeps the page.
    final class Relay: NSObject, WKScriptMessageHandler, WKScriptMessageHandlerWithReply {
        weak var coordinator: Coordinator?

        init(coordinator: Coordinator) {
            self.coordinator = coordinator
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            coordinator?.height(message.body)
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
            guard let coordinator else { return (Self.plain(PageIntent.ack(.undelivered)), nil) }
            return (Self.plain(await coordinator.send(message.body)), nil)
        }

        /// The ack as the page reads it.
        static func plain(_ ack: [String: JSONValue]) -> [String: Any] {
            ack.compactMapValues { value -> Any? in
                switch value {
                case .bool(let flag): flag
                case .number(let number): number
                case .string(let text): text
                default: nil
                }
            }
        }
    }
}

#if os(macOS)
extension PageWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { makeWebView(context: context) }
    func updateNSView(_ view: WKWebView, context: Context) { load(view, context: context) }
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) { dismantle(view) }
}
#else
extension PageWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makeWebView(context: context) }
    func updateUIView(_ view: WKWebView, context: Context) { load(view, context: context) }
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) { dismantle(view) }
}
#endif

extension EnvironmentValues {
    /// The replies whose pages may open live: the newest, and any a page in it brought, since the
    /// person's last message (`docs/chat.md` §3c).
    @Entry var livePageReplies: Set<String> = []
}
