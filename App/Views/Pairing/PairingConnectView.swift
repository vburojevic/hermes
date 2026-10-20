import HermesKit
import SwiftUI

/// Connects to a gateway from a pairing code or `hermesapp://connect` link: confirms first for
/// links from elsewhere, goes straight ahead for codes scanned in Hermes.
struct PairingConnectView: View {
    let link: PairingLink
    var connectsRightAway = false

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var password = ""
    @State private var phase = Phase.idle
    @State private var isUpdate = false
    @State private var connectTask: Task<Void, Never>?
    @State private var celebrations = 0
    @FocusState private var focusesPassword: Bool

    private enum Phase: Equatable {
        case idle
        case connecting(AppModel.PairingStep)
        case connected
        case failed(String, suggestion: String?, botModeFailed: Bool)
    }

    private var needsPassword: Bool { link.backend?.signIn == .password }
    private var isBusy: Bool { if case .connecting = phase { true } else { false } }

    /// `mac.tail0.ts.net:8642`
    /// The whole address, scheme included: whoever made the link chose the name, not this.
    private var address: String {
        var text = link.gateway.host() ?? link.gateway.absoluteString
        if let port = link.gateway.port { text += ":\(port)" }
        return (link.gateway.scheme.map { "\($0)://" } ?? "") + text
    }

    /// Plain http to an address on the internet: the key and every chat travel readable.
    private var isInsecureOverInternet: Bool { Self.isInsecureOverInternet(link) }

    static func isInsecureOverInternet(_ link: PairingLink) -> Bool {
        link.gateway.scheme?.lowercased() == "http" && !BotConfiguration.looksLocal(link.gateway.host() ?? "")
    }

    /// A saved gateway goes by this name at another address: the link may be passing for it.
    private var namesAnotherGateway: BotConfiguration? {
        guard !isUpdate else { return nil }
        return app.bots.first { $0.name.localizedCaseInsensitiveCompare(link.name) == .orderedSame && $0.baseURL != link.gateway }
    }

    init(link: PairingLink, connectsRightAway: Bool = false) {
        self.link = link
        self.connectsRightAway = connectsRightAway
        // A code scanned in Hermes opens already connecting, so the title doesn't flash a question.
        let startsConnecting = connectsRightAway && link.backend?.signIn != .password && !Self.isInsecureOverInternet(link)
        _phase = State(initialValue: startsConnecting ? .connecting(.gateway) : .idle)
    }

