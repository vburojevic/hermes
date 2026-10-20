import HermesKit
import HermesPush
import SwiftUI

/// What the edit sheet works on: an entry, and where it sat (its id changes with its text, so a
/// reload finds it again by place).
struct MemoryEditTarget: Identifiable, Hashable {
    let entry: MemoryEntry
    let index: Int?
    var id: String { entry.id }
}

/// Edit Memory (`memoryEdit`, a partial glass sheet): the entry as plain text, the room left in
/// its store, Forget This, and ✓ to save. A refusal (over the cap, changed on the gateway) shows
/// the gateway's words and keeps every character typed.
struct MemoryEditSheet: View {
    let model: MemoryModel
    let target: MemoryEditTarget

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var entry: MemoryEntry?
    @State private var loaded = false
    @State private var refusal: String?
    @State private var isSaving = false
    @State private var forgetting: MemoryEntry?
    @State private var resetting = false
    @FocusState private var focused: Bool

    private var store: MemoryStoreKind { target.entry.store }

    /// Characters left in the store with this text in place of the entry.
    private var room: Int {
        let entries = model.entries(in: store)
        let index = entries.firstIndex { $0.id == (entry ?? target.entry).id }
        return MemoryUsage.room(entries: entries.map(\.text), replacing: index, with: text.trimmingCharacters(in: .whitespacesAndNewlines),
                                limit: model.limit(for: store))
    }

    private var roomText: String {
        let label = MemoryCopy.storeLabel(store)
        return room >= 0
            ? String(localized: "\(label) · room for \(room) more characters")
            : String(localized: "\(label) · \(-room) characters over")
    }

    private var canSave: Bool {
        loaded && entry != nil && !isSaving && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.isOnline
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    TextEditor(text: $text)
                        .focused($focused)
                        .font(.body)
                        .foregroundStyle(Theme.primaryText)
                        .scrollContentBackground(.hidden)
                        .padding(10)
                        // It scrolls inside past this, so the room left and any refusal stay in view.
                        .frame(minHeight: 130, maxHeight: 200)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .disabled(!loaded)
                        .accessibilityLabel(Text("Memory"))
                    Text(roomText)
                        .font(.caption)
                        .foregroundStyle(room >= 0 ? Theme.secondaryText : Theme.warning)
                        .monospacedDigit()
                        .padding(.horizontal, 4)
                    if let refusal {
                        Label(refusal, systemImage: "exclamationmark.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(Theme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 4)
                            .transition(.opacity)
                    }
                    Button {
                        forgetting = entry ?? target.entry
                    } label: {
                        Text("Forget This")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Theme.danger)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .background(Theme.controlFill, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(PressableStyle())
                    .disabled(entry == nil || !model.isOnline)
                    .padding(.top, 8)
                    Text("Saved on \(model.gatewayName). Applies from your next chat.")
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 16)
                .animation(Theme.snappy, value: refusal)
            }
            .scrollBounceBehavior(.basedOnSize)
            .navigationTitle("Edit Memory")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", systemImage: "checkmark", action: save)
                        .buttonStyle(.glassProminent)
                        .tint(Theme.ink)
                        .disabled(!canSave)
                }
            }
        }
        .task {
            guard !loaded else { return }
            entry = target.entry
            text = await model.fullText(of: target.entry)
            loaded = true
            focused = true
        }
        .modifier(MemoryConfirmations(model: model, forgetting: $forgetting, resetting: $resetting) { dismiss() })
        #if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #else
        .frame(width: 460, height: 360)
        #endif
    }

    private func save() {
        guard let entry else { return }
        isSaving = true
        refusal = nil
        Task {
            let outcome = await model.save(entry, text: text)
            isSaving = false
            switch outcome {
            case .saved:
                dismiss()
            case .refused(let message):
                refusal = message
                // Changed on the gateway: work on the entry as it is now, keeping the typed text.
                if MemoryModel.isStale(message) {
                    self.entry = model.current(entry, at: target.index)
                    if let fresh = self.entry {
                        // What the gateway has now, beside what the person typed.
                        refusal = String(localized: "\(message)\nOn \(model.gatewayName) it now says: “\(fresh.text)”. Save to replace it with your text.")
                    } else {
                        refusal = String(localized: "This was forgotten on \(model.gatewayName). Your text is still here to copy.")
                    }
                }
            }
        }
    }
}

