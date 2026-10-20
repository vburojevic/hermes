import HermesKit
import SwiftUI

/// The review of a catalog plugin (`pluginReviewCatalog`, `docs/plugins.md` §5): what it can do on
/// the gateway (its catalog capabilities in plain words, and whether its app is there), the
/// catalog's disclosure, known issues, the source and Installs Into (Hermes by default; any Bot).
/// Install on <gateway> installs it by its catalog name in each chosen profile, the root first,
/// then shows what's ready (`pluginInstalled`), asks for its keys (`pluginInstalledKeys`) or says
/// what went wrong (`pluginInstallFailed`).
struct CatalogPluginReviewView: View {
    let workspace: BotWorkspace
    let name: String
    var inPane = false
    var titled = true

    @Environment(\.dismiss) private var dismiss
    @Environment(\.pluginReviewExit) private var exit
    @State private var chosen: Set<String> = ["default"]
    @State private var keys: [String: String] = [:]
    @State private var savingKeys = false
    @State private var keysSaved = false
    @State private var keysError: String?

    private var hub: PluginHubModel { workspace.pluginHub }
    private var gateway: String { workspace.bot.name }
    private var entry: PluginCatalogEntry? { hub.entry(named: name) }
    private var run: PluginHubModel.Run? { hub.runs[name] }

