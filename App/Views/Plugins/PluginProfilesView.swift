import HermesKit
import SwiftUI

/// One of the app's plugins across Hermes and its Bots (`pluginProfiles`, `docs/plugins.md` §2.1):
/// a summary with one fix ("Install in Scout and Ops", "Turn On in Research Buddy"), the consent
/// card when an update asks for more access, one row per profile with its face, state and action,
/// the version and Check Again, then Turn Off in Hermes and All Bots and Remove, both confirmed.
struct PluginProfilesView: View {
    let workspace: BotWorkspace
    let plugin: AppPlugin
    @State private var confirmingOff = false
    @State private var confirmingRemove = false

    private var model: AppPluginsModel { workspace.plugins }
    private var gateway: String { workspace.bot.name }
    private var entries: [AppPluginsSurvey.Entry] { model.survey?.entries(for: plugin) ?? [] }
    private var isWorking: Bool { model.installing.contains(plugin.name) }

    var body: some View {
        Form {
            if model.needsBotMode {
                Section {
                    Text("The app installs and checks its plugins through Bot Mode. Link Bot Mode for \(gateway) first.")
                        .foregroundStyle(Theme.secondaryText)
                    BotModeLinkButton(workspace: workspace)
                }
            } else {
                if let added = model.heldUpdates[plugin] {
                    Section {
                        AppPluginConsentCard(model: model, plugin: plugin, added: added)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets())
                    }
                } else if let summary {
                    Section {
                        summaryCard(summary)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets())
                    }
                }
                Section {
                    if entries.isEmpty {
                        SkeletonRows(count: 2, twoLines: false)
                    }
                    ForEach(entries, id: \.self) { entry in profileRow(entry) }
                } header: {
                    SectionHeading(title: String(localized: "On \(gateway) · \(AppPluginsModel.places(entries.map(\.profile), title: model.title(of:)))"))
                }
                if !problems.isEmpty {
                    Section {
                        ForEach(problems, id: \.key) { profile, message in
                            LabeledContent(model.title(of: profile)) {
                                Text(PluginInstallFailure(message: message).words(gateway: gateway)).foregroundStyle(Theme.danger)
                            }
                        }
                    } header: {
                        SectionHeading(title: String(localized: "Problems"))
                    }
                }
                Section {
                    LabeledContent(String(localized: "Version"), value: String(localized: "\(plugin.version) · pinned to \(String(plugin.ref.prefix(7)))"))
                    LabeledContent(String(localized: "Checked")) {
                        if let checked = model.checkedAt {
                            Text(checked, format: .relative(presentation: .named))
                        } else {
                            Text("Not yet")
                        }
                    }
                    SetupCheckButton { await model.check() }
                        .disabled(model.isBusy || !model.isOnline)
                } header: {
                    SectionHeading(title: String(localized: "Updates"))
                } footer: {
                    Text("The app keeps it current in every Bot, and installs it in a Bot it makes from scratch.")
                }
                if model.needsRestart, let reason = plugin.words.restartReason {
                    Section {
                        RestartNote(reason: reason, error: model.restartError)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets())
                        Button(String(localized: "Restart Gateway")) { Task { await model.restartGateway() } }
                            .disabled(model.isBusy || !model.isOnline)
                    }
                }
                if entries.contains(where: { $0.state != .missing }) {
                    Section {
                        if entries.contains(where: \.isOn) {
                            Button(String(localized: "Turn Off in Hermes and All Bots")) { confirmingOff = true }
                                .disabled(model.isBusy || !model.isOnline)
                        }
                        Button(String(localized: "Remove from \(gateway)…"), role: .destructive) { confirmingRemove = true }
                            .disabled(model.isBusy || !model.isOnline)
                    } footer: {
                        if plugin == .push {
                            Text("Removing it stops notifications for every device on \(gateway). Stop Notifications in Settings → Notifications stops just this one.")
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(plugin.words.title)
        .task(id: model.isOnline) {
            if model.isOnline, model.survey == nil { await model.check() }
        }
        .confirmationDialog(String(localized: "Turn off \(plugin.words.title) in Hermes and all Bots?"), isPresented: $confirmingOff, titleVisibility: .visible) {
            Button(String(localized: "Turn Off")) { Task { await model.turnOff(plugin) } }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text("It stays installed. The app won’t turn it back on or add it to new Bots until you do.")
        }
        .confirmationDialog(String(localized: "Remove \(plugin.words.title) from \(gateway)?"), isPresented: $confirmingRemove, titleVisibility: .visible) {
            Button(String(localized: "Remove"), role: .destructive) { Task { await model.remove(plugin) } }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text("It leaves Hermes and every Bot. It stays in Suggested, so you can install it again.")
        }
    }

    // MARK: The summary

    private struct Summary {
        let title: String
        let detail: String
        let fix: String
        let profiles: Set<String>
    }

    /// The first thing to fix: missing somewhere, then older, then turned off.
    private var summary: Summary? {
        let title = model.title(of:)
        let missing = entries.filter { $0.state == .missing }.map(\.profile)
        if !missing.isEmpty {
            let places = AppPluginsModel.places(missing, title: title)
            return Summary(title: String(localized: "Missing in \(places)"), detail: plugin.words.missingEffect,
                           fix: String(localized: "Install in \(places)"), profiles: Set(missing))
        }
        let older = entries.filter { if case .outdated = $0.state { true } else { false } }.map(\.profile)
        if !older.isEmpty {
            let places = AppPluginsModel.places(older, title: title)
            return Summary(title: String(localized: "Older in \(places)"), detail: String(localized: "The app updates it the next time it checks."),
                           fix: String(localized: "Update Now"), profiles: Set(older))
        }
        let off = entries.filter { $0.state == .off }.map(\.profile)
        if !off.isEmpty {
            let places = AppPluginsModel.places(off, title: title)
            return Summary(title: String(localized: "Turned off in \(places)"), detail: plugin.words.missingEffect,
                           fix: String(localized: "Turn On in \(places)"), profiles: Set(off))
        }
        return nil
    }

    private func summaryCard(_ summary: Summary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(summary.title).font(.headline).foregroundStyle(Theme.primaryText)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
            }
            if !summary.detail.isEmpty {
                Text(summary.detail)
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            InkButton(title: summary.fix, isWorking: isWorking) {
                Task { await model.install(only: [plugin.name], profiles: summary.profiles) }
            }
            .disabled(model.isBusy || !model.isOnline)
            .padding(.top, 4)
        }
        .pluginRowCard()
    }

    // MARK: Rows

    private func profileRow(_ entry: AppPluginsSurvey.Entry) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                ProfileFace(workspace: workspace, profile: entry.profile, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.title(of: entry.profile)).foregroundStyle(Theme.primaryText)
                    Text(Self.stateText(entry.state))
                        .font(.footnote)
                        .foregroundStyle(entry.state == .missing || { if case .outdated = entry.state { true } else { false } }()
                                         ? Theme.warning : Theme.secondaryText)
                }
            }
            // Face and words as one element; the button stays its own (it changes as it installs).
            .accessibilityElement(children: .combine)
            Spacer()
            switch entry.state {
            case .current:
                Image(systemName: "checkmark").foregroundStyle(Theme.secondaryText).accessibilityHidden(true)
            case .off:
                rowButton(String(localized: "Turn On"), entry)
            case .missing:
                rowButton(String(localized: "Install"), entry)
            case .outdated:
                rowButton(String(localized: "Update"), entry)
            }
        }
    }

    private func rowButton(_ title: String, _ entry: AppPluginsSurvey.Entry) -> some View {
        Button(title) { Task { await model.install(only: [plugin.name], profiles: [entry.profile]) } }
            .buttonStyle(RowCapsuleButtonStyle())
            .disabled(model.isBusy || !model.isOnline || model.heldUpdates[plugin] != nil)
    }

    static func stateText(_ state: AppPluginState) -> String {
        switch state {
        case .current(let version): String(localized: "On · \(version)")
        case .missing: String(localized: "Not installed")
        case .outdated(let version): String(localized: "Older (\(version))")
        case .off: String(localized: "Turned off")
        }
    }

    private var problems: [(key: String, value: String)] {
        let failures = (model.survey?.failures ?? [:]).merging(model.failures) { $1 }
        return failures.sorted { $0.key < $1.key }
    }
}
