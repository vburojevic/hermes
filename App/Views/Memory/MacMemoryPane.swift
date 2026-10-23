#if os(macOS)
import HermesKit
import SwiftUI

/// Settings → Memory on the Mac (`screens/mac/memory.elyx` → `macSettingsMemory`): About You
/// and Hermes's Notes on the left; saves to review, the switches, the provider and Reset
/// Memory… on the right. Double-click edits an entry in place, Delete forgets the selected one
/// after a confirmation, ⌘C copies it.
struct MacMemoryPane: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let workspace = app.currentWorkspace {
            MacMemoryContent(workspace: workspace)
                .id(workspace.id)
        } else {
            ContentUnavailableView("No gateway", systemImage: "server.rack", description: Text("Add a gateway to see what Hermes remembers."))
        }
    }
}

private struct MacMemoryContent: View {
    @State private var model: MemoryModel
    @State private var selection: String?
    @State private var editingID: String?
    @State private var draft = ""
    @State private var refusal: String?
    @State private var forgetting: MemoryEntry?
    @State private var resetting = false
    @State private var settingUp: MemoryProvider?
    @State private var installing: MemoryProvider?
    @State private var setUpNext: MemoryProvider?
    @FocusState private var listFocused: Bool
    @FocusState private var fieldFocused: Bool

    init(workspace: BotWorkspace) {
        _model = State(initialValue: MemoryModel(workspace: workspace, newInChat: workspace.currentConversation.memorySaves))
    }

