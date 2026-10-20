import HermesKit
import SwiftUI

// Setup after pairing (`setupModel`, `setupYou`, `setupReady`): a model if the gateway has none,
// a little about the person, and places to start. Every step can be skipped. Spec:
// docs/onboarding.md §3.

/// A provider the model step offers (`model.options`).
struct SetupProvider: Identifiable, Hashable {
    let slug: String
    let name: String
    let authType: String
    let freeTier: Bool
    var id: String { slug }

    /// Saved with a key on the gateway (`model.save_key`); the rest sign in or run there.
    var takesKey: Bool { authType == "api_key" }
    var isNous: Bool { slug == "nous" }
    var isLocal: Bool { ["ollama", "lmstudio", "lm-studio", "llamacpp", "local", "custom"].contains(slug) }

    var symbol: String {
        if isNous { return "sparkles" }
        if isLocal { return "desktopcomputer" }
        switch slug {
        case "openrouter": return "arrow.triangle.branch"
        case "anthropic": return "text.bubble"
        case "openai", "openai-codex": return "circle.hexagongrid"
        case "gemini", "google": return "diamond"
        default: return "cpu"
        }
    }

    func detail(gateway: String) -> String {
        if isNous { return freeTier ? String(localized: "Free tier to start · sign in with Nous") : String(localized: "Sign in with Nous") }
        if isLocal { return String(localized: "Ollama or LM Studio, nothing leaves \(gateway)") }
        switch slug {
        case "openrouter": return String(localized: "One key, hundreds of models")
        case "anthropic": return String(localized: "Claude models")
        case "openai": return String(localized: "GPT models")
        case "gemini", "google": return String(localized: "Gemini models")
        default: return takesKey ? String(localized: "Add its API key") : String(localized: "Sign in on \(gateway)")
        }
    }
}

/// Where the last step can send the person (`startCard`), only what the gateway backs.
enum StartingPoint: Identifiable, Hashable {
    case project(root: String, label: String, sessions: Int)
    case bots(count: Int, lead: String?)
    case briefing
    case question(gateway: String)

    var id: String {
        switch self {
        case .project(let root, _, _): "project:\(root)"
        case .bots: "bots"
        case .briefing: "briefing"
        case .question: "question"
        }
    }

    var symbol: String {
        switch self {
        case .project: "folder"
        case .bots: "person.3"
        case .briefing: "sun.max"
        case .question: "bubble.left"
        }
    }

    var title: String {
        switch self {
        case .project(_, let label, _): String(localized: "Make \(label) a project")
        case .bots(let count, _): count == 1 ? String(localized: "Meet your Bot") : String(localized: "Meet your \(count) Bots")
        case .briefing: String(localized: "Get a morning briefing")
        case .question(let gateway): String(localized: "Ask about \(gateway)")
        }
    }

    var detail: String {
        switch self {
        case .project(let root, _, let sessions):
            String(localized: "Hermes has worked in \(Self.shortPath(root)) \(sessions) times")
        case .bots(_, let lead):
            lead.map { String(localized: "\($0) and the others are ready in Bot Mode") } ?? String(localized: "They're ready in Bot Mode")
        case .briefing: String(localized: "Weather, calendar and what needs you, at 07:30")
        case .question: "“\(StartingPoint.firstQuestion)”"
        }
    }

    static let firstQuestion = String(localized: "What’s using the most disk space?")

    /// `/Users/studio/Code/hermes-app` → `~/Code/hermes-app`.
    static func shortPath(_ path: String) -> String {
        let parts = path.split(separator: "/")
        if parts.count > 2, parts[0] == "Users" || parts[0] == "home" { return "~/" + parts.dropFirst(2).joined(separator: "/") }
        return path
    }
}

@MainActor
@Observable
final class SetupModel {
    enum Step: Int, CaseIterable { case model, you, ready }

    let workspace: BotWorkspace
    var step: Step = .model
    /// nil while checking the gateway.
    private(set) var needsModel: Bool?
    private(set) var providers: [SetupProvider] = []
    var selected: SetupProvider?
    var showsAllProviders = false
    var message: String?
    private(set) var isWorking = false

