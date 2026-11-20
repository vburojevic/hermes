import HermesKit
import SwiftUI

/// Add Key… for a model provider: the key goes to the gateway's own settings (`model.save_key`,
/// over Bot Mode) and nowhere else (`docs/setup.md` §4.3). From a turn that failed on it, and from
/// the model picker's providers that need one.
struct ProviderKeySheet: View {
    let problem: ProviderProblem
    let gatewayName: String
    let save: (String) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var isSaving = false
    @State private var error: String?
    @FocusState private var fieldFocused: Bool

    private var name: String { problem.providerLabel ?? problem.provider ?? "" }
    private var title: String { String(localized: "Key for \(name)") }
    private var isEmpty: Bool { key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        #if os(macOS)
        macSheet
        #else
        phoneSheet
        #endif
    }

    private var field: some View {
        SecureField("API key", text: $key)
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
            .focused($fieldFocused)
            .onSubmit(submit)
    }

    private var footer: Text {
        if case .key(let envVar?) = problem.kind {
            Text("Saved on \(gatewayName) as \(envVar), where Hermes keeps its keys. Not kept on this device.")
        } else {
            Text("Saved on \(gatewayName), where Hermes keeps its keys. Not kept on this device.")
        }
    }

    #if os(macOS)
    /// The Mac's window-modal sheet: the heading, the field, its footer, the error when saving
    /// failed, and Cancel and Save as push buttons. Return saves; Escape cancels.
    private var macSheet: some View {
        VStack(spacing: 12) {
            Text(title)
                .font(.headline.bold())
                .foregroundStyle(Theme.primaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .accessibilityAddTraits(.isHeader)
            field
                .textFieldStyle(.plain)
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .background(Theme.sheetCell, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
            footer
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
            if let error {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "xmark.octagon.fill")
                        .accessibilityHidden(true)
                    Text(error)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .foregroundStyle(Theme.danger)
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .background(Theme.sheetCell, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
                .accessibilityElement(children: .combine)
            }
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if isSaving {
                    Spinner()
                        .frame(width: 76, height: 28)
                } else {
                    Button("Save", action: submit)
                        .keyboardShortcut(.defaultAction)
                        .inkDefaultButton()
                        .disabled(isEmpty)
                }
            }
            .padding(.top, 6)
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 20)
        .frame(width: 440)
        .frame(minHeight: 220)
        .background(Theme.sheetBackground)
        .onAppear { fieldFocused = true }
    }
    #else
    /// A medium-detent sheet: a grouped Form, glass ✕ to cancel and the prominent ✓ to save,
    /// dimmed until a key is typed.
    private var phoneSheet: some View {
        NavigationStack {
            Form {
                Section {
                    field
                } footer: {
                    footer
                }
                if let error {
                    Section {
                        Label(error, systemImage: "xmark.octagon.fill")
                            .foregroundStyle(Theme.danger)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        Spinner()
                    } else {
                        Button(role: .confirm, action: submit)
                            .tint(Theme.ink)
                            .disabled(isEmpty)
                            .accessibilityLabel("Save")
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
    #endif

    private func submit() {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSaving else { return }
        isSaving = true
        error = nil
        Task {
            defer { isSaving = false }
            do {
                try await save(trimmed)
                key = ""
                dismiss()
            } catch {
                self.error = (error as? GatewayRPCError)?.message ?? error.localizedDescription
            }
        }
    }
}
