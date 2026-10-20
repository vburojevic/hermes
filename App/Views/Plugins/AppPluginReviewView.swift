import HermesKit
import SwiftUI

/// The review of one of the app's own plugins (`pluginReview`, `pluginReviewPush`,
/// `docs/plugins.md` §5): what you get, what it can do on the gateway, the promise, the source,
/// then Install on <gateway> in a floating bar. Install is the consent. It installs in Hermes and
/// every Bot (`installBarBusy`), then shows what's ready now and what waits for the next chat
/// (`pluginInstalled`), or what went wrong with the Terminal way round (`pluginInstallFailed`).
struct AppPluginReviewView: View {
    let workspace: BotWorkspace
    let plugin: AppPlugin
    /// Opened from the one ask: the ask has the Install, so the review only reads.
    var readOnly = false
    /// Set Up Push opens it: a Terminal way round under the bar.
    var offersTerminal = false
    /// The Mac's pane draws it in the Settings window, without the sheet's own buttons.
    var inPane = false
    /// Names its page "Plugin" (not in iPad landscape's right column).
    var titled = true

    @Environment(\.dismiss) private var dismiss
    @State private var started = false
    @State private var showsTerminal = false

    private var model: AppPluginsModel { workspace.plugins }
    private var gateway: String { workspace.bot.name }
    private var isInstalling: Bool { model.installing.contains(plugin.name) }
    private var run: AppPluginsModel.Run? { started && !isInstalling ? model.lastRun : nil }

    var body: some View {
        Group {
            if showsTerminal {
                AppPluginTerminalPage(workspace: workspace, plugin: plugin, failure: nil)
            } else if let run, !run.failures.isEmpty {
                AppPluginTerminalPage(workspace: workspace, plugin: plugin, failure: run.failures.sorted { $0.key < $1.key }.first?.value,
                                      tryAgain: { install() })
            } else if let run, run.plugins.contains(plugin.name) {
                AppPluginInstalledPage(workspace: workspace, plugin: plugin, result: run.results[plugin.name])
            } else {
                review
            }
        }
        .animation(Theme.gentle, value: run)
        .animation(Theme.gentle, value: showsTerminal)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    @ViewBuilder private var review: some View {
        if inPane {
            // The Mac's pane (`macPluginReview`): Install on <gateway> is the header's default button.
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    #if os(macOS)
                    PaneReviewHeader(tile: plugin.tile, name: plugin.words.title,
                                     facts: [plugin.words.tagline, String(localized: "For This App"), plugin.words.maker, "v\(plugin.version)",
                                             String(plugin.ref.prefix(7))].joined(separator: " · "),
                                     actionTitle: installTitle, busy: busyText, isEnabled: model.isOnline && !model.isBusy, action: install)
                    #endif
                    AppPluginReviewContent(workspace: workspace, plugin: plugin, showsHero: false)
                }
                .padding(20)
            }
            .background(Theme.groupedBackground)
        } else {
            ScrollView {
                AppPluginReviewContent(workspace: workspace, plugin: plugin)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
            }
            .background(Theme.sheetBackground)
            .detailTitle(String(localized: "Plugin"), shows: titled)
            .safeAreaBar(edge: .bottom) {
                if !readOnly { bar }
            }
        }
    }

    private var bar: some View {
        InstallBar(
            title: installTitle,
            busy: busyText,
            caption: isInstalling ? String(localized: "You can close this. It keeps going on \(gateway).")
                : (plugin.words.restartReason != nil
                   ? String(localized: "Installs on \(gateway) and turns on. Turn it off any time in Apps and Tools.")
                   : String(localized: "Turns on right away. Turn it off or remove it any time in Apps and Tools.")),
            isEnabled: model.isOnline && !model.isBusy,
            link: offersTerminal && !isInstalling ? String(localized: "Set Up in Terminal Instead") : nil,
            onLink: { showsTerminal = true },
            action: install
        )
        .frame(maxWidth: 560)
    }

    private var installTitle: String {
        let entries = model.survey?.entries(for: plugin) ?? []
        if !entries.isEmpty, entries.allSatisfy({ $0.state == .off || $0.state.isCurrent }), entries.contains(where: { $0.state == .off }) {
            return String(localized: "Turn On in \(AppPluginsModel.places(entries.filter { $0.state == .off }.map(\.profile), title: model.title(of:)))")
        }
        return String(localized: "Install on \(gateway)")
    }

    /// "Installing in Scout… (4 of 5)".
    private var busyText: String? {
        guard isInstalling else { return nil }
        if case .installing(let profile, let done, let total) = model.phase {
            return String(localized: "Installing in \(profile)… (\(done + 1) of \(total))")
        }
        return String(localized: "Installing on \(gateway)…")
    }

    private func install() {
        started = true
        Task { await model.install(only: [plugin.name]) }
    }
}

/// Everything above the bar: hero, What you get, What it can do, the promise, the source.
struct AppPluginReviewContent: View {
    let workspace: BotWorkspace
    let plugin: AppPlugin
    var showsHero = true