    var name: String
    var uses: [String] = []
    var savesToMemory = true

    private(set) var startingPoints: [StartingPoint]?

    static let useChoices = [
        String(localized: "Code"), String(localized: "My home server"), String(localized: "Research"),
        String(localized: "Writing"), String(localized: "Life admin"),
    ]

    init(workspace: BotWorkspace) {
        self.workspace = workspace
        name = WelcomeProgress.shared.name
    }

    var gatewayName: String { workspace.bot.name }
    private var profile: String? { workspace.bot.profileName }
    private var roster: BotRoster? { workspace.roster }

    private func params(_ extra: [String: JSONValue] = [:]) -> [String: JSONValue] {
        var params = extra
        if let profile { params["profile"] = .string(profile) }
        return params
    }

    // MARK: Model

    /// Asks the gateway whether it has a model (`setup.status`). Only Bot Mode speaks that
    /// protocol; without it the step is skipped.
    func checkModel() async {
        guard needsModel == nil else { return }
        for _ in 0..<40 where roster != nil && roster?.isConnected != true {
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard let roster, roster.isConnected,
              let status = try? await roster.request("setup.status", params()) else {
            needsModel = false
            if step == .model { step = .you }
            return
        }
        // `ready` says the gateway's boot check has settled; `provider_configured` whether a
        // model provider is set up.
        let configured = status["provider_configured"]?.boolValue ?? true
        let ready = status["ready"]?.boolValue ?? true
        needsModel = !configured || !ready
        if needsModel == true {
            await loadProviders()
        } else if step == .model {
            step = .you
        }
    }

    private func loadProviders() async {
        guard let roster, let options = try? await roster.request("model.options", params(["include_unconfigured": .bool(true)])) else { return }
        guard case .array(let list)? = options["providers"] else { return }
        let rows = list.compactMap { row -> SetupProvider? in
            guard let slug = row["slug"]?.stringValue, let name = row["name"]?.stringValue else { return nil }
            return SetupProvider(slug: slug, name: name, authType: row["auth_type"]?.stringValue ?? "api_key",
                                 freeTier: row["free_tier"]?.boolValue == true || row["free_tier_row"]?.boolValue == true)
        }
        // Nous Portal first when its free tier is there, then the usual first picks, then the rest.
        let preferred = ["openrouter", "anthropic", "openai", "gemini"]
        func rank(_ provider: SetupProvider) -> Int {
            if provider.isNous { return provider.freeTier ? -1 : preferred.count }
            if let index = preferred.firstIndex(of: provider.slug) { return index }
            return provider.isLocal ? preferred.count + 1 : preferred.count + 2
        }
        providers = rows.map { (rank: rank($0), provider: $0) }
            .sorted { ($0.rank, $0.provider.name) < ($1.rank, $1.provider.name) }
            .map(\.provider)
        selected = providers.first
    }

    var shownProviders: [SetupProvider] {
        if showsAllProviders { return providers }
        let firsts = providers.filter { !$0.isLocal }.prefix(3)
        let local = providers.first(where: \.isLocal).map { [$0] } ?? []
        return Array(firsts) + local
    }

    /// Nous Portal: the free tier if the gateway can mint it (`free_tier.provision`), else the
    /// Nous sign-in in the browser. True when the gateway now has a model.
    func setUpNous() async -> Bool {
        guard let roster else { return false }
        isWorking = true
        defer { isWorking = false }
        if selected?.freeTier == true,
           let result = try? await roster.request("free_tier.provision", params()),
           result["has_guest"]?.boolValue == true {
            return true
        }
        do {
            let flow = try await roster.startProviderSignIn(provider: "nous", profile: profile)
            Task { @MainActor in _ = await BrowserSignIn.shared.open(flow.url) }
            defer { BrowserSignIn.shared.cancel() }
            for _ in 0..<120 {
                try await Task.sleep(for: .seconds(max(flow.interval, 1)))
                let status = try await roster.pollProviderSignIn(provider: "nous", sessionID: flow.sessionID, profile: profile)
                if status == "approved" { return true }
                if status != "pending" { break }
            }
            message = String(localized: "The Nous sign-in didn't finish. Try again, or pick another provider.")
        } catch {
            message = error.localizedDescription
        }
        return false
    }

    /// Saves the key on the gateway (`model.save_key`). The key is only in memory here, never
    /// stored on the device or logged.
    func saveKey(_ key: String, for provider: SetupProvider) async -> Bool {
        guard let roster else { return false }
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try await roster.request("model.save_key", params(["slug": .string(provider.slug), "api_key": .string(key)]))
            return true
        } catch let error as GatewayRPCError {
            switch error.code {
            case 4003: message = String(localized: "\(provider.name) signs in on \(gatewayName): run hermes model there.")
            case 4006: message = String(localized: "\(gatewayName)'s keys are managed for it and can't be changed from here.")
            default: message = String(localized: "\(gatewayName) didn't take the key. Check it and try again.")
            }
        } catch {
            message = error.localizedDescription
        }
        return false
    }

