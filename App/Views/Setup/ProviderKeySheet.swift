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

    private var name: String { problem.providerLabel ?? problem.provider ?? "" }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("API key", text: $key)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .onSubmit(submit)
                } footer: {
                    if case .key(let envVar?) = problem.kind {
                        Text("Saved on \(gatewayName) as \(envVar), where Hermes keeps its keys. Not kept on this device.")
                    } else {
                        Text("Saved on \(gatewayName), where Hermes keeps its keys. Not kept on this device.")
                    }
                }
                if let error {
                    Section {
                        Label(error, systemImage: "xmark.octagon.fill")
                            .foregroundStyle(Theme.danger)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Key for \(name)")
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
                        Button("Save", action: submit)
                            .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
        #if os(macOS)
        .frame(width: 440).frame(minHeight: 220)
        #else
        .presentationDetents([.medium])
        #endif
    }

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