    private var model: AppPluginsModel { workspace.plugins }
    private var gateway: String { workspace.bot.name }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if showsHero {
                PluginHero(tile: plugin.tile, name: plugin.words.title, line: plugin.words.tagline,
                           tags: PluginTags(forThisApp: true, maker: plugin.words.maker, version: plugin.version))
            }
            PluginSection(title: String(localized: "What you get")) {
                ForEach(plugin.words.benefits, id: \.self) { BenefitRow(benefit: $0) }
            }
            PluginSection(title: String(localized: "What it can do on \(gateway)"),
                          footer: String(localized: "From the plugin’s manifest at this commit.")) {
                ForEach(plugin.words.review(gateway)) { CapabilityRowView(line: $0) }
            }
            DisclosureNote(label: String(localized: "From Caffeinated Code"), text: plugin.words.promise(gateway))
            PluginSection(title: String(localized: "Source"),
                          footer: String(localized: "Not in the Hermes catalog yet, so Hermes calls it a custom source. The app installs the commit it was tested with, keeps it current, and asks first if an update needs more access.")) {
                PluginInfoRow(label: String(localized: "Made by"), value: String(localized: "\(plugin.words.maker), who make this app"))
                repositoryRow
                PluginInfoRow(label: String(localized: "Version"), value: String(localized: "\(plugin.version) · pinned to \(String(plugin.ref.prefix(7)))"))
                PluginInfoRow(label: String(localized: "Installs into"), value: AppPluginsModel.places(allProfiles, title: model.title(of:)))
                PluginInfoRow(label: String(localized: "Updates"), value: String(localized: "Kept current by this app"))
            }
        }
    }

    private var allProfiles: [String] {
        AppPluginsModel.profiles(workspace.roster?.profiles.map(\.name) ?? [])
    }

    @ViewBuilder private var repositoryRow: some View {
        if let url = URL(string: "https://github.com/\(plugin.repo)"), WebLink.isWeb(url) {
            Link(destination: url) {
                PluginInfoRow(label: String(localized: "Repository"), value: plugin.repo, valueTint: Theme.link)
            }
            .buttonStyle(.plain)
        } else {
            PluginInfoRow(label: String(localized: "Repository"), value: plugin.repo)
        }
    }
}

// MARK: - After it installs

/// `pluginInstalled`: what's on now, what starts with the next chat, then one way to try it, or
/// the restart that finishes it.
struct AppPluginInstalledPage: View {
    let workspace: BotWorkspace
    let plugin: AppPlugin
    let result: PluginActionResult?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.pluginReviewExit) private var exit
    private var model: AppPluginsModel { workspace.plugins }
    private var gateway: String { workspace.bot.name }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(spacing: 8) {
                    PluginTile(symbol: plugin.words.symbol, ink: true, size: 68)
                    Text("\(plugin.words.title) Is On")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Theme.primaryText)
                        .multilineTextAlignment(.center)
                    Text("In \(model.placesWith(plugin)) on \(gateway) · v\(plugin.version)")
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryText)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
                if !ready.isEmpty {
                    PluginSection(title: String(localized: "Ready now")) {
                        ForEach(ready) { line in
                            ResultLine(symbol: "checkmark.circle.fill", tint: Theme.success, words: line.words,
                                       mono: line.mono + " · " + String(localized: "live in the gateway"))
                        }
                    }
                }
                if let next {
                    PluginSection(title: String(localized: "From your next chat"),
                                  footer: String(localized: "Chats already open keep going as they were: Hermes reads a plugin’s tools when a chat starts.")) {
                        ResultLine(symbol: "clock", tint: Theme.secondaryText, words: next.words, mono: next.mono)
                    }
                }
                if model.needsRestart, let reason = plugin.words.restartReason {
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
        .navigationBarBackButtonHidden(exit == nil)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "Done"), systemImage: "checkmark") { leave() }
            }
        }
        .safeAreaBar(edge: .bottom) { bar.frame(maxWidth: 560) }
    }

    private func leave() { leavePluginPage(exit, dismiss) }

    /// Hooks and commands Hermes says it switched on, in the review's words.
    private var ready: [CapabilityLine] {
        guard let activation = result?.activation else { return [] }
        let live = Set(activation.activatedHooks + activation.activatedCommands.map { "command \($0)" })
        return plugin.words.review(gateway).compactMap { line in
            let names = line.names.filter(live.contains)
            return names.isEmpty ? nil : CapabilityLine(line.kind, line.words, names: names)
        }
    }

    private var next: CapabilityLine? {
        guard let activation = result?.activation, activation.hasNextChat else { return nil }
        let names = activation.deferredTools + (activation.deferredPrompt.isEmpty ? [] : [String(localized: "prompt section")])
        return CapabilityLine(.prompt, String(localized: "\(plugin.words.feature), in every chat you start from now"), names: names)
    }

    @ViewBuilder private var bar: some View {
        if model.needsRestart, plugin.words.restartReason != nil {
            InstallBar(title: String(localized: "Restart Gateway"),
                       busy: model.phase == .restarting ? String(localized: "Restarting \(gateway)…") : nil,
                       caption: String(localized: "Later leaves “Restart the gateway to finish” in Settings."),
                       isEnabled: !model.isBusy, link: String(localized: "Later"), onLink: { leave() }) {
                Task {
                    await model.restartGateway()
                    if model.restartError == nil { leave() }
                }
            }
        } else if let prompt = plugin.words.tryPrompt {
            InstallBar(title: String(localized: "Try It in a New Chat"),
                       caption: String(localized: "Starts a chat that asks: “\(prompt)”")) {
                leave()
                workspace.startChat(typing: prompt)
            }
        } else {
            InstallBar(title: String(localized: "Done"), caption: "") { leave() }
        }
    }
}