    // MARK: About you

    /// "Remember that I'm Sam and I mostly use you for code and my home server." as the
    /// first message of a chat nobody opens; Hermes saves it with its memory tool. Nothing is
    /// sent with Save to Memory off.
    func saveAboutYou() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        WelcomeProgress.shared.name = trimmed
        guard savesToMemory, let sentence = aboutYouSentence else { return }
        workspace.sendInBackground(sentence)
        WelcomeProgress.shared.mark(.aboutYou)
    }

    var aboutYouSentence: String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let things = uses.map { $0.lowercased(with: .current) }
        let list = things.formatted(.list(type: .and))
        switch (trimmed.isEmpty, things.isEmpty) {
        case (false, false): return String(localized: "Remember that I'm \(trimmed) and I mostly use you for \(list).")
        case (false, true): return String(localized: "Remember that I'm \(trimmed).")
        case (true, false): return String(localized: "Remember that I mostly use you for \(list).")
        case (true, true): return nil
        }
    }

    func toggleUse(_ use: String) {
        if let index = uses.firstIndex(of: use) { uses.remove(at: index) } else { uses.append(use) }
    }

    // MARK: Starting points

    /// Up to four, each only when the gateway backs it.
    func loadStartingPoints() async {
        guard startingPoints == nil else { return }
        var points: [StartingPoint] = []
        // A folder Hermes has worked in often that isn't a project yet.
        for _ in 0..<12 where roster?.isConnected == true && !workspace.projects.isAvailable {
            try? await Task.sleep(for: .milliseconds(250))
        }
        await workspace.projects.loadDiscovered()
        if let repo = workspace.projects.suggestedRepos.filter({ $0.sessions >= 3 }).max(by: { $0.sessions < $1.sessions }) {
            points.append(.project(root: repo.root, label: repo.label, sessions: repo.sessions))
        }
        if let roster, roster.isConnected {
            let bots = roster.visibleBots.filter { !$0.isDefault }
            if !bots.isEmpty { points.append(.bots(count: bots.count, lead: bots.first?.title)) }
        }
        if let client = workspace.client, let jobs = try? await client.jobs(), jobs.isEmpty {
            points.append(.briefing)
        }
        points.append(.question(gateway: gatewayName))
        startingPoints = Array(points.prefix(4))
    }

    /// Goes where the card points. False if it couldn't (a project the gateway refused).
    func open(_ point: StartingPoint) async -> Bool {
        switch point {
        case .project(let root, let label, _):
            isWorking = true
            defer { isWorking = false }
            do {
                let project = try await workspace.projects.create(name: label, folders: [root], primary: root, appearance: ProjectAppearance())
                workspace.sidebarMode = .chats
                workspace.selection = .project(project.id)
                WelcomeProgress.shared.mark(.meetBots)
            } catch {
                message = error.localizedDescription
                return false
            }
        case .bots:
            workspace.sidebarMode = .bots
            workspace.selection = nil
        case .briefing:
            workspace.sidebarMode = .chats
            workspace.selection = .tasks
            workspace.pendingNewTask = .morningBriefing
        case .question:
            workspace.startChat(typing: StartingPoint.firstQuestion)
        }
        return true
    }
}

