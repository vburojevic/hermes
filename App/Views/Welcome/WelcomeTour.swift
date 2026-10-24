import HermesKit
import SwiftUI
#if os(iOS)
import VisionKit
#endif

// The welcome tour (`screens/iphone/welcome.elyx`, `ipadWelcome`, `macWelcome`): four pages of
// what Hermes does, each shown with the app's own components in a demo state, and pairing one
// tap away on every page. Spec: docs/onboarding.md §1.

/// One page of the tour.
enum WelcomePage: Int, CaseIterable, Identifiable {
    case chat, bots, work, learns

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .chat: String(localized: "Your agent, on your phone.")
        case .bots: String(localized: "Bots that keep at it.")
        case .work: String(localized: "Hand it the work.")
        case .learns: String(localized: "It gets better with you.")
        }
    }

    var body: String {
        switch self {
        case .chat: String(localized: "Chat with the Hermes Agent running on your own machine. It asks before it does anything risky.")
        case .bots: String(localized: "Give a Bot a role and a schedule. It remembers, follows up, and works with the others.")
        case .work: String(localized: "Cards on a board, pages it builds, files it changes: all beside the chat, so you can watch and step in.")
        case .learns: String(localized: "Hermes writes skills for what you do often and remembers what matters. You can see and change all of it.")
        }
    }

    var next: WelcomePage? { WelcomePage(rawValue: rawValue + 1) }
}

// MARK: - Vignettes

/// A page's picture: real components in a fixed demo state. Decorative, so VoiceOver skips it
/// and nothing in it responds to touch.
struct WelcomeVignette: View {
    let page: WelcomePage
    /// The page is on screen: its motion runs only then.
    var isCurrent = true
    /// On a card beside the words (iPad, Mac): the Inspector pill hangs off the cards' edge.
    var onCard = false

    var body: some View {
        Group {
            switch page {
            case .chat: ChatVignette(onCard: onCard)
            case .bots: BotsVignette()
            case .work: WorkVignette(isCurrent: isCurrent, pillBeside: onCard)
            case .learns: LearnsVignette(isCurrent: isCurrent)
            }
        }
        // Each piece at its own height; the page clips what doesn't fit.
        .fixedSize(horizontal: false, vertical: true)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A message and the approval it leads to (`approvalAsk`).
private struct ChatVignette: View {
    var onCard = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 12) {
            UserBubble(entry: WelcomeDemo.question, images: [], fill: onCard ? Theme.canvas : Theme.surface)
            ApprovalCard(approval: WelcomeDemo.approval, onChoice: { _ in })
        }
    }
}

/// Three Bots and a message from one of them (`botMessageCard`). The faces blink by themselves.
private struct BotsVignette: View {
    var body: some View {
        VStack(spacing: 24) {
            HStack(alignment: .top, spacing: 0) {
                ForEach(WelcomeDemo.bots) { bot in
                    VStack(spacing: 10) {
                        BotFace(appearance: bot.appearance, size: 64)
                            .frame(height: 70)
                        Text(bot.name)
                            .font(.footnote)
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.top, 14)
            let researcher = WelcomeDemo.bots[1]
            BotMessageCard(appearance: researcher.appearance, name: researcher.name, handle: researcher.handle,
                           date: WelcomeDemo.digestTime, text: WelcomeDemo.digest)
        }
    }
}

/// Board cards (`kanbanCard`) with the Inspector pill over them. The running card's clock ticks.
private struct WorkVignette: View {
    let isCurrent: Bool
    var pillBeside = false
    @State private var board = WelcomeDemo.board()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 8) {
            ForEach(board.allCards) { card in
                BoardCardView(model: board, card: card, isSelected: card.column == "running")
            }
        }
        .overlay(alignment: pillBeside ? .trailing : .bottomTrailing) {
            InspectorPillLabel(symbol: "globe", title: "localhost:5173", isUsedByHermes: true, others: 3)
                .fixedSize()
                .alignmentGuide(.trailing) { pillBeside ? $0[.leading] : $0[.trailing] }
                .padding(.trailing, pillBeside ? 0 : 64)
                .padding(.bottom, pillBeside ? 0 : 26)
        }
        .task(id: isCurrent && !reduceMotion) {
            guard isCurrent, !reduceMotion else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                board.tickDemo(to: board.now.addingTimeInterval(1))
            }
        }
    }
}

