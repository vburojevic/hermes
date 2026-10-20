import SwiftUI

/// Getting Hermes Agent (`getHermes`): what it is, the install command with Copy, three steps,
/// and Send to My Mac / Scan Code. Spec: docs/onboarding.md §2.
struct GetHermesView: View {
    @Environment(WindowRouter.self) private var router: WindowRouter?
    @Environment(\.dismiss) private var dismiss

    /// From the Hermes Agent README (Quick Install: Linux, macOS, WSL2).
    static let installCommand = "curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash"
    static let site = URL(string: "https://hermes-agent.nousresearch.com")!

    private var deviceName: String {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad ? String(localized: "iPad") : String(localized: "iPhone")
        #else
        String(localized: "Mac")
        #endif
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Get Hermes Agent")
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(Theme.primaryText)
                    .accessibilityAddTraits(.isHeader)
                Text("Hermes runs on a computer you own: your Mac, a home server or a VPS. This app is how you talk to it from anywhere.")
                    .font(.body)
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
                InstallCard()
                    .padding(.top, 22)
                VStack(alignment: .leading, spacing: 0) {
                    WelcomeStepRow(number: 1, title: String(localized: "Install it"),
                                   detail: String(localized: "Run the command. It sets Hermes up and asks for a model key."))
                    #if os(macOS)
                    WelcomeStepRow(number: 2, title: String(localized: "Come back here"),
                                   detail: String(localized: "Hermes finds the agent running on this Mac. Connect, and you're in."))
                    WelcomeStepRow(number: 3, title: String(localized: "Or use another machine"),
                                   detail: String(localized: "On a server, use Connect to Another Gateway with its address and API key."))
                    #else
                    WelcomeStepRow(number: 2, title: String(localized: "Show a pairing code"),
                                   detail: String(localized: "In Hermes for Mac: Settings → Pair a Device. On a server, use Set Up Manually with its address and API key."))
                    WelcomeStepRow(number: 3, title: String(localized: "Scan it here"),
                                   detail: String(localized: "Your chats, Bots and tasks show up on this \(deviceName)."))
                    #endif
                }
                .padding(.top, 18)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 120)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.canvas)
        #if os(iOS)
        .toolbarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .safeAreaBar(edge: .bottom) { bottomBar }
        #else
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        #endif
    }

    #if os(iOS)
    /// Send to My Mac (the share sheet: AirDrop, Messages) and Scan Code.
    private var bottomBar: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                ShareLink(item: Self.shareText, subject: Text("Install Hermes Agent")) {
                    Label("Send to My Mac", systemImage: "square.and.arrow.up")
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .glassButton()
                if WelcomeActions.canScan {
                    Button {
                        router?.sheet = .scanner
                    } label: {
                        Label("Scan Code", systemImage: "qrcode.viewfinder")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .prominentGlassButton()
                } else {
                    Button {
                        router?.sheet = .addGateway
                    } label: {
                        Text("Set Up Manually")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .prominentGlassButton()
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
        .frame(maxWidth: 560)
    }
    #endif

    /// What Send to My Mac shares: the command and where it comes from.
    static var shareText: String {
        String(localized: "Install Hermes Agent on your Mac, Linux box or server:\n\n\(installCommand)\n\n\(site.absoluteString)")
    }
}

/// The install command with Copy, and where it runs (`installCard`).
struct InstallCard: View {
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("On a Mac, Linux box or server:")
                .font(.footnote.weight(.medium))
                .foregroundStyle(Theme.secondaryText)
            HStack(alignment: .center, spacing: 10) {
                Text(GetHermesView.installCommand)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(Theme.primaryText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    Pasteboard.copy(GetHermesView.installCommand)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        copied = false
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.secondaryText)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(copied ? "Copied" : "Copy Command")
            }
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .padding(.vertical, 10)
            .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
            Text("Hermes Agent is free and open source, by Nous Research. It runs on your machine; this app connects to it.")
                .font(.caption)
                .foregroundStyle(Theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// A numbered step (`stepRow`): ink number, title, detail.
struct WelcomeStepRow: View {
    let number: Int
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.footnote.weight(.bold))
                .foregroundStyle(Theme.inkForeground)
                .frame(width: 26, height: 26)
                .background(Theme.ink, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.primaryText)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Step \(number): \(title). \(detail)"))
    }
}