// MARK: - The flow

/// Setup after the first pairing, full screen on iPhone, a sheet on iPad and the Mac.
struct SetupFlowView: View {
    @State private var model: SetupModel
    /// Only the model step, from Settings → Setup → Models: done once a provider is saved.
    var modelOnly = false
    let onFinish: () -> Void

    init(workspace: BotWorkspace, startAt step: SetupModel.Step? = nil, modelOnly: Bool = false, onFinish: @escaping () -> Void) {
        let model = SetupModel(workspace: workspace)
        if let step { model.step = step }
        _model = State(initialValue: model)
        self.modelOnly = modelOnly
        self.onFinish = onFinish
    }

    var body: some View {
        NavigationStack {
            Group {
                switch model.step {
                case .model: SetupModelStep(model: model)
                case .you: SetupYouStep(model: model)
                case .ready: SetupReadyStep(model: model, onFinish: onFinish)
                }
            }
            .animation(.smooth(duration: 0.3), value: model.step)
            .background(Theme.groupedBackground.ignoresSafeArea())
            .toolbar(.hidden)
        }
        .task { await model.checkModel() }
        .onChange(of: model.step) {
            if modelOnly, model.step != .model { onFinish() }
        }
        .alert("Setup", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.message ?? "")
        }
    }
}

/// One bar per step, done in ink (`setupSteps`).
struct SetupStepBars: View {
    let step: SetupModel.Step

    var body: some View {
        HStack(spacing: 6) {
            ForEach(SetupModel.Step.allCases, id: \.self) { item in
                Capsule()
                    .fill(item.rawValue <= step.rawValue ? Theme.ink : Theme.controlFill)
                    .frame(height: 4)
            }
        }
        .frame(width: 200)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Step \(step.rawValue + 1) of \(SetupModel.Step.allCases.count)"))
    }
}

/// A step's frame: the bars, the title and words, the content, and the bottom buttons.
private struct SetupPage<Content: View, Buttons: View>: View {
    let step: SetupModel.Step
    let title: String
    let detail: String
    @ViewBuilder let content: Content
    @ViewBuilder let buttons: Buttons

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SetupStepBars(step: step)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 14)
                Text(title)
                    .font(.title.weight(.bold))
                    .foregroundStyle(Theme.primaryText)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.top, 40)
                Text(detail)
                    .font(.body)
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
                content
                    .padding(.top, 28)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 110)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaBar(edge: .bottom) {
            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 10) { buttons }
                    .font(.headline)
                    .buttonBorderShape(.capsule)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
            .frame(maxWidth: 560)
        }
    }
}

// MARK: Step 1: a model

private struct SetupModelStep: View {
    @Bindable var model: SetupModel
    @State private var keyFor: SetupProvider?