/// The learning map (`learningMapCompact`) settling into place, and a memory note.
private struct LearnsVignette: View {
    let isCurrent: Bool
    @State private var learned = WelcomeDemo.learned()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            LearningMapView(model: learned, settles: isCurrent)
                .frame(height: 260)
            MemoryNotes(changes: [WelcomeDemo.memory], context: nil)
                .padding(.horizontal, 6)
        }
    }
}

// MARK: - Pieces

/// The tour's page dots (`pageDots`): the current page is a wider ink capsule.
struct WelcomePageDots: View {
    let current: WelcomePage

    var body: some View {
        HStack(spacing: 6) {
            ForEach(WelcomePage.allCases) { page in
                Capsule()
                    .fill(page == current ? Theme.ink : Theme.controlFill)
                    .frame(width: page == current ? 20 : 8, height: 8)
            }
        }
        .animation(.snappy(duration: 0.25), value: current)
        .accessibilityHidden(true)
    }
}

/// The wing and "Hermes".
struct WelcomeBrand: View {
    var size: CGFloat = 24

    var body: some View {
        HStack(spacing: 8) {
            HermesMarkView()
                .frame(width: size, height: size)
            Text("Hermes")
                .font(.headline.weight(.bold))
                .foregroundStyle(Theme.primaryText)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A page's words (`tourText`), read first: the title, then which page this is.
struct WelcomeWords: View {
    let page: WelcomePage
    var alignment: HorizontalAlignment = .center
    var titleFont: Font = .title.weight(.bold)

    var body: some View {
        VStack(alignment: alignment, spacing: 8) {
            Text(page.title)
                .font(titleFont)
                .foregroundStyle(Theme.primaryText)
                .accessibilityAddTraits(.isHeader)
                .accessibilityValue(Text("Page \(page.rawValue + 1) of \(WelcomePage.allCases.count)"))
            Text(page.body)
                .font(.body)
                .foregroundStyle(Theme.secondaryText)
        }
        .multilineTextAlignment(alignment == .center ? .center : .leading)
        .frame(maxWidth: .infinity, alignment: alignment == .center ? .center : .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Scan Pairing Code, Set Up Manually and "New to Hermes Agent? Get it", the same on every page.
/// Without a camera Set Up Manually is the only way in and takes the ink (`onboardingNoCamera`).
struct WelcomeActions: View {
    var width: CGFloat = 320
    var alignment: HorizontalAlignment = .center
    let getHermes: () -> Void
    @Environment(WindowRouter.self) private var router: WindowRouter?

    static var canScan: Bool {
        #if os(iOS)
        #if DEBUG
        // `-HERMES_HAS_CAMERA YES`: the camera variant on a simulator (screenshots).
        if UserDefaults.standard.bool(forKey: "HERMES_HAS_CAMERA") { return true }
        #endif
        return DataScannerViewController.isSupported
        #else
        return false
        #endif
    }

    var body: some View {
        VStack(alignment: alignment, spacing: 12) {
            GlassEffectContainer(spacing: 12) {
                VStack(spacing: 12) {
                    if Self.canScan {
                        Button { router?.sheet = .scanner } label: {
                            Label("Scan Pairing Code", systemImage: "qrcode.viewfinder")
                                .font(.headline)
                                .frame(maxWidth: width, minHeight: 50)
                        }
                        .prominentGlassButton()
                        Button { router?.sheet = .addGateway } label: {
                            Text("Set Up Manually")
                                .font(.headline)
                                .frame(maxWidth: width, minHeight: 50)
                        }
                        .glassButton()
                    } else {
                        Button { router?.sheet = .addGateway } label: {
                            Text("Set Up Manually")
                                .font(.headline)
                                .frame(maxWidth: width, minHeight: 50)
                        }
                        .prominentGlassButton()
                    }
                }
            }
            .frame(maxWidth: width)
            Button(action: getHermes) {
                HStack(spacing: 4) {
                    Text("New to Hermes Agent? Get it")
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                }
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("New to Hermes Agent? Get it")
        }
    }
}

// MARK: - Auto-advance

/// Moves to the next page every 6 s until the person touches the tour, stopping on the last
/// page. Off under Reduce Motion and while VoiceOver runs.
struct WelcomeAutoAdvance: ViewModifier {
    @Binding var page: WelcomePage
    @Binding var touched: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    private var runs: Bool { !touched && !reduceMotion && !voiceOver }

    func body(content: Content) -> some View {
        content
            .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in touched = true })
            .task(id: runs ? page.rawValue : -1) {
                guard runs, let next = page.next else { return }
                try? await Task.sleep(for: .seconds(6))
                guard !Task.isCancelled, runs else { return }
                withAnimation(.smooth(duration: 0.5)) { page = next }
            }
    }
}

extension View {
    func welcomeAutoAdvance(page: Binding<WelcomePage>, touched: Binding<Bool>) -> some View {
        modifier(WelcomeAutoAdvance(page: page, touched: touched))
    }
}

// MARK: - iPhone and iPad

#if os(iOS)
/// First launch with no gateway: the tour, then pairing. iPhone pages through vignette and words;
/// iPad shows the vignette on a card at the left and the words and actions at the right.
struct WelcomeTourView: View {
    @State private var page = WelcomePage.chat
    @State private var touched = false
    @State private var showsGetHermes = false
    @Environment(\.horizontalSizeClass) private var sizeClass

    init() {
        #if DEBUG
        // `-HERMES_WELCOME_PAGE 0…3|get` opens on that page and holds still, or on Get Hermes
        // Agent (screenshots).
        if let raw = UserDefaults.standard.string(forKey: "HERMES_WELCOME_PAGE") {
            _touched = State(initialValue: true)
            if let index = Int(raw), let start = WelcomePage(rawValue: index) { _page = State(initialValue: start) }
            if raw == "get" { _showsGetHermes = State(initialValue: true) }
        }
        #endif
    }

    var body: some View {
        NavigationStack {
            Group {
                if sizeClass == .regular {
                    split
                } else {
                    paged
                }
            }
            .background(Theme.canvas.ignoresSafeArea())
            .navigationDestination(isPresented: $showsGetHermes) {
                GetHermesView()
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    // iPhone (`welcomeChat` … `welcomeLearns`).
    private var paged: some View {
        GeometryReader { geometry in
            let vignetteHeight = min(380, max(240, geometry.size.height * 0.47))
            VStack(spacing: 0) {
                WelcomeBrand()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                TabView(selection: $page) {
                    ForEach(WelcomePage.allCases) { item in
                        VStack(spacing: 16) {
                            WelcomeVignette(page: item, isCurrent: item == page)
                                .frame(maxWidth: 362)
                                .frame(height: vignetteHeight, alignment: .top)
                                .clipped()
                                .overlay(alignment: .bottom) {
                                    LinearGradient(colors: [Theme.canvas.opacity(0), Theme.canvas], startPoint: .top, endPoint: .bottom)
                                        .frame(height: 82)
                                        .padding(.horizontal, -20)
                                }
                            WelcomeWords(page: item)
                                .frame(maxWidth: 354)
                                .padding(.top, 6)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 14)
                        .tag(item)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(maxHeight: .infinity)
                .welcomeAutoAdvance(page: $page, touched: $touched)
                WelcomePageDots(current: page)
                    .padding(.bottom, 32)
                WelcomeActions { showsGetHermes = true }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 4)
            }
            .frame(maxHeight: .infinity)
        }
    }

    // iPad (`ipadWelcome`).
    private var split: some View {
        HStack(spacing: 60) {
            TabView(selection: $page) {
                ForEach(WelcomePage.allCases) { item in
                    WelcomeVignette(page: item, isCurrent: item == page, onCard: true)
                        .frame(maxWidth: 380)
                        .padding(.leading, 25)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .tag(item)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 40, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 40, style: .continuous))
            .frame(maxWidth: 600, maxHeight: 730)
            .welcomeAutoAdvance(page: $page, touched: $touched)
            VStack(alignment: .leading, spacing: 0) {
                WelcomeBrand(size: 26)
                    .padding(.bottom, 26)
                WelcomeWords(page: page, alignment: .leading, titleFont: .largeTitle.weight(.bold))
                    .id(page)
                    .transition(.opacity)
                    .animation(.smooth(duration: 0.3), value: page)
                WelcomePageDots(current: page)
                    .padding(.top, 24)
                    .padding(.bottom, 26)
                WelcomeActions(width: 340, alignment: .leading) { showsGetHermes = true }
            }
            .frame(maxWidth: 440, alignment: .leading)
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
#endif