/// The plugin pages' way out: back to where the review was opened, or, in iPad landscape's right
/// column, back to an empty column.
func leavePluginPage(_ exit: PluginReviewExit?, _ dismiss: DismissAction) {
    if let exit { exit.close() } else { dismiss() }
}

/// One line of the result: a glyph, the words, the names in mono.
private struct ResultLine: View {
    let symbol: String
    let tint: Color
    let words: String
    let mono: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(words).font(.subheadline).foregroundStyle(Theme.primaryText)
                Text(mono).font(.caption2.monospaced()).foregroundStyle(Theme.tertiaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
    }
}

/// "Restart the gateway to finish", with why, and what went wrong the last time it tried.
struct RestartNote: View {
    let reason: String
    var error: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "arrow.clockwise")
                .foregroundStyle(Theme.primaryText)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Restart the gateway to finish")
                    .font(.body.weight(.medium))
                    .foregroundStyle(Theme.primaryText)
                Text(reason)
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
                if let error {
                    Text("Couldn’t restart: \(error)")
                        .font(.footnote)
                        .foregroundStyle(Theme.danger)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(Theme.pluginCell, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Terminal

/// `pluginInstallFailed`, and Set Up in Terminal Instead: what went wrong (if anything), then the
/// commands to run on the gateway. The page watches the gateway and closes once the plugin is
/// on everywhere, however it got there.
struct AppPluginTerminalPage: View {
    let workspace: BotWorkspace
    let plugin: AppPlugin
    /// Hermes's message when an install didn't go through.
    let failure: String?
    var tryAgain: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.pluginReviewExit) private var exit
    private var model: AppPluginsModel { workspace.plugins }
    private var gateway: String { workspace.bot.name }
    private var isInstalling: Bool { model.installing.contains(plugin.name) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PluginHero(tile: plugin.tile, name: plugin.words.title, line: plugin.words.tagline, tags: PluginTags(forThisApp: true))
                if let failure {
                    FailureCard(title: String(localized: "Couldn’t install on \(gateway)"),
                                failure: PluginInstallFailure(message: failure), gateway: gateway)
                }
                PluginSection(title: failure == nil ? String(localized: "Set it up in Terminal on \(gateway)")
                                                    : String(localized: "Or set it up in Terminal on \(gateway)"),
                              footer: String(localized: "Run the first line with -p <bot> for each Bot too. This sheet checks \(gateway) and closes by itself when the plugin answers.")) {
                    ForEach(Self.commands(for: plugin), id: \.self) { command in
                        SetupCommand(command: command)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.sheetBackground)
        .safeAreaBar(edge: .bottom) {
            if let tryAgain {
                InstallBar(title: String(localized: "Try Again"), busy: isInstalling ? String(localized: "Installing on \(gateway)…") : nil,
                           caption: changedCaption, isEnabled: model.isOnline && !model.isBusy, action: tryAgain)
                    .frame(maxWidth: 560)
            }
        }
        .task { await watch() }
    }

    private func leave() { leavePluginPage(exit, dismiss) }

    private var changedCaption: String {
        let on = model.survey?.profilesWith(plugin) ?? []
        return on.isEmpty ? String(localized: "Nothing was changed on \(gateway).")
            : String(localized: "It’s on in \(AppPluginsModel.places(on, title: model.title(of:))). Try Again finishes the rest.")
    }

    /// The commands, in the order to run them.
    static func commands(for plugin: AppPlugin) -> [String] {
        var commands = ["hermes plugins install \(plugin.repo) --enable"]
        if plugin.words.restartReason != nil { commands.append("hermes gateway restart") }
        return commands
    }

    /// Every few seconds: is it on everywhere now? Then close with it.
    private func watch() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(5))
            guard !model.isBusy else { continue }
            await model.check()
            if model.status(for: plugin).isReady || (model.status(for: plugin) == .restartPending) {
                leave()
                return
            }
        }
    }
}

/// The red card: what went wrong in words, Hermes's message in mono.
struct FailureCard: View {
    let title: String
    let failure: PluginInstallFailure
    let gateway: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.danger)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Theme.primaryText)
                Text(failure.words(gateway: gateway))
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
                Text(failure.detail)
                    .font(.caption2.monospaced())
                    .foregroundStyle(Theme.secondaryText)
                    .textSelection(.enabled)
                    .lineLimit(6)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(Theme.dangerWash, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Theme.dangerBorder))
        .accessibilityElement(children: .combine)
    }
}
