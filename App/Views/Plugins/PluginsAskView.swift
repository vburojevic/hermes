import HermesKit
import SwiftUI

/// The one ask (`pluginsAsk`, `macPluginsAsk`, `docs/plugins.md` §3.3): once per gateway on this
/// device, after Bot Mode first connects and setup is done. Every app plugin missing or older
/// there, each with a switch (on), each row opening its review; Install on <gateway> puts the
/// ones switched on in Hermes and every Bot. Not Now keeps them in Suggested. Afterwards
/// (`pluginsAskDone`) where they're on, and Restart Gateway / Later when push went into the root.
struct PluginsAskSheet: View {
    let workspace: BotWorkspace
    @Environment(\.dismiss) private var dismiss
    /// What the ask lists, as it was when it opened: installing changes what's missing.
    @State private var listed: [AppPlugin] = []
    @State private var chosen: Set<String> = []
    @State private var started = false

    private var model: AppPluginsModel { workspace.plugins }
    private var gateway: String { workspace.bot.name }
    private var isInstalling: Bool { started && !model.installing.isEmpty }
    private var run: AppPluginsModel.Run? { started && model.installing.isEmpty ? model.lastRun : nil }

    var body: some View {
        NavigationStack {
            Group {
                if let run {
                    PluginsAskDone(workspace: workspace, run: run, retry: install, close: close)
                } else {
                    ask
                }
            }
            .navigationDestination(for: AskPage.self) { page in
                switch page {
                case .review(let name):
                    if let plugin = AppPlugin.named(name) {
                        AppPluginReviewView(workspace: workspace, plugin: plugin, readOnly: true)
                    }
                case .profiles:
                    InstallsIntoList(workspace: workspace)
                }
            }
            #if os(iOS)
            .toolbar {
                if run == nil {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "Not Now"), systemImage: "xmark") { close() }
                    }
                }
            }
            #endif
        }
        .onAppear {
            guard listed.isEmpty else { return }
            listed = model.askable.isEmpty ? AppPlugin.all.filter { $0.moments.contains(.ask) } : model.askable
            chosen = Set(listed.map(\.name))
        }
        #if os(macOS)
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
        #else
        .presentationDetents([.large])
        #endif
    }

    // MARK: The ask

    @ViewBuilder private var ask: some View {
        #if os(macOS)
        macAsk
        #else
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                PluginSection(title: String(localized: "Plugins for this app · \(listed.count)"),
                              footer: String(localized: "Tap one to see everything it can do on \(gateway) before you install it.")) {
                    ForEach(listed) { plugin in AskRow(plugin: plugin, isOn: binding(for: plugin)) }
                }
                where_
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.sheetBackground)
        .safeAreaBar(edge: .bottom) {
            InstallBar(
                title: String(localized: "Install on \(gateway)"),
                busy: busyText,
                caption: isInstalling ? String(localized: "You can close this. It keeps going on \(gateway).")
                    : String(localized: "Not Now keeps them in Settings → Apps and Tools → Plugins."),
                isEnabled: !chosen.isEmpty && model.isOnline && !model.isBusy,
                link: isInstalling ? nil : String(localized: "Not Now"), onLink: close,
                action: install
            )
            .frame(maxWidth: 560)
        }
        #endif
    }

    private var header: some View {
        VStack(spacing: 8) {
            AppIconArt(size: 68)
            Text("Set Up \(gateway) for This App")
                .font(.title2.weight(.bold))
                .foregroundStyle(Theme.primaryText)
                .multilineTextAlignment(.center)
            Text(Self.reason(for: listed))
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
    }

    /// Where they go and how they stay current.
    private var where_: some View {
        PluginSection(title: nil,
                      footer: String(localized: "Pinned to the versions this app was tested with. If an update ever needs more access, the app asks first.")) {
            NavigationLink(value: AskPage.profiles) {
                PluginInfoRow(label: String(localized: "Installs into"), value: places, chevron: true)
            }
            .buttonStyle(.plain)
            PluginInfoRow(label: String(localized: "Updates"), value: String(localized: "Kept current by this app"))
        }
    }

    private var places: String {
        AppPluginsModel.places(AppPluginsModel.profiles(workspace.roster?.profiles.map(\.name) ?? []), title: model.title(of:))
    }

    private var busyText: String? {
        guard isInstalling else { return nil }
        if case .installing(let profile, let done, let total) = model.phase {
            return String(localized: "Installing in \(profile)… (\(done + 1) of \(total))")
        }
        return String(localized: "Installing on \(gateway)…")
    }

    private func binding(for plugin: AppPlugin) -> Binding<Bool> {
        Binding(get: { chosen.contains(plugin.name) }, set: { on in
            if on { chosen.insert(plugin.name) } else { chosen.remove(plugin.name) }
        })
    }

    private func install() {
        started = true
        let names = chosen
        Task { await model.install(only: names) }
    }

    private func close() {
        if model.consent == nil { model.decline() }
        model.isAsking = false
        dismiss()
    }

    /// "Hermes Agent can't reach your devices or draw cards by itself. Two small plugins add that."
    static func reason(for plugins: [AppPlugin]) -> String {
        let push = plugins.contains(.push)
        let widgets = plugins.contains(.widgets)
        switch (push, widgets, plugins.count) {
        case (true, true, 2):
            return String(localized: "Hermes Agent can’t reach your devices or draw cards by itself. Two small plugins add that.")
        case (true, false, 1):
            return String(localized: "Hermes Agent can’t reach your devices by itself. A small plugin adds that.")
        case (false, true, 1):
            return String(localized: "Hermes Agent can’t draw cards by itself. A small plugin adds that.")
        default:
            return String(localized: "These small plugins add what Hermes Agent can’t do for this app by itself.")
        }
    }

    // MARK: The Mac

    #if os(macOS)
    /// `macPluginsAsk`: a sheet on the main window, the rows in one card, Not Now and Install.
    private var macAsk: some View {
        VStack(spacing: 14) {
            BotAvatar(bot: workspace.bot, size: 56)
            VStack(spacing: 4) {
                Text("Set Up \(gateway) for This App")
                    .font(.headline)
                    .foregroundStyle(Theme.primaryText)
                Text(Self.reason(for: listed) + " " + String(localized: "In Hermes and \(botsCount)."))
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            PluginCard {
                ForEach(listed) { plugin in AskRow(plugin: plugin, isOn: binding(for: plugin)) }
            }
            Text("Pinned to the versions this app was tested with and kept current; it asks first if an update needs more access. Click one to see what it can do.")
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                if let busyText {
                    Spinner()
                    Text(busyText).font(.callout).foregroundStyle(Theme.secondaryText)
                }
                Spacer()
                Button(String(localized: "Not Now"), action: close)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isInstalling)
                Button(String(localized: "Install on \(gateway)"), action: install)
                    .inkDefaultButton()
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen.isEmpty || !model.isOnline || model.isBusy)
            }
            .buttonBorderShape(.capsule)
        }
        .padding(20)
        .background(Theme.sheetBackground)
    }

    private var botsCount: String {
        let bots = (workspace.roster?.profiles.filter { !$0.isDefault }.count ?? 0)
        return bots == 1 ? String(localized: "its 1 Bot") : String(localized: "its \(bots) Bots")
    }
    #endif
}