    var body: some View {
        Group {
            if let entry {
                if let run, run.isDone {
                    result(entry, run)
                } else {
                    review(entry)
                }
            } else if hub.catalogChecked {
                ContentUnavailableView(String(localized: "Not in the Catalog"), systemImage: "puzzlepiece.extension",
                                       description: Text("\(name) isn’t in Hermes’s catalog as this device last read it."))
            } else {
                Spinner(size: .regular).task { await hub.load() }
            }
        }
        .detailTitle(String(localized: "Plugin"), shows: titled && !inPane)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await hub.readPresence(name) }
        // A finished install's result isn't shown again the next time the review opens.
        .onDisappear { if hub.runs[name]?.isDone == true { hub.clearRun(name) } }
    }

    // MARK: The review

    @ViewBuilder
    private func review(_ entry: PluginCatalogEntry) -> some View {
        if inPane {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    #if os(macOS)
                    let tier = entry.isOfficial ? String(localized: "Official") : String(localized: "Community")
                    PaneReviewHeader(tile: entry.tile, name: entry.title,
                                     facts: [entry.summary, tier, entry.maintainer, entry.version.map { "v\($0)" }, String(entry.sha.prefix(7))]
                                        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
                                     actionTitle: hub.installedRow(catalogName: entry.name) == nil ? String(localized: "Install on \(gateway)") : nil,
                                     busy: busyText, isEnabled: hub.unavailable(entry) == nil && hub.isOnline) {
                        let profiles = Array(chosen)
                        Task { await hub.install(entry, into: profiles) }
                    }
                    if let reason = hub.unavailable(entry) {
                        Text(reason).font(.callout).foregroundStyle(Theme.warning)
                    }
                    #endif
                    CatalogPluginReviewContent(workspace: workspace, entry: entry, chosen: $chosen, showsHero: false)
                }
                .padding(20)
            }
            .background(Theme.groupedBackground)
        } else {
            ScrollView {
                CatalogPluginReviewContent(workspace: workspace, entry: entry, chosen: $chosen)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
            }
            .background(Theme.sheetBackground)
            .safeAreaBar(edge: .bottom) {
                if hub.installedRow(catalogName: entry.name) == nil || run != nil {
                    bar(entry).frame(maxWidth: 560)
                }
            }
        }
    }

    private func bar(_ entry: PluginCatalogEntry) -> some View {
        let reason = hub.unavailable(entry)
        return InstallBar(
            title: String(localized: "Install on \(gateway)"),
            busy: busyText,
            caption: busyText != nil ? String(localized: "You can close this. It keeps going on \(gateway).")
                : reason ?? String(localized: "Turns on right away. Turn it off or remove it any time in Apps and Tools."),
            isEnabled: reason == nil && hub.isOnline
        ) {
            let profiles = Array(chosen)
            Task { await hub.install(entry, into: profiles) }
        }
    }

    private var busyText: String? {
        guard let run, let index = run.current else { return nil }
        if run.profiles.count == 1 { return String(localized: "Installing on \(gateway)…") }
        return String(localized: "Installing in \(hub.title(of: run.profiles[index]))… (\(index + 1) of \(run.profiles.count))")
    }

    // MARK: Afterwards

    @ViewBuilder
    private func result(_ entry: PluginCatalogEntry, _ run: PluginHubModel.Run) -> some View {
        let installedSomewhere = run.result != nil
        if !installedSomewhere, let failure = run.failures.sorted(by: { $0.key < $1.key }).first {
            failed(entry, failure.value)
        } else if let missing = run.result?.missingEnv, !missing.isEmpty, !keysSaved {
            PluginKeysForm(hub: hub, title: entry.title, envs: missing, values: $keys, error: keysError)
                .safeAreaBar(edge: .bottom) {
                    InstallBar(title: String(localized: "Save Keys"), busy: savingKeys ? String(localized: "Saving…") : nil,
                               caption: String(localized: "\(entry.title) starts from the next turn."),
                               isEnabled: missing.allSatisfy { !(keys[$0] ?? "").isEmpty }) {
                        saveKeys(into: run.profiles.filter { run.failures[$0] == nil })
                    }
                    .frame(maxWidth: 560)
                }
        } else {
            CatalogInstalledPage(workspace: workspace, entry: entry, run: run) { finish() }
        }
    }

    private func failed(_ entry: PluginCatalogEntry, _ message: String) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PluginHero(tile: entry.tile, name: entry.title, line: entry.summary, tags: PluginTags(tier: entry.tier))
                FailureCard(title: String(localized: "Couldn’t install on \(gateway)"), failure: PluginInstallFailure(message: message), gateway: gateway)
                PluginSection(title: String(localized: "Or set it up in Terminal on \(gateway)"),
                              footer: String(localized: "Add -p <bot> for each Bot you want it in.")) {
                    SetupCommand(command: "hermes plugins install \(entry.name) --enable")
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.sheetBackground)
        .safeAreaBar(edge: .bottom) {
            InstallBar(title: String(localized: "Try Again"), caption: String(localized: "Nothing was changed on \(gateway)."), isEnabled: hub.isOnline) {
                let profiles = run?.profiles ?? ["default"]
                hub.clearRun(entry.name)
                Task { await hub.install(entry, into: profiles) }
            }
            .frame(maxWidth: 560)
        }
    }

    private func saveKeys(into profiles: [String]) {
        let secrets = keys
        keys = [:]
        savingKeys = true
        Task {
            do {
                try await hub.saveKeys(secrets, into: profiles)
                keysSaved = true
            } catch {
                keysError = error.localizedDescription
            }
            savingKeys = false
        }
    }

    private func finish() {
        hub.clearRun(name)
        leavePluginPage(exit, dismiss)
    }
}

/// Everything above the bar.
struct CatalogPluginReviewContent: View {
    let workspace: BotWorkspace
    let entry: PluginCatalogEntry
    @Binding var chosen: Set<String>
    var showsHero = true
    @State private var picking = false