/// Memory Provider (`memoryOptions` → Where Memory Lives): built-in, or a provider that's ready.
/// One that needs settings opens its setup form, one that's unavailable its install
/// (`docs/setup.md` §4.4); one Hermes can't find is set up on the gateway.
struct MemoryProviderPicker: View {
    let model: MemoryModel
    @State private var settingUp: MemoryProvider?
    @State private var installing: MemoryProvider?
    /// Installed and wanting its settings: the form opens once the install sheet has gone.
    @State private var setUpNext: MemoryProvider?

    private var active: String { model.status?.active ?? "" }

    var body: some View {
        Form {
            Section {
                row(title: String(localized: "Built-in"), detail: String(localized: "Two small files on \(model.gatewayName)"), name: "", enabled: true)
                ForEach(model.status?.providers ?? []) { provider in
                    if provider.status == "needs_config" {
                        fixRow(provider, action: String(localized: "Needs its settings · Set Up…")) { settingUp = provider }
                    } else if provider.status == "unavailable" {
                        fixRow(provider, action: String(localized: "Unavailable · Install…")) { installing = provider }
                    } else {
                        row(title: provider.title, detail: detail(provider), name: provider.name, enabled: provider.isReady)
                    }
                }
            } footer: {
                Text("Built-in memory is two small files on \(model.gatewayName). Other providers (Honcho, Mem0, …) add long-term recall: one that needs installing or its settings is set up here.")
            }
            Section {
                // Providers are set up on the gateway (`docs/setup.md` §4.4).
                SetupSteps(steps: [SetupStep(String(localized: "To set one up, on \(model.gatewayName):"), command: "hermes memory setup")])
                    .padding(.vertical, 4)
                if let url = model.workspace.bot.backend?.url {
                    Link(destination: url) {
                        Label("Set Up a Provider on \(model.gatewayName)", systemImage: "arrow.up.right.square")
                    }
                }
                SetupDocsLink(url: GatewaySetup.Docs.memoryProviders)
            }
        }
        .formStyle(.grouped)
        // On the Form, not a row: a sheet on rows in a Form is repeated for each.
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
        .navigationTitle("Memory Provider")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    /// A provider the app can set up: its name, and what tapping does.
    private func fixRow(_ provider: MemoryProvider, action: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.title).foregroundStyle(Theme.primaryText)
                    Text(action)
                        .font(.caption)
                        .foregroundStyle(Theme.link)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!model.isOnline)
    }

    private func detail(_ provider: MemoryProvider) -> String {
        if provider.isReady { return provider.description.isEmpty ? String(localized: "Ready") : provider.description }
        switch provider.status {
        case "needs_config": return String(localized: "Needs setting up on the gateway")
        case "missing": return String(localized: "Not found on the gateway")
        default: return String(localized: "Unavailable")
        }
    }

    private func row(title: String, detail: String, name: String, enabled: Bool) -> some View {
        Button {
            Task { await model.setProvider(name) }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(enabled ? Theme.primaryText : Theme.tertiaryText)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if active == name {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.primaryText)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled || !model.isOnline)
        .accessibilityAddTraits(active == name ? .isSelected : [])
    }
}