/// Pages the ask opens: a plugin's review, or where they go.
enum AskPage: Hashable {
    case review(String)
    case profiles
}

/// Installs Into: Hermes and each Bot, with their faces. The app's own plugins go in all of them.
struct InstallsIntoList: View {
    let workspace: BotWorkspace

    var body: some View {
        ScrollView {
            PluginSection(title: String(localized: "On \(workspace.bot.name)"),
                          footer: String(localized: "The app's own plugins go in Hermes and every Bot, and into Bots you make later: hooks only reach the plugins of the profile a turn runs in.")) {
                ForEach(AppPluginsModel.profiles(workspace.roster?.profiles.map(\.name) ?? []), id: \.self) { profile in
                    HStack(spacing: 12) {
                        ProfileFace(workspace: workspace, profile: profile, size: 28)
                        Text(workspace.plugins.title(of: profile)).foregroundStyle(Theme.primaryText)
                        Spacer()
                        Image(systemName: "checkmark").foregroundStyle(Theme.secondaryText).accessibilityHidden(true)
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 46)
                }
            }
            .padding(16)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.sheetBackground)
        .navigationTitle(String(localized: "Installs Into"))
    }
}

/// A profile's face: the Bot's, or Hermes's own for the root.
struct ProfileFace: View {
    let workspace: BotWorkspace
    let profile: String
    var size: CGFloat = 28

    var body: some View {
        if let roster = workspace.roster, let bot = roster.bot(named: profile) {
            BotFace(appearance: roster.appearance(for: bot), size: size)
        } else {
            BotAvatar(bot: workspace.bot, size: size)
        }
    }
}

