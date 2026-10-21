import Foundation
import HermesKit
import Observation
import OSLog
import SwiftUI
import WebKit

/// The app as Hermes's browser for one chat (`docs/web.md` §6): a web view in the Inspector that
/// Hermes's browser tools drive, live, with Take Over and Hand Back, and the person's turn at a
/// sign-in page. It registers with the gateway for the chat's session before each turn: over Bot
/// Mode's socket (`browser.controller.*`, which Hermes allows only for a signed-in backend) or, for
/// a chat that runs on the API server, with the gateway's key (`/v1/browser-control/register`,
/// then the controller socket). What the person types in the page is never read or sent
/// (`BrowserControllerScript`).
@MainActor
@Observable
final class BrowserController: NSObject {
    enum State: Equatable {
        case off
        case connecting
        /// Hermes's browser tools for this chat come here.
        case attached
        /// The gateway said no; the reason says what would fix it.
        case refused(BrowserControlRefusal)
        /// The connection dropped; it comes back by itself.
        case reconnecting
    }

    enum Route: Equatable {
        /// Bot Mode's socket, with the chat's runtime session id.
        case socket(sessionID: String)
        /// The API server, with the chat's stored session id.
        case apiServer(sessionID: String)

        var sessionID: String {
            switch self {
            case .socket(let id), .apiServer(let id): id
            }
        }
    }

    private(set) var state = State.off
    /// The person took over: commands get Hermes's "a person has control" refusal instead of running.
    private(set) var personHasControl = false
    /// The page asks for a password or a one-time code: it's the person's turn (`signInYourselfBar`).
    private(set) var isSignInPage = false
    /// What Hermes is doing now, for `agentDrivingBar` ("Opening vercel.com").
    private(set) var currentStep: String?
    private(set) var stepCount = 0
    private(set) var lastActionAt: Date?
    private(set) var address = ""
    private(set) var pageTitle = ""
    private(set) var canGoBack = false
    private(set) var isLoading = false
    /// A page on this device's network that's waiting for the person (`Reach.asks`), and whether
    /// Hermes asked for it or the page itself went there.
    private(set) var asksForHost: String?
    private(set) var askedByHermes = false