    var body: some View {
        SetupPage(
            step: .model,
            title: String(localized: "Hermes needs a model"),
            detail: String(localized: "\(model.gatewayName) doesn’t have a model provider yet. Pick one; you’ll add its key next, and it stays on \(model.gatewayName).")
        ) {
            if model.needsModel == nil || model.providers.isEmpty {
                SkeletonRows()
                    .padding(.top, 20)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    LearnedCard {
                        ForEach(model.shownProviders) { provider in
                            providerRow(provider)
                        }
                    }
                    if !model.showsAllProviders, model.providers.count > model.shownProviders.count {
                        Button("Show All Providers") { withAnimation { model.showsAllProviders = true } }
                            .font(.subheadline)
                            .foregroundStyle(Theme.secondaryText)
                            .padding(.horizontal, 16)
                    }
                }
            }
        } buttons: {
            Button { withAnimation { model.step = .you } } label: {
                Text("Later").frame(maxWidth: .infinity, minHeight: 50)
            }
            .glassButton()
            Button { Task { await continueTapped() } } label: {
                Group {
                    if model.isWorking { Spinner() } else { Text("Continue") }
                }
                .frame(maxWidth: .infinity, minHeight: 50)
            }
            .prominentGlassButton()
            .disabled(model.selected == nil || model.isWorking)
        }
        .navigationDestination(item: $keyFor) { provider in
            SetupKeyView(model: model, provider: provider) {
                keyFor = nil
                withAnimation { model.step = .you }
            }
        }
    }

    private func providerRow(_ provider: SetupProvider) -> some View {
        let isSelected = model.selected == provider
        return Button {
            model.selected = provider
        } label: {
            HStack(spacing: 12) {
                Image(systemName: provider.symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isSelected ? Theme.inkForeground : Theme.secondaryText)
                    .frame(width: 32, height: 32)
                    .background(isSelected ? Theme.ink : Theme.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.name)
                        .font(.body)
                        .foregroundStyle(Theme.primaryText)
                    Text(provider.detail(gateway: model.gatewayName))
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: isSelected ? "checkmark" : "chevron.right")
                    .font(.system(size: isSelected ? 15 : 12, weight: .semibold))
                    .foregroundStyle(isSelected ? Theme.primaryText : Theme.tertiaryText)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func continueTapped() async {
        guard let provider = model.selected else { return }
        if provider.isNous {
            if await model.setUpNous() { withAnimation { model.step = .you } }
        } else if provider.takesKey {
            keyFor = provider
        } else {
            model.message = provider.isLocal
                ? String(localized: "Set up a local model on \(model.gatewayName) with hermes model, then come back.")
                : String(localized: "\(provider.name) signs in on \(model.gatewayName): run hermes model there.")
        }
    }
}

/// A provider's key, saved on the gateway with `model.save_key`. Never kept on the device.
private struct SetupKeyView: View {
    let model: SetupModel
    let provider: SetupProvider
    let onSaved: () -> Void
    @State private var key = ""
    @FocusState private var focused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("\(provider.name) key")
                    .font(.title.weight(.bold))
                    .foregroundStyle(Theme.primaryText)
                    .accessibilityAddTraits(.isHeader)
                Text("Paste the API key from your \(provider.name) account. It’s saved on \(model.gatewayName), not on this device.")
                    .font(.body)
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
                SecureField("API key", text: $key)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .focused($focused)
                    .font(.body.monospaced())
                    .padding(.horizontal, 16)
                    .frame(minHeight: 50)
                    .background(Theme.groupedCell, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(.top, 28)
                    .onSubmit { Task { await save() } }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.groupedBackground)
        .toolbar(.visible)
        .safeAreaBar(edge: .bottom) {
            Button { Task { await save() } } label: {
                Group {
                    if model.isWorking { Spinner() } else { Text("Save Key") }
                }
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 50)
            }
            .prominentGlassButton()
            .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isWorking)
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
            .frame(maxWidth: 560)
        }
        .onAppear { focused = true }
        .onDisappear { key = "" }
    }

    private func save() async {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if await model.saveKey(trimmed, for: provider) {
            key = ""
            onSaved()
        }
    }
}

// MARK: Step 2: about you

private struct SetupYouStep: View {
    @Bindable var model: SetupModel
    @FocusState private var nameFocused: Bool