    private var hub: PluginHubModel { workspace.pluginHub }
    private var gateway: String { workspace.bot.name }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if showsHero {
                PluginHero(tile: entry.tile, name: entry.title, line: entry.summary,
                           tags: PluginTags(tier: entry.tier, maker: entry.maintainer, version: entry.version))
            }
            if let installed = hub.installedRow(catalogName: entry.name) {
                PluginCard {
                    PluginInfoRow(label: String(localized: "Installed"), value: installed.isEnabled ? String(localized: "On") : String(localized: "Turned off"),
                                  symbol: "checkmark.circle.fill")
                }
            }
            PluginSection(title: String(localized: "What it can do on \(gateway)"),
                          footer: String(localized: "From the plugin’s catalog entry and manifest at this commit.")) {
                ForEach(lines) { CapabilityRowView(line: $0) }
            }
            if let disclosure = hub.presence[entry.name]?.disclosure.nilIfEmpty ?? entry.disclosure {
                DisclosureNote(label: String(localized: "The catalog’s disclosure"), text: disclosure)
            }
            ForEach(entry.knownIssues, id: \.self) { issue in
                KnownIssueNote(text: issue)
            }
            PluginSection(title: String(localized: "Source"),
                          footer: String(localized: "Reviewed means a person read this exact commit before it entered the catalog. It isn’t a security audit.")) {
                PluginInfoRow(label: String(localized: "Reviewed"), value: String(localized: "Hermes catalog · scan passed"), symbol: "checkmark.shield")
                PluginInfoRow(label: String(localized: "Repository"), value: Self.shortRepo(entry.repo))
                PluginInfoRow(label: String(localized: "Version"), value: [entry.version, String(entry.sha.prefix(7))].compactMap { $0 }.joined(separator: " · "))
                Button { picking = true } label: {
                    PluginInfoRow(label: String(localized: "Installs into"), value: AppPluginsModel.places(Array(chosen), title: hub.title(of:)), chevron: true)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(hub.installedRow(catalogName: entry.name) != nil)
            }
        }
        .sheet(isPresented: $picking) {
            ProfilePicker(hub: hub, workspace: workspace, chosen: $chosen)
        }
    }

    /// The app it drives (from `presence`), then its capabilities. A catalog entry doesn't list
    /// where it sends data, so the review never promises it sends nothing.
    private var lines: [CapabilityLine] {
        var lines: [CapabilityLine] = []
        if let presence = hub.presence[entry.name] {
            switch presence.state {
            case "present":
                lines.append(CapabilityLine(.app, String(localized: "Uses \(presence.title) on \(gateway). \(presence.title) is there"), names: ["app: present"]))
            case "app_not_running":
                lines.append(CapabilityLine(.app, String(localized: "Uses \(presence.title) on \(gateway). It isn’t running now"), names: ["app: not running"]))
            case "missing_app":
                lines.append(CapabilityLine(.app, presence.sentence.nilIfEmpty ?? String(localized: "Needs \(presence.title) on \(gateway)"), names: ["app: missing"]))
            default:
                break
            }
        }
        guard entry.capabilitiesKnown else {
            // Known only from Hermes's lookup: say so rather than show nothing as if it did nothing.
            return lines + [CapabilityLine(.reaches, String(localized: "What it can do isn’t listed here: the catalog couldn’t be read on this device"),
                                           names: [String(localized: "Hermes checks it when it installs")])]
        }
        return lines + CapabilityWords.lines(for: entry.capabilities, gateway: gateway, knowsNetwork: false)
    }

    static func shortRepo(_ repo: String) -> String {
        var text = repo
        for prefix in ["https://github.com/", "http://github.com/"] where text.hasPrefix(prefix) { text.removeFirst(prefix.count) }
        return text.hasSuffix(".git") ? String(text.dropLast(4)) : text
    }
}

