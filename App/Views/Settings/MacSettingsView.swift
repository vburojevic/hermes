#if os(macOS)
import HermesKit
import HermesMacSupport
import SwiftUI

/// Settings on the Mac (`screens/mac/settings.elyx`): General, Gateways and Chat tabs.
struct MacSettingsView: View {
    let updater: Updater

    @AppStorage(PreferenceKey.appearance) private var appearance = AppearancePreference.system

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralPane(updater: updater)
            }
            Tab("Gateways", systemImage: "server.rack") {
                GatewaysPane()
            }
            Tab("Chat", systemImage: "bubble.left") {
                ChatPane()
            }
        }
        .frame(width: 480)
        .preferredColorScheme(appearance.colorScheme)
    }
}

/// `macSettingsGeneral`: appearance, privacy, version and updates, links.
private struct GeneralPane: View {
    @Bindable var updater: Updater
    @AppStorage(PreferenceKey.appearance) private var appearance = AppearancePreference.system

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppearancePreference.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
            }
            Section {
                LabeledContent {
                    EmptyView()
                } label: {
                    Text("Privacy")
                    Text("Hermes talks only to your own gateways. No accounts, no analytics.")
                }
            }
            Section {
                LabeledContent("Version", value: Self.versionString)
                Toggle(isOn: $updater.checksAutomatically) {
                    Text("Check for updates automatically")
                    Text(updater.isAvailable ? String(localized: "Updates with Sparkle.") : String(localized: "This build doesn't update itself."))
                }
                .disabled(!updater.isAvailable)
                Link(destination: URL(string: "https://hermes-agent.nousresearch.com/docs/")!) {
                    LabeledContent("Hermes Agent documentation") { Image(systemName: "arrow.up.right") }
                        .foregroundStyle(Theme.primaryText)
                }
                Link(destination: URL(string: "https://github.com/NousResearch/hermes-agent")!) {
                    LabeledContent("Hermes Agent on GitHub") { Image(systemName: "arrow.up.right") }
                        .foregroundStyle(Theme.primaryText)
                }
            } footer: {
                Text("Made by Caffeinated Code · for Hermes Agent by Nous Research.")
                    .frame(maxWidth: .infinity)
                    .padding(.top, 6)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }

    static var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}

/// `macSettingsGateways`: the gateways with their status, + and −, Pair a Device…, Edit….
private struct GatewaysPane: View {
    @Environment(AppModel.self) private var app
    @State private var selection: UUID?
    @State private var isAdding = false
    @State private var editing: BotConfiguration?
    @State private var pairing: UUID?
    @State private var removing: BotConfiguration?
    @State private var removeError: String?

    private var selected: BotConfiguration? {
        app.bots.first { $0.id == (selection ?? app.bots.first?.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            List(selection: $selection) {
                ForEach(app.bots) { bot in
                    HStack(spacing: 10) {
                        BotAvatar(bot: bot, size: 26)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(bot.name)
                                .foregroundStyle(Theme.primaryText)
                            Text(subtitle(for: bot))
                                .font(.caption)
                                .foregroundStyle(Theme.secondaryText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Circle()
                            .fill(statusColor(for: bot))
                            .frame(width: 8, height: 8)
                            .padding(3)
                            .background(Circle().fill(statusColor(for: bot).opacity(0.18)))
                            .accessibilityLabel(statusText(for: bot))
                    }
                    .padding(.vertical, 4)
                    .tag(bot.id)
                    .contextMenu {
                        Button("Edit…") { editing = bot }
                        Button("Pair a Device…") { pairing = bot.id }
                        Divider()
                        Button("Remove…", role: .destructive) { removing = bot }
                    }
                }
            }
            .listStyle(.inset)
            .alternatingRowBackgrounds(.disabled)
            .frame(height: 200)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline))

            HStack(spacing: 6) {
                Button { isAdding = true } label: { Image(systemName: "plus").frame(width: 14, height: 14) }
                    .help("Add Gateway…")
                Button { removing = selected } label: { Image(systemName: "minus").frame(width: 14, height: 14) }
                    .disabled(selected == nil)
                    .help("Remove Gateway…")
                Spacer()
                Button("Pair a Device…") { pairing = selected?.id }
                    .disabled(selected == nil)
                Button("Edit…") { editing = selected }
                    .disabled(selected == nil)
            }
            .controlSize(.regular)

            Text("API keys are stored in the Keychain on this Mac.")
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
        }
        .padding(20)
        .onAppear { if selection == nil { selection = app.bots.first?.id } }
        .sheet(isPresented: $isAdding) {
            NavigationStack {
                BotEditorView(mode: .add) { isAdding = false }
            }
            .frame(width: 520).frame(minHeight: 420, idealHeight: 540)
        }
        .sheet(item: $editing) { bot in
            NavigationStack {
                BotEditorView(mode: .edit(bot)) { editing = nil }
            }
            .frame(width: 520).frame(minHeight: 420, idealHeight: 540)
        }
        .sheet(item: Binding(get: { pairing.map(PairingTarget.init) }, set: { pairing = $0?.id })) { target in
            PairingSheet(botID: target.id)
        }
        .alert(
            "Remove “\(removing?.name ?? "")”?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                guard let bot = removing else { return }
                do {
                    try app.removeBot(bot.id)
                    selection = nil
                } catch {
                    removeError = error.localizedDescription
                }
            }
        } message: {
            Text("Its chats stay on the gateway. Its API key is removed from this Mac.")
        }
        .alert("Couldn't Remove", isPresented: Binding(get: { removeError != nil }, set: { if !$0 { removeError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(removeError ?? "")
        }
    }

    private struct PairingTarget: Identifiable {
        let id: UUID
    }

    private func subtitle(for bot: BotConfiguration) -> String {
        var parts = [bot.displayAddress]
        if bot.backend != nil { parts.append(String(localized: "Bot Mode")) }
        if case .failed = app.workspaces[bot.id]?.connection { parts.append(String(localized: "Offline")) }
        return parts.joined(separator: " · ")
    }

    private func statusColor(for bot: BotConfiguration) -> Color {
        switch app.workspaces[bot.id]?.connection {
        case .online?: Theme.success
        case .connecting?: Theme.warning
        case .failed?: Theme.danger
        default: Theme.tertiaryText
        }
    }

    private func statusText(for bot: BotConfiguration) -> String {
        switch app.workspaces[bot.id]?.connection {
        case .online?: String(localized: "Connected")
        case .connecting?: String(localized: "Connecting")
        case .failed?: String(localized: "Offline")
        default: String(localized: "Not connected")
        }
    }
}

/// `macSettingsChat`: how chats behave.
private struct ChatPane: View {
    @AppStorage(PreferenceKey.sendWithReturn) private var sendWithReturn = true
    @AppStorage(PreferenceKey.expandAgentActivity) private var expandAgentActivity = false
    @AppStorage(PreferenceKey.showUsage) private var showUsage = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $expandAgentActivity) {
                    Text("Show agent steps while working")
                    Text("Tool calls and thinking appear in the transcript as they happen.")
                }
            }
            Section {
                Toggle(isOn: $sendWithReturn) {
                    Text("Send with Return")
                    Text("With Send with Return on, Shift-Return starts a new line.")
                }
            }
            Section {
                Toggle(isOn: $showUsage) {
                    Text("Show usage under replies")
                    Text("Tokens, cost and how full the context is, under each reply.")
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }
}
#endif