    private var allEntries: [MemoryEntry] { model.entries(in: .about) + model.entries(in: .notes) }
    private var selected: MemoryEntry? { allEntries.first { $0.id == selection } }

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !model.isOnline || model.needsBotMode {
                        MemoryNotice(symbol: model.needsBotMode ? "server.rack" : "wifi.slash",
                                     title: model.needsBotMode ? String(localized: "Turn on Bot Mode for \(model.gatewayName)") : String(localized: "\(model.gatewayName) is offline"),
                                     detail: String(localized: "Memory shows when Bot Mode is connected."))
                    } else if model.settings?.isOff == true {
                        MemoryEmptyState(isOff: true) { Task { await model.turnOn() } }
                    }
                    if model.list != nil || (model.isOnline && model.isLoading) {
                        store(.about)
                        store(.notes)
                    }
                }
                .padding(.vertical, 16)
                .padding(.leading, 20)
            }
            .focusable()
            .focused($listFocused)
            .focusEffectDisabled()
            .onKeyPress(.upArrow) { move(by: -1) }
            .onKeyPress(.downArrow) { move(by: 1) }
            .onKeyPress(.return) {
                guard editingID == nil, let selected else { return .ignored }
                startEditing(selected)
                return .handled
            }
            .onDeleteCommand {
                if editingID == nil, let selected { forgetting = selected }
            }
            .onCopyCommand {
                guard editingID == nil, let selected else { return [] }
                return [NSItemProvider(object: selected.text as NSString)]
            }
            .frame(maxWidth: .infinity)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    review
                    saving
                }
                .padding(.vertical, 16)
                .padding(.trailing, 20)
            }
            .frame(width: 330)
        }
        .background(Theme.groupedBackground)
        .task(id: model.isOnline) {
            if model.isOnline { await model.load() }
        }
        .modifier(MemoryConfirmations(model: model, forgetting: $forgetting, resetting: $resetting) { selection = nil })
        .onChange(of: model.refusedEdit) {
            guard let target = model.refusedEdit else { return }
            model.refusedEdit = nil
            reopen(target)
        }
        .modifier(MemoryToast(text: $model.toast))
    }

    // MARK: Entries

    @ViewBuilder
    private func store(_ store: MemoryStoreKind) -> some View {
        let entries = model.entries(in: store)
        VStack(alignment: .leading, spacing: 8) {
            Text(MemoryCopy.storeTitle(store))
                .font(.headline)
                .foregroundStyle(Theme.primaryText)
                .accessibilityAddTraits(.isHeader)
            if model.list != nil {
                MemoryMeter(store: store, count: entries.count, fraction: model.fraction(in: store))
            }
            if model.list == nil {
                SkeletonRows(count: 3)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.groupedCell, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else if entries.isEmpty {
                Text("Nothing here yet. Tell \(model.keeperName) “Remember that…” in any chat.")
                    .font(.callout)
                    .foregroundStyle(Theme.secondaryText)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.groupedCell, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 {
                            Rectangle().fill(Theme.separator).frame(height: 0.5).padding(.leading, 12)
                        }
                        row(entry, index: index)
                    }
                }
                .background(Theme.groupedCell, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private func row(_ entry: MemoryEntry, index: Int) -> some View {
        let isSelected = selection == entry.id
        let isEditing = editingID == entry.id
        return HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                if isEditing {
                    TextField("Memory", text: $draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .focused($fieldFocused)
                        .onSubmit { commit(entry, index: index) }
                        .onExitCommand { cancelEditing() }
                    HStack(spacing: 8) {
                        Text(roomText(for: entry))
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                            .monospacedDigit()
                        Spacer()
                        Button("Cancel") { cancelEditing() }
                            .controlSize(.small)
                        Button("Save") { commit(entry, index: index) }
                            .controlSize(.small)
                            .inkDefaultButton()
                    }
                    if let refusal {
                        Text(refusal)
                            .font(.caption)
                            .foregroundStyle(Theme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text(entry.text)
                        .foregroundStyle(Theme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    if model.isNew(entry) {
                        TagLabel(title: String(localized: "New in this chat"))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !isEditing {
                Menu {
                    Button("Edit…") { startEditing(entry) }
                    Button("Copy") { Pasteboard.copy(entry.text) }
                    Divider()
                    Button("Forget…", role: .destructive) { forgetting = entry }
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(Theme.tertiaryText)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("More")
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(isSelected && !isEditing ? Theme.rowSelected : .clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { startEditing(entry) }
        .onTapGesture {
            selection = entry.id
            listFocused = true
        }
        .contextMenu {
            Button("Edit…") { startEditing(entry) }
            Button("Copy") { Pasteboard.copy(entry.text) }
            Divider()
            Button("Forget…", role: .destructive) { forgetting = entry }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(MemoryCopy.spoken(entry)))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: "Edit") { startEditing(entry) }
        .accessibilityAction(named: "Copy") { Pasteboard.copy(entry.text) }
        .accessibilityAction(named: "Forget") { forgetting = entry }
    }

    private func roomText(for entry: MemoryEntry) -> String {
        let entries = model.entries(in: entry.store)
        let index = entries.firstIndex { $0.id == entry.id }
        let room = MemoryUsage.room(entries: entries.map(\.text), replacing: index, with: draft.trimmingCharacters(in: .whitespacesAndNewlines),
                                    limit: model.limit(for: entry.store))
        return room >= 0 ? String(localized: "Room for \(room) more characters") : String(localized: "\(-room) characters over")
    }

    private func move(by step: Int) -> KeyPress.Result {
        guard editingID == nil, !allEntries.isEmpty else { return .ignored }
        let current = allEntries.firstIndex { $0.id == selection }
        let next = current.map { min(max($0 + step, 0), allEntries.count - 1) } ?? (step > 0 ? 0 : allEntries.count - 1)
        selection = allEntries[next].id
        return .handled
    }

    private func startEditing(_ entry: MemoryEntry) {
        selection = entry.id
        refusal = nil
        draft = entry.text
        editingID = entry.id
        Task {
            draft = await model.fullText(of: entry)
            fieldFocused = true
        }
    }

    private func cancelEditing() {
        editingID = nil
        refusal = nil
        listFocused = true
    }

    /// Save closes the editor at once and the row shows the new text; a refusal opens it again
    /// with the text typed and the gateway's words (`reopen`).
    private func commit(_ entry: MemoryEntry, index: Int) {
        let text = draft
        editingID = nil
        refusal = nil
        listFocused = true
        Task {
            if await model.save(entry, text: text, at: index) == .saved {
                let entries = model.entries(in: entry.store)
                if selection == entry.id { selection = entries.indices.contains(index) ? entries[index].id : nil }
            }
        }
    }

    private func reopen(_ target: MemoryEditTarget) {
        draft = target.draft ?? target.entry.text
        refusal = target.refusal
        guard !target.isGone else {
            // Nothing left to edit: say so, with what was typed.
            model.refusal = RefusedChange(String(localized: "Couldn't save the change"),
                                          message: (target.refusal ?? "") + "\n“\(target.draft ?? "")”")
            return
        }
        selection = target.entry.id
        editingID = target.entry.id
        fieldFocused = true
    }

    // MARK: Right column

    @ViewBuilder
    private var review: some View {
        let pending = model.pending
        if !pending.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Waiting for Review · \(pending.count)")
                    .font(.headline)
                    .foregroundStyle(Theme.primaryText)
                VStack(spacing: 0) {
                    ForEach(Array(pending.enumerated()), id: \.element.id) { index, item in
                        if index > 0 {
                            Rectangle().fill(Theme.separator).frame(height: 0.5).padding(.leading, 12)
                        }
                        MemoryPendingRow(item: item, compact: true) {
                            Task { await model.approve(item) }
                        } discard: {
                            Task { await model.discard(item) }
                        }
                        .font(.callout)
                        .padding(14)
                    }
                }
                .background(Theme.groupedCell, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private var saving: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Saving")
                .font(.headline)
                .foregroundStyle(Theme.primaryText)
            VStack(spacing: 0) {
                toggle(String(localized: "Remember things about you"), detail: MemoryStoreKind.about.fileName, isOn: storeBinding(.about))
                Rectangle().fill(Theme.separator).frame(height: 0.5).padding(.leading, 12)
                toggle(String(localized: "Keep notes about your setup"), detail: MemoryStoreKind.notes.fileName, isOn: storeBinding(.notes))
                Rectangle().fill(Theme.separator).frame(height: 0.5).padding(.leading, 12)
                toggle(String(localized: "Ask before saving"), detail: String(localized: "Review each change first"), isOn: askBinding)
            }
            .background(Theme.groupedCell, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .disabled(!model.isOnline || model.settings == nil)
            Text("\(model.keeperName) reads memory at the start of every chat, so changes apply from your next one.")
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Picker("Provider:", selection: providerBinding) {
                    Text("Built-in").tag("")
                    ForEach(model.status?.providers ?? []) { provider in
                        // Why one can't be picked (`docs/setup.md` §4.4).
                        Text(provider.isReady ? provider.title : String(localized: "\(provider.title) (not set up)"))
                            .tag(provider.name)
                            .disabled(!provider.isReady)
                    }
                }
                .pickerStyle(.menu)
                // Not fixed: a long provider name ("Supermemory (not set up)") would squeeze Reset.
                .frame(maxWidth: 260, alignment: .leading)
                .help("Other providers are set up on the gateway.")
                Spacer()
                Button {
                    resetting = true
                } label: {
                    Text("Reset Memory…")
                        .foregroundStyle(Theme.danger)
                        .padding(.horizontal, 14)
                        .frame(height: 28)
                        .background(Theme.groupedCell, in: Capsule())
                        .overlay(Capsule().strokeBorder(Theme.hairline))
                        .contentShape(Capsule())
                }
                .buttonStyle(PressableStyle())
                .fixedSize()
            }
            .disabled(!model.isOnline)
            .padding(.top, 4)
            let needingSettings = model.status?.providers.filter { $0.status == "needs_config" } ?? []
            let unavailable = model.status?.providers.filter { $0.status == "unavailable" } ?? []
            if !needingSettings.isEmpty || !unavailable.isEmpty {
                // Hermes takes their settings, and installs what they need, from here
                // (`docs/setup.md` §4.4).
                HStack {
                    if !needingSettings.isEmpty {
                        Menu("Set Up a Provider") {
                            ForEach(needingSettings) { provider in
                                Button(provider.title) { settingUp = provider }
                            }
                        }
                        .fixedSize()
                    }
                    if !unavailable.isEmpty {
                        Menu("Install a Provider") {
                            ForEach(unavailable) { provider in
                                Button(provider.title) { installing = provider }
                            }
                        }
                        .fixedSize()
                    }
                }
                .disabled(!model.isOnline)
            }
            if model.status?.providers.contains(where: { $0.status == "missing" }) == true {
                SetupSteps(steps: [SetupStep(String(localized: "To install another provider, on \(model.gatewayName):"), command: "hermes memory setup")])
                    .font(.caption)
            }
        }
        .sheet(item: $settingUp) { provider in
            MemoryProviderSetupSheet(model: model, provider: provider)
        }
        .sheet(item: $installing, onDismiss: {
            settingUp = setUpNext
            setUpNext = nil
        }) { provider in
            MemoryProviderInstallSheet(model: model, provider: provider) {
                setUpNext = provider
                installing = nil
            }
        }
    }

    private func toggle(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).foregroundStyle(Theme.primaryText)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    private func storeBinding(_ store: MemoryStoreKind) -> Binding<Bool> {
        Binding(get: { model.settings?.isEnabled(store) ?? true },
                set: { value in Task { await model.setEnabled(store, value) } })
    }

    private var askBinding: Binding<Bool> {
        Binding(get: { model.settings?.askBeforeSaving ?? false },
                set: { value in Task { await model.setAskBeforeSaving(value) } })
    }

    private var providerBinding: Binding<String> {
        Binding(get: { model.status?.active ?? "" },
                set: { value in Task { await model.setProvider(value) } })
    }
}
#endif
