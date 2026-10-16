import HermesKit
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
                        .frame(minHeight: 130)
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
                    if self.entry == nil {
                        refusal = String(localized: "This was forgotten on \(model.gatewayName). Your text is still here to copy.")
                    }
                }
            }
        }
    }
}

/// Memory Provider (`memoryOptions` → Where Memory Lives): built-in, or a provider that's ready.
/// Setting one up happens on the gateway; this only switches between ready ones.
struct MemoryProviderPicker: View {
    let model: MemoryModel

    private var active: String { model.status?.active ?? "" }

    var body: some View {
        Form {
            Section {
                row(title: String(localized: "Built-in"), detail: String(localized: "Two small files on \(model.gatewayName)"), name: "", enabled: true)
                ForEach(model.status?.providers ?? []) { provider in
                    row(title: provider.title, detail: detail(provider), name: provider.name, enabled: provider.isReady)
                }
            } footer: {
                Text("Built-in memory is two small files on \(model.gatewayName). Other providers (Honcho, Mem0, …) add long-term recall; they are set up on the gateway.")
            }
            if let url = model.workspace.bot.backend?.url {
                Section {
                    Link(destination: url) {
                        Label("Set Up a Provider on \(model.gatewayName)", systemImage: "arrow.up.right.square")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Memory Provider")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
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