/// Set Up for a memory provider that needs its settings (`docs/setup.md` §4.4): Hermes's own
/// fields for it, shown as Hermes shows them (`when`), saved with
/// `PUT /api/memory/providers/{name}/config`. Secrets go to the gateway and aren't kept here.
struct MemoryProviderSetupSheet: View {
    let model: MemoryModel
    let provider: MemoryProvider
    @Environment(\.dismiss) private var dismiss
    @State private var form: MemoryProviderForm?
    @State private var edits: [String: String] = [:]
    @State private var isSaving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                if let form {
                    let fields = form.visibleFields(edits: edits)
                    if fields.contains(where: { $0.kind == .other }) {
                        Section {
                            SetupSteps(steps: [SetupStep(String(localized: "Some of its settings are set up on \(model.gatewayName):"), command: "hermes memory setup \(provider.name)")])
                        }
                    }
                    Section {
                        ForEach(fields.filter { $0.kind != .other }) { field in
                            fieldView(field)
                        }
                    } footer: {
                        Text("Saved on \(model.gatewayName), where Hermes keeps its keys and settings. Then pick \(provider.title) to use it.")
                    }
                } else if let error {
                    Section { Text(error).foregroundStyle(Theme.secondaryText) }
                } else {
                    Section { SkeletonRows(count: 3, twoLines: false) }
                }
                if let error, form != nil {
                    Section {
                        Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(Theme.danger)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Set Up \(provider.title)")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        Spinner()
                    } else {
                        Button("Save", action: save).disabled(form.map { !$0.isComplete(edits: edits) } ?? true)
                    }
                }
            }
            .task {
                do {
                    form = try await model.providerForm(provider.name)
                } catch {
                    self.error = error.localizedDescription
                }
            }
        }
        #if os(macOS)
        .frame(width: 480).frame(minHeight: 340)
        #endif
    }

    @ViewBuilder
    private func fieldView(_ field: MemoryProviderForm.Field) -> some View {
        let binding = Binding(get: { edits[field.key] ?? field.value }, set: { edits[field.key] = $0 })
        VStack(alignment: .leading, spacing: 4) {
            if field.kind == .secret || field.kind == .text || field.kind == .number {
                // A field in a Form shows only its prompt; the name goes above it.
                Text(field.required ? String(localized: "\(field.label) (required)") : field.label)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.primaryText)
            }
            switch field.kind {
            case .secret:
                SecureField(field.label, text: binding, prompt: Text(field.isSet ? String(localized: "Set · leave empty to keep") : (field.placeholder.isEmpty ? field.label : field.placeholder)))
                    .autocorrectionDisabled()
            case .select:
                Picker(field.label, selection: binding) {
                    ForEach(field.options, id: \.value) { option in
                        Text(option.label).tag(option.value)
                    }
                }
            case .toggle:
                Toggle(field.label, isOn: Binding(get: { (edits[field.key] ?? field.value) == "true" }, set: { edits[field.key] = $0 ? "true" : "false" }))
            case .text, .number, .other:
                TextField(field.label, text: binding, prompt: Text(field.placeholder.isEmpty ? field.label : field.placeholder))
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(field.kind == .number ? .decimalPad : .default)
                    #endif
            }
            if !field.description.isEmpty {
                Text(field.description).font(.caption).foregroundStyle(Theme.secondaryText)
            }
            if let url = field.url, WebLink.isWeb(url) {
                Link("Where to get it", destination: url).font(.caption)
            }
        }
    }

    private func save() {
        guard let form else { return }
        isSaving = true
        error = nil
        Task {
            defer { isSaving = false }
            do {
                try await model.saveProvider(provider.name, values: form.changes(edits))
                edits = [:]
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// Installs what a provider needs on the gateway (`docs/setup.md` §4.4): the sheet shows what
/// Hermes will run, as the provider's plugin lists it, before the person taps Install.
struct MemoryProviderInstallSheet: View {
    let model: MemoryModel
    let provider: MemoryProvider
    /// Installed, and it wants its settings next.
    var setUp: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var form: MemoryProviderForm?
    @State private var loadError: String?
    @State private var isInstalling = false
    @State private var outcome: MemoryModel.ProviderInstallOutcome?

    var body: some View {
        NavigationStack {
            Form {
                if isInstalling {
                    Section {
                        Label {
                            Text("Installing on \(model.gatewayName). This can take a few minutes.")
                        } icon: {
                            Spinner()
                        }
                    }
                } else if let outcome {
                    result(outcome)
                } else if let setup = form?.setup, setup.hasSteps, !setup.installed {
                    plan(setup)
                } else if form != nil {
                    Section {
                        Text(form?.setup?.installed == true
                             ? String(localized: "What \(provider.title) needs is installed, but Hermes says it isn't available yet: it may need its settings, or a restart of the gateway.")
                             : String(localized: "\(provider.title) doesn't list anything to install, but Hermes says it isn't available."))
                        SetupSteps(steps: [SetupStep(String(localized: "To see what it needs, on \(model.gatewayName):"), command: "hermes memory setup")])
                            .padding(.vertical, 4)
                        SetupDocsLink(url: GatewaySetup.Docs.memoryProviders)
                    }
                } else if let loadError {
                    Section { Text(loadError).foregroundStyle(Theme.secondaryText) }
                } else {
                    Section { SkeletonRows(count: 3, twoLines: false) }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Install \(provider.title)")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(outcome == nil ? "Cancel" : "Done") { dismiss() }
                }
                if outcome == nil, let setup = form?.setup, setup.hasSteps, !setup.installed {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Install", action: install).disabled(isInstalling)
                    }
                }
            }
            .task {
                do {
                    form = try await model.providerForm(provider.name)
                } catch {
                    loadError = error.localizedDescription
                }
            }
        }
        #if os(macOS)
        .frame(width: 520).frame(minHeight: 360)
        #endif
    }

    /// Exactly what Hermes will run. The text comes from the plugin, so hidden characters show.
    private func plan(_ setup: MemoryProviderForm.Setup) -> some View {
        Section {
            if !setup.packages.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Python packages").font(.subheadline.weight(.medium))
                    Text(VisibleText.of(setup.packages.joined(separator: ", ")))
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            ForEach(setup.commands) { command in
                VStack(alignment: .leading, spacing: 4) {
                    Text(VisibleText.of(command.name)).font(.subheadline.weight(.medium))
                    Text(VisibleText.of(command.install))
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        } header: {
            Text("What Hermes runs on \(model.gatewayName)")
        } footer: {
            Text("\(provider.title)'s plugin on \(model.gatewayName) lists these. Hermes answers when they're done, which can take a few minutes.")
        }
    }

    @ViewBuilder
    private func result(_ outcome: MemoryModel.ProviderInstallOutcome) -> some View {
        switch outcome {
        case .installed(let status):
            Section {
                Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.primaryText)
                switch status {
                case "needs_config":
                    Button("Set Up \(provider.title)…", action: setUp)
                case "ready":
                    Button("Use \(provider.title)") {
                        Task {
                            await model.setProvider(provider.name)
                            dismiss()
                        }
                    }
                default:
                    Text("Hermes still says \(provider.title) isn't available.").foregroundStyle(Theme.secondaryText)
                    SetupSteps(steps: [SetupStep(String(localized: "To see what it needs, on \(model.gatewayName):"), command: "hermes memory setup")])
                        .padding(.vertical, 4)
                }
            }
        case .failed(let steps):
            Section {
                Label("Something didn't install", systemImage: "xmark.octagon.fill").foregroundStyle(Theme.danger)
                ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(VisibleText.of(step.command.isEmpty ? step.name : step.command))
                            .font(.system(.footnote, design: .monospaced).weight(.medium))
                        if !step.output.isEmpty {
                            Text(VisibleText.of(step.output))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(Theme.secondaryText)
                                .textSelection(.enabled)
                        }
                    }
                }
                Button("Try Again", action: install)
            } footer: {
                Text("Hermes's own words. To try it there, run hermes memory setup on \(model.gatewayName).")
            }
        case .unknown:
            Section {
                Text("\(model.gatewayName) stopped answering before the install finished. It may still be installing.")
                SetupCheckButton {
                    form = try? await model.providerForm(provider.name)
                    if form?.setup?.installed == true {
                        self.outcome = .installed(status: model.status?.providers.first { $0.name == provider.name }?.status)
                    }
                }
            }
        case .error(let message):
            Section {
                Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(Theme.danger)
                Button("Try Again", action: install)
            }
        }
    }

    private func install() {
        isInstalling = true
        outcome = nil
        Task {
            let outcome = await model.installProvider(provider.name)
            isInstalling = false
            self.outcome = outcome
        }
    }
}
