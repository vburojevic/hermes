#if os(macOS)
import AppKit
import HermesKit
import SwiftUI

// The Mac's welcome window (`macWelcome`): the tour at the left; at the right, Hermes Agent on
// this Mac if it's running, with Connect. Spec: docs/onboarding.md §6.

/// Hermes Agent on this Mac: its API server (`GET /v1/health`), its dashboard for Bot Mode, and
/// the API key in its `.env`.
@MainActor
@Observable
final class LocalGateway {
    enum State: Equatable {
        case looking
        case running(version: String?, botMode: Bool)
        case notRunning
    }

    private(set) var state = State.looking
    private(set) var isConnecting = false
    var message: String?

    /// `-HERMES_LOCAL_GATEWAY`, `-HERMES_LOCAL_BACKEND`, `-HERMES_LOCAL_HOME` point these at a
    /// mock gateway and a test folder (debug builds; never the real ~/.hermes in tests).
    let apiURL: URL
    let backendURL: URL
    let home: URL

    init() {
        let defaults = UserDefaults.standard
        func override(_ key: String) -> String? {
            #if DEBUG
            return defaults.string(forKey: key)
            #else
            return nil
            #endif
        }
        // The address, not `localhost`: that name may reach a listener on IPv6's ::1 first, which
        // anything can take when Hermes listens on IPv4 only.
        apiURL = override("HERMES_LOCAL_GATEWAY").flatMap(URL.init(string:)) ?? URL(string: "http://127.0.0.1:8642")!
        backendURL = override("HERMES_LOCAL_BACKEND").flatMap(URL.init(string:)) ?? URL(string: "http://127.0.0.1:\(BackendLink.defaultPort)")!
        home = override("HERMES_LOCAL_HOME").map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".hermes", directoryHint: .isDirectory)
    }

    /// "127.0.0.1:8642".
    var address: String {
        [apiURL.host(), apiURL.port.map(String.init)].compactMap { $0 }.joined(separator: ":")
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2.5
        configuration.timeoutIntervalForResource = 4
        return URLSession(configuration: configuration)
    }()

    /// Asks the API server whether it's up (unauthenticated), and the dashboard whether Bot Mode
    /// is there.
    func look() async {
        state = .looking
        guard let (data, response) = try? await Self.session.data(from: apiURL.appending(path: "v1/health")),
              (response as? HTTPURLResponse)?.statusCode == 200 else {
            state = .notRunning
            return
        }
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let version = json?["version"] as? String
        let botMode: Bool
        if let (_, status) = try? await Self.session.data(from: backendURL.appending(path: "api/status")),
           let code = (status as? HTTPURLResponse)?.statusCode {
            botMode = code < 500
        } else {
            botMode = false
        }
        state = .running(version: version, botMode: botMode)
    }

    /// Connects in one click: the key from Hermes's `.env` (`API_SERVER_KEY`), read only now that
    /// the person asked. The app isn't sandboxed (Developer ID), so it can read the folder
    /// directly; the key goes straight to the Keychain and never into a log. It's sent only when
    /// the process listening on the port is the one Hermes recorded (`LocalListener`): anything
    /// can answer `/v1/health`, and the key runs commands on this Mac.
    func connect(app: AppModel) async {
        guard case .running(_, let botMode) = state else { return }
        isConnecting = true
        defer { isConnecting = false }
        guard let pid = LocalListener.recordedPID(inHome: home), LocalListener.listens(pid: pid, port: apiURL.port ?? 80) else {
            message = String(localized: "Something other than Hermes Agent is answering on \(address). Quit it or restart Hermes Agent, then try again.")
            return
        }
        guard let key = Self.apiKey(in: home.appending(path: ".env")) else {
            message = String(localized: "Hermes Agent on this Mac has no API key yet. Set API_SERVER_KEY in ~/.hermes/.env, restart it, then try again.")
            return
        }
        let name = Host.current().localizedName ?? String(localized: "This Mac")
        let backend = botMode ? BackendLink(url: backendURL, signIn: .automatic) : nil
        do {
            // The same check as adding a gateway by hand: the key works, and this Hermes talks to apps.
            _ = try await AppModel.probe(baseURL: apiURL, apiKey: key)
            try app.addBot(name: name, baseURL: apiURL, apiKey: key, accent: .gold, backend: backend)
        } catch {
            message = (error as? HermesError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// `API_SERVER_KEY` from a dotenv file: `KEY=value`, `export KEY=value`, quoted or not.
    nonisolated static func apiKey(in file: URL) -> String? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard let equals = line.firstIndex(of: "="),
                  line[..<equals].trimmingCharacters(in: .whitespaces) == "API_SERVER_KEY" else { continue }
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if let quote = value.first, quote == "\"" || quote == "'", value.count >= 2, value.last == quote {
                value = String(value.dropFirst().dropLast())
            } else if let comment = value.range(of: " #") {
                value = String(value[..<comment.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
            return value.isEmpty ? nil : value
        }
        return nil
    }
}

/// The welcome window: the tour on a card at the left, the way in at the right.
struct MacWelcomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(WindowRouter.self) private var router: WindowRouter?
    @State private var local = LocalGateway()
    @State private var page = WelcomePage.work
    @State private var touched = false
    @State private var showsGetHermes = false

    var body: some View {
        HStack(spacing: 30) {
            tour
            wayIn
        }
        .padding(20)
        .frame(maxWidth: 940, maxHeight: 640)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
        .task { await local.look() }
        .sheet(isPresented: $showsGetHermes) {
            NavigationStack { GetHermesView() }
                .frame(width: 520, height: 600)
        }
        .alert("Couldn't Connect", isPresented: Binding(get: { local.message != nil }, set: { if !$0 { local.message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(local.message ?? "")
        }
    }

    private var tour: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 0)
            ZStack {
                ForEach(WelcomePage.allCases) { item in
                    if item == page {
                        WelcomeVignette(page: item, isCurrent: true, onCard: true)
                            .frame(width: 320)
                            .transition(.opacity)
                    }
                }
            }
            .frame(maxHeight: 420)
            .clipped()
            .animation(.smooth(duration: 0.4), value: page)
            HStack(spacing: 6) {
                ForEach(WelcomePage.allCases) { item in
                    Button {
                        touched = true
                        page = item
                    } label: {
                        Capsule()
                            .fill(item == page ? Theme.ink : Theme.controlFill)
                            .frame(width: item == page ? 20 : 8, height: 8)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Page \(item.rawValue + 1) of \(WelcomePage.allCases.count): \(item.title)"))
                }
            }
            .animation(.snappy(duration: 0.25), value: page)
            Spacer(minLength: 0)
        }
        .frame(width: 420)
        .frame(maxHeight: .infinity)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .welcomeAutoAdvance(page: $page, touched: $touched)
    }

    private var wayIn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                HermesMarkView()
                    .frame(width: 22, height: 22)
                Text("Hermes")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
            }
            .padding(.bottom, 18)
            Text("Welcome to Hermes")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(Theme.primaryText)
                .accessibilityAddTraits(.isHeader)
            Text("Chat with your own Hermes Agent, approve what it runs, hand it work and watch it happen, on your Mac, iPhone and iPad.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
            localCard
                .padding(.top, 18)
            HStack(spacing: 12) {
                Button("Connect to Another Gateway…") { router?.sheet = .addGateway }
                    .buttonBorderShape(.capsule)
                Button {
                    showsGetHermes = true
                } label: {
                    HStack(spacing: 4) {
                        Text("Get Hermes Agent")
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 16)
        }
        .frame(width: 400, alignment: .leading)
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private var localCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch local.state {
            case .looking:
                HStack(spacing: 10) {
                    Spinner()
                    Text("Looking for Hermes Agent on this Mac…")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondaryText)
                }
            case .running(let version, let botMode):
                HStack(alignment: .top, spacing: 10) {
                    Circle()
                        .fill(Theme.success)
                        .frame(width: 8, height: 8)
                        .padding(4)
                        .background(Theme.success.opacity(0.18), in: Circle())
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Hermes Agent is running on this Mac")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Theme.primaryText)
                        Text(runningDetail(version: version, botMode: botMode))
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
                Button {
                    Task { await local.connect(app: app) }
                } label: {
                    Text("Connect")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 22)
                }
                .inkDefaultButton()
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(local.isConnecting)
            case .notRunning:
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hermes Agent isn't running on this Mac")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.primaryText)
                    Text("Start it with hermes gateway, or get it below. A gateway on another machine works too.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Look Again") { Task { await local.look() } }
                    .buttonBorderShape(.capsule)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.sheetCell, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
        .animation(.smooth(duration: 0.25), value: local.state)
    }

    /// "Hermes 0.9.2 · 127.0.0.1:8642 · Bot Mode on".
    private func runningDetail(version: String?, botMode: Bool) -> String {
        [version.map { "Hermes \($0)" }, local.address, botMode ? String(localized: "Bot Mode on") : nil]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}
#endif