    var body: some View {
        SetupPage(
            step: .you,
            title: String(localized: "A little about you"),
            detail: String(localized: "So Hermes can get to the point. Skip it if you like.")
        ) {
            VStack(alignment: .leading, spacing: 8) {
                LearnedSectionTitle(title: String(localized: "What should Hermes call you?"))
                TextField("Your name", text: $model.name)
                    .textFieldStyle(.plain)
                    .textContentType(.givenName)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .focused($nameFocused)
                    .onSubmit { nameFocused = false }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 52)
                    .background(Theme.groupedCell, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                LearnedSectionTitle(title: String(localized: "Mostly for"))
                    .padding(.top, 14)
                FlowLayout(spacing: 8) {
                    ForEach(SetupModel.useChoices, id: \.self) { use in
                        Button {
                            model.toggleUse(use)
                        } label: {
                            ChipLabel(title: use, isActive: model.uses.contains(use))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(model.uses.contains(use) ? [.isButton, .isSelected] : .isButton)
                    }
                }
                .padding(.horizontal, 2)
                Toggle(isOn: $model.savesToMemory) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Save to Memory")
                            .font(.body)
                            .foregroundStyle(Theme.primaryText)
                        Text("Hermes will remember this in every chat")
                            .font(.footnote)
                            .foregroundStyle(Theme.secondaryText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .toggleStyle(.switch)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Theme.groupedCell, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                .padding(.top, 22)
                Text("You can see and change it later in Settings → Memory.")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.horizontal, 16)
            }
        } buttons: {
            Button { withAnimation { model.step = .ready } } label: {
                Text("Skip").frame(maxWidth: .infinity, minHeight: 50)
            }
            .glassButton()
            Button {
                model.saveAboutYou()
                withAnimation { model.step = .ready }
            } label: {
                Text("Continue").frame(maxWidth: .infinity, minHeight: 50)
            }
            .prominentGlassButton()
        }
    }
}

// MARK: Step 3: starting points

private struct SetupReadyStep: View {
    let model: SetupModel
    let onFinish: () -> Void

    private var title: String {
        let name = WelcomeProgress.shared.name
        return name.isEmpty ? String(localized: "You’re set") : String(localized: "You’re set, \(name)")
    }

    var body: some View {
        SetupPage(
            step: .ready,
            title: title,
            detail: String(localized: "Connected to \(model.gatewayName). Here are a few good places to start.")
        ) {
            if let points = model.startingPoints {
                VStack(spacing: 10) {
                    ForEach(points) { point in
                        Button {
                            Task {
                                if await model.open(point) { onFinish() }
                            }
                        } label: {
                            StartCard(point: point)
                        }
                        .buttonStyle(PressableStyle())
                        .disabled(model.isWorking)
                    }
                }
            } else {
                SkeletonRows()
                    .padding(.top, 20)
            }
        } buttons: {
            Button(action: onFinish) {
                Text("Start Chatting").frame(maxWidth: .infinity, minHeight: 50)
            }
            .prominentGlassButton()
        }
        .task { await model.loadStartingPoints() }
    }
}

/// A starting point (`startCard`): ink tile, title, why.
struct StartCard: View {
    let point: StartingPoint

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: point.symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Theme.inkForeground)
                .frame(width: 38, height: 38)
                .background(Theme.ink, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(point.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.primaryText)
                Text(point.detail)
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.tertiaryText)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Presenting

/// Setup over the window once the first gateway is paired: full screen on iPhone and iPad, a
/// sheet on the Mac. `-HERMES_SETUP model|you|ready` opens it on that step (screenshots).
struct SetupPresentation: ViewModifier {
    @Environment(AppModel.self) private var app

    private struct Target: Identifiable {
        let id: UUID
        var step: SetupModel.Step?
    }

    @State private var debugStep: SetupModel.Step?

    private var target: Binding<Target?> {
        Binding(
            get: { app.setupGatewayID.map { Target(id: $0, step: debugStep) } },
            set: { if $0 == nil { app.setupGatewayID = nil } }
        )
    }

    func body(content: Content) -> some View {
        content
            #if os(iOS)
            .fullScreenCover(item: target) { target in flow(target) }
            #else
            .sheet(item: target) { target in
                flow(target)
                    .frame(width: 560, height: 680)
            }
            #endif
            #if DEBUG
            .task {
                guard let raw = UserDefaults.standard.string(forKey: "HERMES_SETUP") else { return }
                try? await Task.sleep(for: .seconds(2))
                debugStep = ["model": .model, "you": .you, "ready": .ready][raw] ?? .model
                app.setupGatewayID = app.selectedBotID
            }
            #endif
    }

    @ViewBuilder
    private func flow(_ target: Target) -> some View {
        if let workspace = app.workspaces[target.id] {
            SetupFlowView(workspace: workspace, startAt: target.step) {
                app.setupGatewayID = nil
            }
        }
    }
}
