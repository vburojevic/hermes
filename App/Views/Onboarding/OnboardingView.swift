import SwiftUI
#if os(iOS)
import VisionKit
#endif

/// First launch: what Hermes is, and connecting the first gateway.
struct OnboardingView: View {
    @Environment(AppModel.self) private var app
    @Environment(WindowRouter.self) private var router: WindowRouter?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .largeTitle) private var titleSize: CGFloat = 40
    @State private var appeared = false

    /// On an iPhone or iPad that can scan, pairing with the Mac is the quickest way in.
    private var scansFirst: Bool {
        #if os(iOS)
        DataScannerViewController.isSupported
        #else
        false
        #endif
    }

    var body: some View {
        ZStack {
            Theme.canvas.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 0) {
                    hero
                        .padding(.top, 72)
                    actions
                        .padding(.top, 44)
                        .modifier(Entrance(appeared: appeared, delay: 0.22, reduceMotion: reduceMotion))
                    Link(destination: URL(string: "https://hermes-agent.nousresearch.com/docs/user-guide/features/api-server")!) {
                        Text("How do I set up Hermes Agent?")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Theme.secondaryText)
                            .frame(minHeight: 44)
                    }
                    .padding(.top, 10)
                    .modifier(Entrance(appeared: appeared, delay: 0.3, reduceMotion: reduceMotion))
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .onAppear { appeared = true }
    }

    private var hero: some View {
        VStack(spacing: 22) {
            HermesMarkView()
                .frame(width: 88)
                .background {
                    // A slow, soft glow around the wing (the Bot aura shader, in white).
                    BotAura(color: .white, intensity: 0.32)
                        .frame(width: 260, height: 260)
                }
                .scaleEffect(appeared || reduceMotion ? 1 : 0.7)
                .opacity(appeared ? 1 : 0)
                .animation(reduceMotion ? .easeOut(duration: 0.3) : .spring(response: 0.8, dampingFraction: 0.72).delay(0.05), value: appeared)
            VStack(spacing: 10) {
                Text("Hermes")
                    .font(.system(size: titleSize, weight: .bold))
                    .foregroundStyle(Theme.primaryText)
                Text("Your own agent, in your pocket.\nConnect to a Hermes Agent gateway to chat, run tools and check on scheduled tasks.")
                    .font(.body)
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }
            .modifier(Entrance(appeared: appeared, delay: 0.12, reduceMotion: reduceMotion))
        }
    }

    private var actions: some View {
        GlassEffectContainer(spacing: 12) {
            VStack(spacing: 12) {
                if scansFirst {
                    scanButton(prominent: true)
                    manualButton(prominent: false)
                } else {
                    manualButton(prominent: true)
                    #if os(iOS)
                    scanButton(prominent: false)
                    #endif
                }
            }
        }
    }

    @ViewBuilder
    private func manualButton(prominent: Bool) -> some View {
        let label = Text(scansFirst ? "Set Up Manually" : "Connect Hermes")
            .font(.headline)
            .frame(maxWidth: 320, minHeight: 50)
        if prominent {
            Button { router?.sheet = .addGateway } label: { label }
                .prominentGlassButton()
        } else {
            Button { router?.sheet = .addGateway } label: { label }
                .glassButton()
        }
    }

    @ViewBuilder
    private func scanButton(prominent: Bool) -> some View {
        let label = Label("Scan Pairing Code", systemImage: "qrcode.viewfinder")
            .font(.headline)
            .frame(maxWidth: 320, minHeight: 50)
        if prominent {
            Button { router?.sheet = .scanner } label: { label }
                .prominentGlassButton()
        } else {
            Button { router?.sheet = .scanner } label: { label }
                .glassButton()
        }
    }
}

/// Fades and lifts a piece of the first screen in, a beat after the one before it.
private struct Entrance: ViewModifier {
    let appeared: Bool
    let delay: Double
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared || reduceMotion ? 0 : 14)
            .animation(
                reduceMotion ? .easeOut(duration: 0.3) : .spring(response: 0.7, dampingFraction: 0.85).delay(delay),
                value: appeared
            )
    }
}