    /// "vercel.com": the tab's title.
    var siteTitle: String? {
        guard let host = webViewStorage?.url?.host(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    @ObservationIgnored private weak var inspector: InspectorModel?
    @ObservationIgnored private var route: Route?
    @ObservationIgnored private var socketTask: URLSessionWebSocketTask?
    @ObservationIgnored private var receiving: Task<Void, Never>?
    @ObservationIgnored private var heartbeat: Task<Void, Never>?
    @ObservationIgnored private var reconnecting: Task<Void, Never>?
    @ObservationIgnored private var running: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var webViewStorage: WKWebView?
    @ObservationIgnored private var personObserver: ControllerPersonInput?
    @ObservationIgnored private var navigationWaiters: [CheckedContinuation<String?, Never>] = []
    @ObservationIgnored private var allowedHosts: Set<String> = []
    @ObservationIgnored private var askedURL: URL?
    /// The controller socket's heartbeat that proves it's open (`apiServer`): attached once it echoes.
    @ObservationIgnored private var awaitingNonce: String?
    @ObservationIgnored private var reconnectDelay: Double = 3
    /// Answers finished while the connection was down: sent once it's back (Hermes keeps waiting
    /// out each command's deadline meanwhile).
    @ObservationIgnored private var pendingResults: [BrowserCommandResult] = []

    private static let logger = Logger(subsystem: "co.caffeinatedcode.hermes", category: "browser")

    init(inspector: InspectorModel) {
        self.inspector = inspector
        super.init()
        Self.live.append(Weak(self))
    }

    // MARK: Every chat's browser

    private struct Weak {
        weak var controller: BrowserController?
        init(_ controller: BrowserController) { self.controller = controller }
    }

    private static var live: [Weak] = []

    /// The place changed, or the app is going to the background on iPhone or iPad: every chat
    /// (on one gateway, or all) gives the app's browser back.
    static func detachAll(gateway: UUID? = nil) {
        live.removeAll { $0.controller == nil }
        for entry in live {
            guard let controller = entry.controller else { continue }
            if gateway == nil || controller.inspector?.gatewayID == gateway { controller.detach() }
        }
    }

    // MARK: Identity

    /// This app's browser, the same on every launch so a reconnect refreshes its registration
    /// instead of replacing it. Not a secret: Hermes binds the identity to the key or the sign-in.
    static var controllerID: String {
        let key = "browserController.id"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = "hermes-app-" + UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    static let browserProfileID = "hermes-app"

    private static func storeKey(_ gateway: UUID) -> String { "browserController.store.\(gateway.uuidString)" }

    /// Each gateway's pages keep their own cookies and storage, apart from the Preview's.
    static func dataStoreID(gateway: UUID) -> UUID {
        if let text = UserDefaults.standard.string(forKey: storeKey(gateway)), let id = UUID(uuidString: text) { return id }
        let id = UUID()
        UserDefaults.standard.set(id.uuidString, forKey: storeKey(gateway))
        return id
    }

    /// Settings → Browser → Clear Browsing Data: every sign-in the app's browser kept for a gateway.
    /// The store stays (a web view may be using it); everything in it goes.
    static func clearData(gateway: UUID) async {
        guard let text = UserDefaults.standard.string(forKey: storeKey(gateway)), let id = UUID(uuidString: text) else { return }
        let store = WKWebsiteDataStore(forIdentifier: id)
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }

    /// The gateway is gone: its store goes with every site's cookies, and the key that named it.
    static func removeData(gateway: UUID) async {
        guard let text = UserDefaults.standard.string(forKey: storeKey(gateway)), let id = UUID(uuidString: text) else { return }
        UserDefaults.standard.removeObject(forKey: storeKey(gateway))
        try? await WKWebsiteDataStore.remove(forIdentifier: id)
    }

    // MARK: Attaching

    /// Registers as the chat's browser before a turn. Hermes ties the controller to the transport
    /// that registered it, and registering again with the same identity only refreshes that, so a
    /// Bot Mode chat registers before every turn. A newer attach or a detach while it waits wins.
    func attach(_ route: Route) {
        if route == self.route {
            switch state {
            case .connecting, .reconnecting:
                return
            case .attached:
                if case .socket = route { Task { await reregister() } }
                return
            case .off, .refused:
                break
            }
        }
        detach()
        self.route = route
        generation += 1
        let generation = generation
        state = .connecting
        Task { await connect(generation: generation) }
    }

    /// The chat attached again after Bot Mode reconnected (`session.resume`): the controller still
    /// belongs to the old socket, so it registers on this one. Another runtime id is another
    /// session: the next turn attaches that.
    func chatReattached(runtime: String) {
        guard case .socket(let sessionID)? = route else { return }
        if sessionID != runtime {
            detach()
        } else if state == .attached || state == .reconnecting {
            Task { await reregister() }
        }
    }

    private var isRefused: Bool {
        if case .refused = state { return true }
        return false
    }

    private func connect(generation: Int) async {
        guard let route, let conversation = inspector?.conversation else { return }
        do {
            switch route {
            case .socket(let sessionID):
                guard let roster = conversation.workspace?.roster else { throw BrowserControlRefusal.needsSignIn }
                try await register(sessionID, on: roster)
                guard generation == self.generation else {
                    // Given back while Hermes answered: say so, or each step would wait out its
                    // deadline here instead of using Hermes's own browser.
                    if self.route != route || state == .off { Self.sendDetach(sessionID, on: roster) }
                    return
                }
                markAttached(generation: generation)
            case .apiServer(let sessionID):
                guard let client = conversation.workspace?.client else { throw BrowserControlRefusal.other("no gateway") }
                let ticket = try await client.registerBrowserController(sessionID: sessionID, controllerID: Self.controllerID,
                                                                        browserProfileID: Self.browserProfileID)
                // A ticket left unused expires by itself (30 s).
                guard generation == self.generation, let task = client.browserControlSocket(ticket) else { return }
                socketTask = task
                task.resume()
                receiving = Task { [weak self] in await self?.receive(on: task, generation: generation) }
                // Attached once the socket answers this (`receive`): an upgrade Hermes refused never does.
                let nonce = UUID().uuidString
                awaitingNonce = nonce
                send(.object(["method": .string("browser.controller.heartbeat"), "params": .object(["nonce": .string(nonce)])]))
            }
        } catch let refusal as BrowserControlRefusal {
            guard generation == self.generation else { return }
            state = .refused(refusal)
            conversation.workspace?.inAppBrowser.refusal = refusal
        } catch {
            guard generation == self.generation else { return }
            Self.logger.notice("browser: register failed (\((error as NSError).domain, privacy: .public) \((error as NSError).code, privacy: .public))")
            scheduleReconnect(generation: generation)
        }
    }

    private func register(_ sessionID: String, on roster: BotRoster) async throws {
        do {
            _ = try await roster.request("browser.controller.register", [
                "session_id": .string(sessionID),
                "controller_id": .string(Self.controllerID),
                "browser_profile_id": .string(Self.browserProfileID),
                "capabilities": .array(BrowserControl.capabilities.map(JSONValue.string)),
                "protocol_version": .number(Double(BrowserControl.protocolVersion)),
            ], timeout: .seconds(20))
        } catch let error as GatewayRPCError {
            throw BrowserControlRefusal.from(rpc: error)
        }
    }

    /// Registers again on Bot Mode's socket, keeping what's on screen.
    private func reregister() async {
        guard case .socket(let sessionID)? = route, let conversation = inspector?.conversation,
              let roster = conversation.workspace?.roster else { return }
        let generation = generation
        do {
            try await register(sessionID, on: roster)
            guard generation == self.generation else { return }
            markAttached(generation: generation)
        } catch let refusal as BrowserControlRefusal {
            guard generation == self.generation else { return }
            state = .refused(refusal)
            conversation.workspace?.inAppBrowser.refusal = refusal
        } catch {
            guard generation == self.generation else { return }
            scheduleReconnect(generation: generation)
        }
    }

    private func markAttached(generation: Int) {
        if state != .attached { Self.logger.notice("browser: this app is the chat's browser") }
        state = .attached
        awaitingNonce = nil
        reconnectDelay = 3
        inspector?.conversation?.workspace?.inAppBrowser.refusal = nil
        startHeartbeat(generation: generation)
        let finished = pendingResults
        pendingResults = []
        for result in finished { Task { await deliver(result) } }
    }

    // TODO(docs/web.md §9): Hermes's own browser takes the chat's later steps after a detach; keep
    // them here if the gateway gets a "wait for the controller" option.
    /// Gives the chat's browser back (`browser.controller.detach`): another place was chosen, the
    /// app is going to the background on iPhone or iPad, or the chat is gone. Hermes cancels what
    /// was waiting, and the chat's later steps use its own browser. Also while a registration is
    /// still on its way, so one that lands after this doesn't stay behind.
    func detach(notify: Bool = true) {
        let wasLive = state == .attached || state == .connecting || state == .reconnecting
        generation += 1
        heartbeat?.cancel()
        reconnecting?.cancel()
        receiving?.cancel()
        heartbeat = nil
        reconnecting = nil
        receiving = nil
        for task in running.values { task.cancel() }
        running = [:]
        resumeWaiters(with: "The browser was given back.")
        if notify, wasLive, let route {
            Self.logger.notice("browser: giving the chat's browser back")
            switch route {
            case .socket(let sessionID):
                if let roster = inspector?.conversation?.workspace?.roster { Self.sendDetach(sessionID, on: roster) }
                socketTask?.cancel(with: .normalClosure, reason: nil)
            case .apiServer:
                let frame: JSONValue = .object(["method": .string("browser.controller.detach"), "params": .object([:])])
                if let task = socketTask, let text = try? String(decoding: JSONEncoder().encode(frame), as: UTF8.self) {
                    task.send(.string(text)) { _ in task.cancel(with: .normalClosure, reason: nil) }
                }
            }
        } else {
            socketTask?.cancel(with: .normalClosure, reason: nil)
        }
        socketTask = nil
        route = nil
        state = .off
        currentStep = nil
        personHasControl = false
        awaitingNonce = nil
        pendingResults = []
    }

    private static func sendDetach(_ sessionID: String, on roster: BotRoster) {
        Task { _ = try? await roster.request("browser.controller.detach", ["session_id": .string(sessionID)], timeout: .seconds(10)) }
    }

    /// Hermes says the controller isn't this connection's any more: another device took the chat's
    /// browser (Hermes keeps one per chat). It's not taken back until the next message here.
    private func lostToAnother() {
        Self.logger.notice("browser: the chat's browser is another device's now")
        detach(notify: false)
    }

    private func scheduleReconnect(generation: Int) {
        state = .reconnecting
        socketTask = nil
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, 60)
        reconnecting = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, generation == self.generation else { return }
            await self.connect(generation: generation)
        }
    }

    private func startHeartbeat(generation: Int) {
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled, let self, generation == self.generation else { return }
                await self.beat()
            }
        }
    }

    private func beat() async {
        switch route {
        case .socket(let sessionID)?:
            guard let roster = inspector?.conversation?.workspace?.roster else { return }
            do {
                _ = try await roster.request("browser.controller.heartbeat", ["session_id": .string(sessionID)], timeout: .seconds(10))
            } catch let error as GatewayRPCError where error.code == 4403 {
                lostToAnother()
            } catch {}
        case .apiServer?:
            send(.object(["method": .string("browser.controller.heartbeat"), "params": .object(["nonce": .string(UUID().uuidString)])]))
        case nil:
            break
        }
    }

    // MARK: Frames

    private func receive(on task: URLSessionWebSocketTask, generation: Int) async {
        while !Task.isCancelled {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await task.receive()
            } catch {
                guard generation == self.generation else { return }
                // The socket dropped, or Hermes refused the upgrade: register again, later each
                // time. Hermes keeps the commands' deadlines and holds cancels for the same identity.
                scheduleReconnect(generation: generation)
                return
            }
            let data: Data? = switch message {
            case .string(let text): Data(text.utf8)
            case .data(let data): data
            @unknown default: nil
            }
            guard let data, let json = try? JSONDecoder().decode(JSONValue.self, from: data) else { continue }
            receive(BrowserControlFrame(json: json))
        }
    }

    /// A frame from either transport (the backend socket's `event` arrives through the chat).
    func receive(_ frame: BrowserControlFrame) {
        switch frame {
        case .command(let command):
            guard state == .attached || state == .reconnecting else { return }
            running[command.commandID] = Task { [weak self] in
                guard let self else { return }
                let result = await self.answer(command)
                // Hermes stopped waiting (cancel, detach): it takes no answer.
                guard !Task.isCancelled else { return }
                self.running[command.commandID] = nil
                await self.deliver(result)
            }
        case .cancel(let commandID, _):
            // Hermes's cancel always names the command (`_cancel_frame`).
            guard let commandID, let task = running.removeValue(forKey: commandID) else { return }
            task.cancel()
            currentStep = nil
            // The person's own page load (their sign-in) isn't Hermes's to stop.
            guard !personHasControl else { return }
            resumeWaiters(with: "Stopped.")
            webViewStorage?.stopLoading()
        case .heartbeat(let nonce):
            if let awaitingNonce, nonce == awaitingNonce { markAttached(generation: generation) }
        case .detached:
            detach(notify: false)
        case .other:
            break
        }
    }

    private func deliver(_ result: BrowserCommandResult) async {
        switch route {
        case .socket(let sessionID)?:
            guard let roster = inspector?.conversation?.workspace?.roster else {
                pendingResults.append(result)
                return
            }
            var params = result.params
            params["session_id"] = .string(sessionID)
            do {
                _ = try await roster.request("browser.controller.result", params, timeout: .seconds(10))
            } catch let error as GatewayRPCError where error.code == 4403 {
                lostToAnother()
            } catch {
                pendingResults.append(result)
            }
        case .apiServer?:
            guard state == .attached, socketTask != nil else {
                pendingResults.append(result)
                return
            }
            send(result.frame)
        case nil:
            break
        }
    }

    private func send(_ frame: JSONValue) {
        guard let task = socketTask, let data = try? JSONEncoder().encode(frame) else { return }
        task.send(.string(String(decoding: data, as: UTF8.self))) { _ in }
    }

    // MARK: Commands

    /// Runs one command and answers within `BrowserControl.answerWithin` whatever the page does,
    /// so a stuck page fails here, cleanly, before Hermes's own deadline.
    private func answer(_ command: BrowserCommand) async -> BrowserCommandResult {
        // The first step of a run of them brings the tab up (also when the person holds the page, so
        // they see Hermes waiting); after that, a person who closed the Inspector or went to another
        // tab isn't pulled back on every step.
        if lastActionAt.map({ Date.now.timeIntervalSince($0) > 60 }) ?? true { inspector?.showBrowser() }
        lastActionAt = .now
        if personHasControl { return .success(command.commandID, BrowserControl.personHasControl) }
        stepCount += 1
        currentStep = BrowserCopyInApp.step(for: command)
        let late = BrowserCommandResult.success(command.commandID, Self.json(["success": .bool(false), "error": .string("The page didn't answer in time.")]))
        // The first of the work and the deadline answers; a script that never returns, or a
        // snapshot that never comes, is left behind.
        let (outcomes, finish) = AsyncStream.makeStream(of: BrowserCommandResult.self)
        let work = Task {
            finish.yield(await self.perform(command))
            finish.finish()
        }
        let deadline = Task {
            try? await Task.sleep(for: BrowserControl.answerWithin)
            finish.yield(late)
            finish.finish()
        }
        var iterator = outcomes.makeAsyncIterator()
        let result = await iterator.next() ?? late
        deadline.cancel()
        if result == late {
            work.cancel()
            if !personHasControl {
                resumeWaiters(with: "The page didn't answer in time.")
                webViewStorage?.stopLoading()
            }
        }
        currentStep = nil
        lastActionAt = .now
        return result
    }

    private func perform(_ command: BrowserCommand) async -> BrowserCommandResult {
        let id = command.commandID
        switch command.action {
        case "browser_navigate":
            return .success(id, await navigate(command.string("url") ?? ""))
        case "browser_back":
            guard let webView = webViewStorage, webView.canGoBack else {
                return .success(id, Self.json(["success": .bool(false), "error": .string("There's no page to go back to.")]))
            }
            webView.goBack()
            let failure = await waitForNavigation()
            return .success(id, page(failure: failure))
        case "browser_snapshot":
            let full = command.arguments["full"]?.boolValue ?? false
            return .success(id, await snapshot(full: full))
        case "browser_click":
            return .success(id, await call("click(\(Self.quoted(command.string("ref") ?? "")))"))
        case "browser_type":
            return .success(id, await call("type(\(Self.quoted(command.string("ref") ?? "")), \(Self.quoted(command.string("text") ?? "")))"))
        case "browser_scroll":
            return .success(id, await call("scroll(\(Self.quoted(command.string("direction") ?? "down")))"))
        case "browser_press":
            return .success(id, await call("press(\(Self.quoted(command.string("key") ?? "Enter")))"))
        case "browser_tabs":
            return .success(id, Self.json(["success": .bool(true), "tabs": .array([.object([
                "index": .number(0), "url": .string(webViewStorage?.url?.absoluteString ?? ""), "title": .string(pageTitle), "active": .bool(true),
            ])])]))
        case "browser_tab_activate":
            return .success(id, Self.json(["success": .bool(true), "index": .number(0)]))
        case "browser_screenshot":
            return .success(id, await screenshot())
        default:
            return .failure(id, "This app's browser can't do \(command.action).")
        }
    }

    private func navigate(_ raw: String) async -> String {
        let target = PreviewTarget(raw)
        guard let url = target.url, WebLink.isWeb(url) else {
            return Self.json(["success": .bool(false), "error": .string("Only http and https pages open in this app's browser.")])
        }
        if let host = await asksFirst(url) {
            ask(for: url, host: host, byHermes: true)
            return Self.json(["success": .bool(false), "error": .string("\(host) is on the person's own network. They need to open it in this app's browser first.")])
        }
        webView.load(URLRequest(url: url))
        let failure = await waitForNavigation()
        return page(failure: failure)
    }

    /// The page as Hermes's tools describe it after a navigation.
    private func page(failure: String?) -> String {
        if let failure { return Self.json(["success": .bool(false), "error": .string(failure)]) }
        return Self.json(["success": .bool(true), "url": .string(webViewStorage?.url?.absoluteString ?? ""), "title": .string(pageTitle),
                          "sign_in": .bool(isSignInPage)])
    }

    private func snapshot(full: Bool) async -> String {
        let text = await call("snapshot(\(full ? "true" : "false"))")
        if let signIn = Self.parse(text)?["sign_in"]?.boolValue { isSignInPage = signIn }
        return text
    }

    /// Runs a `__hermesControl` call in the scripts' own world, where the page can't reach.
    private func evaluate(_ expression: String) async throws -> Any? {
        try await webView.evaluateJavaScript(expression, in: nil, contentWorld: BrowserControllerScript.world)
    }

    private func call(_ expression: String) async -> String {
        do {
            let value = try await evaluate("window.__hermesControl ? window.__hermesControl.\(expression) : JSON.stringify({error: 'The page is still loading.'})")
            guard let text = value as? String else { return Self.json(["success": .bool(false), "error": .string("The page didn't answer.")]) }
            if let json = Self.parse(text), json["error"] != nil {
                if json["sign_in"]?.boolValue == true { isSignInPage = true }
                return Self.json(["success": .bool(false), "error": json["error"] ?? .string("")])
            }
            return text
        } catch {
            return Self.json(["success": .bool(false), "error": .string("The page didn't answer.")])
        }
    }

    private func screenshot() async -> String {
        guard let webView = webViewStorage else { return Self.json(["success": .bool(false), "error": .string("No page is open.")]) }
        // A field the person filled, or one that holds a secret, is never pictured.
        if (try? await evaluate("window.__hermesControl ? window.__hermesControl.showsWithheld() : true")) as? Bool != false {
            return Self.json(["success": .bool(false), "error": .string("The page shows something the person entered (a password, a card or a code), so this app's browser takes no screenshot of it now. Use browser_snapshot instead.")])
        }
        let configuration = WKSnapshotConfiguration()
        configuration.snapshotWidth = 800
        guard let image = try? await webView.takeSnapshot(configuration: configuration) else {
            return Self.json(["success": .bool(false), "error": .string("Couldn't take a screenshot.")])
        }
        #if os(macOS)
        let data = image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .jpeg, properties: [.compressionFactor: 0.6]) }
        #else
        let data = image.jpegData(compressionQuality: 0.6)
        #endif
        guard let data else { return Self.json(["success": .bool(false), "error": .string("Couldn't take a screenshot.")]) }
        return Self.json(["success": .bool(true), "mime_type": .string("image/jpeg"), "image_base64": .string(data.base64EncodedString())])
    }

    // MARK: The person

    func takeOver() {
        personHasControl = true
        currentStep = nil
    }

    /// The page may have changed while the person had it: read it again, so the bar knows whether
    /// it's still a sign-in page.
    func handBack() {
        personHasControl = false
        Task { _ = await snapshot(full: false) }
    }

    /// The person touched the page (in any frame): like the Preview, their own touch takes over.
    private func personTouchedPage() {
        if !personHasControl, state == .attached || state == .reconnecting { takeOver() }
    }

    // MARK: Pages on this device's network

    private func ask(for url: URL, host: String, byHermes: Bool) {
        asksForHost = host
        askedByHermes = byHermes
        askedURL = url
    }

    /// The person opened a page on their network that was asked for (`asksForHost`).
    func allowAskedHost() {
        guard let host = asksForHost else { return }
        allowedHosts.insert(host)
        asksForHost = nil
        if let url = askedURL { webView.load(URLRequest(url: url)) }
        askedURL = nil
    }

    /// The Preview's rule (`PreviewController.asksFirst`): the gateway itself opens, and so does
    /// loopback when the gateway is this machine; any other page on this device's network asks.
    private func asksFirst(_ url: URL) async -> String? {
        guard let host = url.host()?.lowercased() else { return nil }
        let gateway = inspector?.gatewayHost?.lowercased()
        if host == gateway || allowedHosts.contains(host) { return nil }
        if PreviewTarget.isLocalHost(host), let gateway, GatewayHost.isThisMachine(gateway) { return nil }
        if BotConfiguration.looksLocal(host) { return host }
        return await HostAddresses.resolvesLocal(host) ? host : nil
    }

    // MARK: The web view

    var webView: WKWebView {
        if let webViewStorage { return webViewStorage }
        let configuration = WKWebViewConfiguration()
        let controller = WKUserContentController()
        let world = BrowserControllerScript.world
        controller.addUserScript(WKUserScript(source: BrowserControllerScript.person, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world))
        controller.addUserScript(WKUserScript(source: BrowserControllerScript.control, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: world))
        let observer = ControllerPersonInput { [weak self] in self?.personTouchedPage() }
        controller.add(observer, contentWorld: world, name: "hermesPerson")
        personObserver = observer
        configuration.userContentController = controller
        if let gateway = inspector?.gatewayID {
            configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: Self.dataStoreID(gateway: gateway))
        }
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        #if DEBUG
        view.isInspectable = true
        #endif
        webViewStorage = view
        return view
    }

    /// The chat is gone: the browser is given back and the page closed.
    func tearDown() {
        detach()
        webViewStorage?.stopLoading()
        webViewStorage?.configuration.userContentController.removeAllScriptMessageHandlers()
        webViewStorage = nil
        resumeWaiters(with: "The browser closed.")
    }

    private func waitForNavigation() async -> String? {
        await withCheckedContinuation { continuation in
            navigationWaiters.append(continuation)
        }
    }

    private func resumeWaiters(with failure: String?) {
        let waiters = navigationWaiters
        navigationWaiters = []
        for waiter in waiters { waiter.resume(returning: failure) }
    }

    private func syncState(_ webView: WKWebView, loading: Bool) {
        isLoading = loading
        canGoBack = webView.canGoBack
        pageTitle = webView.title ?? ""
        address = webView.url.map { PreviewTarget($0.absoluteString).displayURL } ?? ""
    }

    // MARK: Helpers

    static func parse(_ text: String) -> JSONValue? {
        try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    static func json(_ object: [String: JSONValue]) -> String {
        (try? String(decoding: JSONEncoder().encode(JSONValue.object(object)), as: UTF8.self)) ?? "{}"
    }

    /// A JavaScript string literal (JSON is a subset).
    static func quoted(_ text: String) -> String {
        (try? String(decoding: JSONEncoder().encode(JSONValue.string(text)), as: UTF8.self)) ?? "\"\""
    }
}

