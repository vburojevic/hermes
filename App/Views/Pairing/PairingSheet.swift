import HermesKit
import SwiftUI

/// A gateway's pairing QR code, so an iPhone or iPad can connect by scanning it.
struct PairingSheet: View {
    let botID: UUID

    @Environment(AppModel.self) private var app
    @Environment(WindowRouter.self) private var router: WindowRouter?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    /// Built once, off the main thread: the link (one Keychain read) and its QR grid.
    @State private var content: Content?
    @State private var isRevealed = false
    /// 0 while hidden, animating to 1 as the code resolves from its centre.
    @State private var reveal = 0.0
    @State private var appeared = false
    @AccessibilityFocusState private var focusesCode: Bool

    private struct Content {
        let link: PairingLink?
        let matrix: QRMatrix?
        /// The Bot Mode backend left out because only this machine can reach it.
        let localBackend: BackendLink?
    }

    private var bot: BotConfiguration? { app.bots.first { $0.id == botID } }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if let content {
                    if let link = content.link, let matrix = content.matrix {
                        header(instructions: true)
                            .padding(.bottom, 24)
                        code(matrix)
                        details(link, localBackend: content.localBackend)
                            .padding(.top, 22)
                    } else {
                        header(instructions: false)
                            .padding(.bottom, 12)
                        localOnly
                    }
                } else {
                    header(instructions: true)
                        .padding(.bottom, 24)
                    Spinner(size: .regular)
                        .frame(height: 272)
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 34)
            .padding(.bottom, 12)
            .frame(maxWidth: 440)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .prominentGlassButton()
                .padding(.top, 10)
                .padding(.bottom, 18)
                .frame(maxWidth: .infinity)
                .background(Theme.canvas)
        }
        .background(Theme.canvas)
        .task(id: botID) { await load() }
        // The code holds the API key: leaving the app (the switcher's snapshot, the Mac's
        // window behind others) hides it again.
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active, isRevealed else { return }
            isRevealed = false
            reveal = 0
        }
        .onAppear {
            withAnimation(reduceMotion ? nil : .spring(response: 0.7, dampingFraction: 0.78)) { appeared = true }
            #if DEBUG
            // `-HERMES_OPEN_PAIRING reveal` (or `reveal:0.4`, frozen mid-resolve) for screenshot
            // and scan tests.
            if let value = UserDefaults.standard.string(forKey: "HERMES_OPEN_PAIRING"), value.hasPrefix("reveal") {
                isRevealed = true
                reveal = Double(value.split(separator: ":").last ?? "") ?? 1
            }
            #endif
        }
    }

    private func load() async {
        let full = app.pairingLink(for: botID)
        let link = full?.forOtherDevices
        let text = link.flatMap { $0.isReachableFromOtherDevices ? $0.url.absoluteString : nil }
        let matrix = await Task.detached(priority: .userInitiated) { text.flatMap(QRMatrix.init) }.value
        let localBackend = full?.backend != nil && link?.backend == nil ? full?.backend : nil
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) {
            content = Content(link: matrix == nil ? nil : link, matrix: matrix, localBackend: localBackend)
        }
    }

    private func header(instructions: Bool) -> some View {
        VStack(spacing: 8) {
            Text("Pair a Device")
                .font(.title2.weight(.bold))
                .foregroundStyle(Theme.primaryText)
            if instructions {
                Text("Scan this code with the Camera app on your iPhone or iPad, or with Scan Pairing Code in Hermes.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func code(_ matrix: QRMatrix) -> some View {
        ZStack {
            Color.white
            PairingCodeView(matrix: matrix)
                .padding(6)
                .accessibilityHidden(!isRevealed)
                .accessibilityFocused($focusesCode)
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: 272)
        // Hidden, the code is a soft mosaic too coarse to scan; revealed, it resolves outwards
        // from the Hermes badge.
        .modifier(PairingRevealEffect(progress: reveal))
        .clipShape(.rect(cornerRadius: 30, style: .continuous))
        .overlay {
            if !isRevealed {
                Button(action: showCode) {
                    Label("Show Code", systemImage: "eye")
                        .font(.headline)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                }
                .glassButton()
                .environment(\.colorScheme, .light)
                .accessibilityHint("The code holds your API key. Show it when you're ready to scan.")
                .transition(reduceMotion ? .opacity : .scale(scale: 0.85).combined(with: .opacity))
            }
        }
        .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
        .scaleEffect(appeared ? 1 : 0.92)
        .opacity(appeared ? 1 : 0)
        .sensoryFeedback(.impact(weight: .light), trigger: isRevealed)
    }

    private func showCode() {
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.4, dampingFraction: 0.8)) {
            isRevealed = true
        }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.85)) {
            reveal = 1
        }
        focusesCode = true
    }

    private func details(_ link: PairingLink, localBackend: BackendLink?) -> some View {
        VStack(spacing: 10) {
            if let bot {
                HStack(spacing: 10) {
                    BotAvatar(bot: bot, size: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(bot.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.primaryText)
                        Text(bot.displayAddress)
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            if link.backend != nil {
                Label(link.backend?.signIn == .password ? "Bot Mode included · asks for the password" : "Bot Mode included", systemImage: "face.smiling")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
            } else if let localBackend {
                Label("Bot Mode stays on this device: its backend (\(localBackend.displayAddress)) is a local address.", systemImage: "face.dashed")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Anyone who scans this code can use your Hermes. Show it only to devices you own.")
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
    }

    private var localOnly: some View {
        VStack(spacing: 12) {
            Image(systemName: "network.slash")
                .font(.system(.largeTitle, weight: .light))
                .foregroundStyle(Theme.secondaryText)
                .padding(.bottom, 4)
            Text("Other devices can't reach this address")
                .font(.headline)
                .foregroundStyle(Theme.primaryText)
                .multilineTextAlignment(.center)
            Text("\(bot?.displayAddress ?? "This gateway") only works on this machine. Give the gateway an address your iPhone can reach, such as its Tailscale name or network address, then pair.")
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let bot, router != nil {
                Button("Edit Gateway…") {
                    router?.sheet = .editGateway(bot)
                }
                .glassButton()
                .padding(.top, 6)
            }
        }
        .padding(.vertical, 24)
    }
}