/// One plugin in the ask: its glyph on ink, the feature, what it is, and a switch. The row opens
/// its review.
private struct AskRow: View {
    let plugin: AppPlugin
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            NavigationLink(value: AskPage.review(plugin.name)) {
                HStack(spacing: 12) {
                    PluginTile(symbol: plugin.words.symbol, ink: true, size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(plugin.words.feature)
                            .font(.body)
                            .foregroundStyle(Theme.primaryText)
                        Text("\(plugin.words.title) · \(plugin.words.askLine)")
                            .font(.footnote)
                            .foregroundStyle(Theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("Shows everything it can do before you install it"))
            Toggle(plugin.words.feature, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Theme.switchOn)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }
}

/// `pluginsAskDone`: where each plugin is on, the restart that finishes push, or what failed.
private struct PluginsAskDone: View {
    let workspace: BotWorkspace
    let run: AppPluginsModel.Run
    let retry: () -> Void
    let close: () -> Void

    private var model: AppPluginsModel { workspace.plugins }
    private var gateway: String { workspace.bot.name }
    private var plugins: [AppPlugin] { run.plugins.compactMap(AppPlugin.named) }
    private var failed: Bool { !run.failures.isEmpty }

    /// Nothing went in anywhere: the whole ask failed.
    private var nothingChanged: Bool {
        failed && plugins.allSatisfy { (model.survey?.profilesWith($0) ?? []).isEmpty }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(spacing: 8) {
                    AppIconArt(size: 68)
                    Text(nothingChanged ? String(localized: "Couldn’t Set Up \(gateway)")
                         : failed ? String(localized: "Not Set Up Everywhere") : String(localized: "\(gateway) Is Set Up"))
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Theme.primaryText)
                        .multilineTextAlignment(.center)
                    if !nothingChanged {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(Theme.secondaryText)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
                if let failure = run.failures.sorted(by: { $0.key < $1.key }).first {
                    FailureCard(title: nothingChanged ? String(localized: "Couldn’t install on \(gateway)")
                                                      : String(localized: "Couldn’t install in \(model.title(of: failure.key))"),
                                failure: PluginInstallFailure(message: failure.value), gateway: gateway)
                }
                if !nothingChanged {
                    PluginCard {
                        ForEach(plugins) { plugin in row(plugin) }
                    }
                }
                if failed {
                    PluginSection(title: String(localized: "Or set it up in Terminal on \(gateway)"),
                                  footer: String(localized: "Run the install lines with -p <bot> for each Bot too.")) {
                        ForEach(plugins.flatMap(AppPluginTerminalPage.commands(for:)).uniqued(), id: \.self) { command in
                            SetupCommand(command: command)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                        }
                    }
                } else if model.needsRestart, let reason = plugins.compactMap(\.words.restartReason).first {
                    RestartNote(reason: reason, error: model.restartError)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.sheetBackground)
        .safeAreaBar(edge: .bottom) { bar.frame(maxWidth: 560) }
        #if os(macOS)
        .frame(minHeight: 460)
        #endif
    }

    private func row(_ plugin: AppPlugin) -> some View {
        HStack(alignment: .top, spacing: 12) {
            PluginTile(symbol: plugin.words.symbol, ink: true, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(plugin.words.feature).foregroundStyle(Theme.primaryText)
                Text("\(plugin.words.title) · \(plugin.words.askLine)")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
                Text(placeLine(plugin))
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(isEverywhere(plugin) ? Theme.success : Theme.warning)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
    }

    /// On in every profile, as the last check found it (a pending restart doesn't change that).
    private func isEverywhere(_ plugin: AppPlugin) -> Bool {
        guard let survey = model.survey else { return false }
        let entries = survey.entries(for: plugin)
        return !entries.isEmpty && entries.allSatisfy { $0.state.isCurrent } && survey.failures.isEmpty
    }

    /// "On in Hermes and 4 Bots", or what's still missing.
    private func placeLine(_ plugin: AppPlugin) -> String {
        if isEverywhere(plugin) { return String(localized: "On in \(model.placesWith(plugin))") }
        // Where it's still missing, older or off; Hermes's words are in the card above.
        guard let survey = model.survey else { return "" }
        return AppPluginsModel.line(for: .of(plugin, in: survey, restartPending: false), title: model.title(of:))
    }

    private var subtitle: String {
        if failed { return String(localized: "Some Bots didn’t get them. Try again, or set them up in Terminal.") }
        let places = model.placesWith(plugins.first ?? .push)
        switch plugins.count {
        case 1: return String(localized: "\(plugins[0].words.title) is on in \(places).")
        case 2: return String(localized: "Both plugins are on in \(places).")
        default: return String(localized: "All \(plugins.count) plugins are on in \(places).")
        }
    }

    @ViewBuilder private var bar: some View {
        if failed {
            InstallBar(title: String(localized: "Try Again"),
                       caption: nothingChanged ? String(localized: "Nothing was changed on \(gateway).")
                                               : String(localized: "Try Again finishes the rest."),
                       isEnabled: model.isOnline && !model.isBusy, link: String(localized: "Close"), onLink: close, action: retry)
        } else if model.needsRestart {
            InstallBar(title: String(localized: "Restart Gateway"),
                       busy: model.phase == .restarting ? String(localized: "Restarting \(gateway)…") : nil,
                       caption: String(localized: "Later leaves “Restart the gateway to finish” in Settings."),
                       isEnabled: !model.isBusy, link: String(localized: "Later"), onLink: close) {
                Task {
                    await model.restartGateway()
                    if model.restartError == nil { close() }
                }
            }
        } else {
            InstallBar(title: String(localized: "Done"), caption: "", action: close)
        }
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