extension BrowserController: WKNavigationDelegate {
    /// Like the Preview: a page on this device's network doesn't open without the person, and a
    /// frame that would reach it doesn't load.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .allow }
        guard WebLink.isWeb(url) || url.scheme == "about" else { return .cancel }
        guard let host = await asksFirst(url) else { return .allow }
        guard action.targetFrame?.isMainFrame ?? true else { return .cancel }
        // The page went there itself (a link, a redirect): Hermes didn't ask for it.
        ask(for: url, host: host, byHermes: false)
        return .cancel
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        syncState(webView, loading: true)
        isSignInPage = false
        asksForHost = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        syncState(webView, loading: false)
        Task {
            if let signIn = try? await webView.evaluateJavaScript("window.__hermesControl ? window.__hermesControl.signIn() : false",
                                                                  in: nil, contentWorld: BrowserControllerScript.world) as? Bool {
                // It's the person's turn: they need to see the page.
                if signIn, !isSignInPage, state == .attached { inspector?.showBrowser() }
                isSignInPage = signIn
            }
            resumeWaiters(with: nil)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        syncState(webView, loading: false)
        resumeWaiters(with: Self.describe(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        syncState(webView, loading: false)
        resumeWaiters(with: Self.describe(error))
    }

    private static func describe(_ error: any Error) -> String {
        let error = error as NSError
        if error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled { return "The page didn't open." }
        return "The page didn't load (\(error.domain) \(error.code))."
    }
}

extension BrowserController: WKUIDelegate {
    /// A link or script that opens a new window (target=_blank, a sign-in pop-up) opens here
    /// instead, through the same rules as any page.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, WebLink.isWeb(url) { webView.load(URLRequest(url: url)) }
        return nil
    }

    /// The camera and microphone are never the app's to give a page Hermes opened.
    func webView(_ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin, initiatedBy frame: WKFrameInfo,
                 type: WKMediaCaptureType) async -> WKPermissionDecision {
        .deny
    }
}

private final class ControllerPersonInput: NSObject, WKScriptMessageHandler {
    let onInput: @MainActor () -> Void

    init(onInput: @escaping @MainActor () -> Void) {
        self.onInput = onInput
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { onInput() }
    }
}

/// The steps the bar shows while Hermes drives the app's browser: never what it types.
enum BrowserCopyInApp {
    static func step(for command: BrowserCommand) -> String {
        switch command.action {
        case "browser_navigate":
            let site = command.string("url").flatMap { URLComponents(string: $0.contains("://") ? $0 : "https://" + $0)?.host } ?? ""
            return String(localized: "Opening \(site)")
        case "browser_snapshot": return String(localized: "Reading the page")
        case "browser_click": return String(localized: "Clicking")
        case "browser_type": return String(localized: "Typing")
        case "browser_scroll": return String(localized: "Scrolling")
        case "browser_press": return String(localized: "Pressing \(command.string("key") ?? "a key")")
        case "browser_back": return String(localized: "Going back")
        default: return String(localized: "Using the page")
        }
    }
}