    var body: some View {
        // Centred when it fits; scrolls at large text sizes and in landscape.
        ViewThatFits(in: .vertical) {
            details
            ScrollView { details }
                .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxHeight: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            actions
        }
        .background(Theme.canvas)
        .animation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.4, dampingFraction: 0.85), value: phase)
        .sensoryFeedback(.success, trigger: celebrations)
        .onAppear {
            isUpdate = app.existingBot(for: link) != nil
            if needsPassword {
                focusesPassword = true
            } else if connectsRightAway {
                // A scanned code connects at once, unless there's a warning to read first.
                if isInsecureOverInternet || namesAnotherGateway != nil {
                    phase = .idle
                } else {
                    start(includingBotMode: true)
                }
            }
        }
        .onDisappear { connectTask?.cancel() }
        .onChange(of: phase) { _, new in
            switch new {
            case .failed(let message, _, _):
                AccessibilityNotification.Announcement(message).post()
            case .connected:
                AccessibilityNotification.Announcement(String(localized: "Connected")).post()
            default:
                break
            }
        }
    }

    private var details: some View {
            VStack(spacing: 0) {
                badge
                    .padding(.bottom, 24)
                Text(title)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.primaryText)
                    .id(title)
                    .transition(.blurReplace)
                Text(address)
                    .font(.subheadline.monospaced())
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.top, 6)

                VStack(spacing: 10) {
                    if isInsecureOverInternet {
                        warning("This address isn't encrypted and isn't on your network: the API key and your chats would travel readable. Connect only if you trust every network in between.")
                    }
                    if let saved = namesAnotherGateway {
                        warning("You already have a gateway called \(saved.name) at another address. Connect only if you made this code yourself.")
                    }
                    fact("Chats, tasks and skills from this gateway", symbol: "bubble.left.and.bubble.right")
                    if link.backend != nil {
                        fact("Bot Mode: your Bots, their chats and routines", symbol: "face.smiling")
                    }
                    fact("The API key is saved in this device's Keychain", symbol: "key")
                }
                .padding(.top, 22)

                if needsPassword {
                    SecureField("Bot Mode password", text: $password, prompt: Text("Password for \(link.backend?.username ?? "admin")"))
                        .textContentType(.password)
                        .focused($focusesPassword)
                        .padding(12)
                        .background(Theme.surface, in: .rect(cornerRadius: 12, style: .continuous))
                        .padding(.top, 18)
                        .onSubmit(connect)
                        .disabled(isBusy)
                }

                if case .failed(let message, let suggestion, _) = phase {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(Theme.danger)
                        if let suggestion {
                            Text(suggestion)
                                .font(.footnote)
                                .foregroundStyle(Theme.secondaryText)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 18)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 36)
            .padding(.bottom, 12)
            .frame(maxWidth: 440)
            .frame(maxWidth: .infinity)
    }

    private var title: String {
        switch phase {
        case .connected:
            String(localized: "Connected to \(link.name)")
        case .connecting:
            String(localized: "Connecting to \(link.name)…")
        default:
            isUpdate ? String(localized: "Update \(link.name)?") : String(localized: "Connect to \(link.name)?")
        }
    }

    /// The wing, turning into a check (with a burst) once connected.
    private var badge: some View {
        ZStack {
            Circle()
                .fill(phase == .connected ? Theme.success.opacity(0.2) : BotAccent.gold.color.opacity(0.18))
                .frame(width: 92, height: 92)
            if phase == .connected {
                Image(systemName: "checkmark")
                    .font(.system(size: 38, weight: .bold))
                    .foregroundStyle(Theme.success)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.3).combined(with: .opacity))
            } else {
                HermesMarkView(isAnimating: isBusy, color: Theme.primaryText)
                    .frame(width: 46)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.6).combined(with: .opacity))
            }
            SparkleBurst(color: Theme.success, trigger: celebrations, radius: 60)
        }
        .scaleEffect(phase == .connected && !reduceMotion ? 1.06 : 1)
        .accessibilityHidden(true)
    }

    private var actions: some View {
        VStack(spacing: 12) {
            if case .failed(_, _, true) = phase {
                Button("Connect Without Bot Mode") { connect(includingBotMode: false) }
                    .glassButton()
                    .controlSize(.large)
            }
            Button(action: { connect() }) {
                ZStack {
                    switch phase {
                    case .connecting(let step):
                        HStack(spacing: 10) {
                            Spinner()
                            Text(step == .gateway ? LocalizedStringKey("Checking the gateway…") : "Signing in to Bot Mode…")
                        }
                        .transition(.blurReplace)
                    case .connected:
                        Label("Connected", systemImage: "checkmark")
                            .transition(.blurReplace)
                    case .failed:
                        Text("Try Again")
                            .transition(.blurReplace)
                    case .idle:
                        Text(isUpdate ? "Update" : "Connect")
                            .transition(.blurReplace)
                    }
                }
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 30)
            }
            .keyboardShortcut(.defaultAction)
            .prominentGlassButton()
            .disabled(isBusy || phase == .connected || (needsPassword && password.isEmpty))

            Button("Cancel", role: .cancel) {
                connectTask?.cancel()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .buttonStyle(.plain)
            .foregroundStyle(Theme.secondaryText)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .disabled(phase == .connected)
        }
        .padding(.horizontal, 28)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .frame(maxWidth: 440)
        .frame(maxWidth: .infinity)
        .background(Theme.canvas)
    }

    private func warning(_ text: LocalizedStringKey) -> some View {
        Label {
            Text(text)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.warning)
                .frame(width: 26)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fact(_ text: LocalizedStringKey, symbol: String) -> some View {
        Label {
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(Theme.primaryText)
                .frame(width: 26) // symbols differ in width; keep the text aligned
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func connect() {
        connect(includingBotMode: true)
    }

    private func connect(includingBotMode: Bool) {
        guard !isBusy, phase != .connected, !(needsPassword && includingBotMode && password.isEmpty) else { return }
        start(includingBotMode: includingBotMode)
    }

    private func start(includingBotMode: Bool) {
        connectTask?.cancel()
        phase = .connecting(.gateway)
        connectTask = Task {
            do {
                let pairing = try await app.verifyPairing(link, password: password, includingBotMode: includingBotMode) { step in
                    phase = .connecting(step)
                }
                phase = .connected
                celebrations += 1
                // Celebrate first, then save: making the gateway current rebuilds the window behind
                // this sheet, which is fine once the burst has settled and the screen is still.
                try? await Task.sleep(for: .milliseconds(reduceMotion ? 450 : 950))
                do {
                    try app.save(pairing)
                } catch {
                    app.storageError = error.localizedDescription
                }
                dismiss()
            } catch is CancellationError {
            } catch let failure as AppModel.PairingFailure {
                guard !Task.isCancelled else { return }
                phase = describe(failure)
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed(BotRoster.describe(error), suggestion: nil, botModeFailed: false)
            }
        }
    }

    /// Says which part failed and what usually fixes it.
    private func describe(_ failure: AppModel.PairingFailure) -> Phase {
        let host = link.gateway.host() ?? "the gateway"
        switch failure.step {
        case .gateway:
            let error = (failure.underlying as? URLError).map { HermesError.from(urlError: $0, host: host) }
                ?? failure.underlying as? HermesError
            let message = error?.errorDescription ?? BotRoster.describe(failure.underlying)
            let suggestion = error?.recoverySuggestion
                ?? String(localized: "Make sure this device can reach \(host): the same network, or Tailscale on.")
            return .failed(message, suggestion: suggestion, botModeFailed: false)
        case .botMode:
            return .failed(
                String(localized: "Bot Mode: \(BotRoster.describe(failure.underlying))"),
                suggestion: needsPassword
                    ? String(localized: "Check the password, or connect without Bot Mode and sign in later.")
                    : String(localized: "Check that hermes serve is running, or connect without Bot Mode for now."),
                botModeFailed: true
            )
        }
    }
}