/// A known issue from the catalog: informational, never blocking.
struct KnownIssueNote: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "info.circle")
                .foregroundStyle(Theme.secondaryText)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Known issue".uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.tertiaryText)
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(Theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(Theme.pluginCell, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Installs Into: Hermes and each Bot, with checkmarks. At least one stays chosen.
private struct ProfilePicker: View {
    let hub: PluginHubModel
    let workspace: BotWorkspace
    @Binding var chosen: Set<String>
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(hub.profiles, id: \.self) { profile in
                        Button {
                            if chosen.contains(profile) {
                                if chosen.count > 1 { chosen.remove(profile) }
                            } else {
                                chosen.insert(profile)
                            }
                        } label: {
                            HStack(spacing: 12) {
                                ProfileFace(workspace: workspace, profile: profile, size: 28)
                                Text(hub.title(of: profile)).foregroundStyle(Theme.primaryText)
                                Spacer()
                                if chosen.contains(profile) {
                                    Image(systemName: "checkmark").foregroundStyle(Theme.primaryText)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(chosen.contains(profile) ? .isSelected : [])
                    }
                } footer: {
                    Text("Each Bot has its own plugins. Hooks only reach the plugins of the Bot a chat runs in.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle(String(localized: "Installs Into"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done"), systemImage: "checkmark") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(width: 380, height: 420)
        #else
        .presentationDetents([.medium, .large])
        #endif
    }
}

/// `pluginInstalled` for a catalog plugin: where it went, what works now, what waits.
private struct CatalogInstalledPage: View {
    let workspace: BotWorkspace
    let entry: PluginCatalogEntry
    let run: PluginHubModel.Run
    let done: () -> Void

    private var hub: PluginHubModel { workspace.pluginHub }
    private var activation: PluginActivation? { run.result?.activation }
    private var places: [String] { run.profiles.filter { run.failures[$0] == nil } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(spacing: 8) {
                    PluginTile(symbol: "puzzlepiece.extension", size: 68)
                    Text("\(entry.title) Is On")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Theme.primaryText)
                    Text("In \(AppPluginsModel.places(places, title: hub.title(of:))) on \(workspace.bot.name)" + (entry.version.map { " · v\($0)" } ?? ""))
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryText)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
                if let activation, activation.hasReadyNow {
                    PluginSection(title: String(localized: "Ready now")) {
                        ForEach(readyLines(activation)) { line in
                            CapabilityRowView(line: CapabilityLine(.safe, line.words, names: line.names))
                        }
                    }
                }
                if let activation, activation.hasNextChat {
                    PluginSection(title: String(localized: "From your next chat"),
                                  footer: String(localized: "Chats already open keep going as they were: Hermes reads a plugin’s tools when a chat starts.")) {
                        CapabilityRowView(line: CapabilityLine(.prompt, String(localized: "Its tools and instructions, in every chat you start from now"),
                                                               names: activation.deferredTools + activation.deferredPrompt))
                    }
                }
                if !run.failures.isEmpty {
                    ForEach(run.failures.sorted(by: { $0.key < $1.key }), id: \.key) { profile, message in
                        FailureCard(title: String(localized: "Couldn’t install in \(hub.title(of: profile))"),
                                    failure: PluginInstallFailure(message: message), gateway: workspace.bot.name)
                    }
                }
                ForEach(run.result?.knownIssues ?? [], id: \.self) { KnownIssueNote(text: $0) }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.sheetBackground)
        .safeAreaBar(edge: .bottom) {
            InstallBar(title: String(localized: "Done"), caption: "", action: done).frame(maxWidth: 560)
        }
    }

    /// Its MCP server's tools and skills, and the hooks Hermes switched on.
    private func readyLines(_ activation: PluginActivation) -> [CapabilityLine] {
        var lines: [CapabilityLine] = []
        if !activation.liveTools.isEmpty {
            let count = activation.liveTools.count
            lines.append(CapabilityLine(.tools, count == 1 ? String(localized: "1 tool, in open chats from their next turn")
                                                           : String(localized: "\(count) tools, in open chats from their next turn"),
                                        names: activation.liveTools))
        }
        if !activation.liveSkills.isEmpty {
            lines.append(CapabilityLine(.skill, String(localized: "Its skills"), names: activation.liveSkills))
        }
        lines += CapabilityWords.hookLines(activation.activatedHooks).map {
            CapabilityLine($0.kind, $0.words, names: $0.names + [String(localized: "live in the gateway")])
        }
        if !activation.activatedCommands.isEmpty {
            lines.append(CapabilityLine(.tools, String(localized: "Its commands"), names: activation.activatedCommands.map { "/" + $0 }))
        }
        return lines
    }
}
