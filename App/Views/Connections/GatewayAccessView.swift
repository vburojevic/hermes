import HermesKit
import SwiftUI

// A gateway's Access settings (`docs/connecting-and-voice.md` §11): how the app gets past an access
// gateway in front of Hermes. iPhone and iPad open them as their own page from Edit Gateway's
// Access row (`gatewayAccess`); the Mac shows the same sections inline in the sheet (`macAccess`).

/// What the last check of the Access settings found (`accessStatus` and its variants).
enum AccessCheck: Equatable {
    /// The access gateway or a proxy turned the app away before Hermes saw it.
    case refused(AccessRefusal, host: String)
    /// The app got through, and Hermes answered with its key.
    case passed
}

/// Edit Gateway's Access row on iPhone and iPad: what's set, opening the Access page.
struct GatewayAccessRow: View {
    @Binding var draft: GatewayAccessDraft
    let check: AccessCheck?
    let host: String
    let checkAgain: () async -> Void

    var body: some View {
        Section {
            NavigationLink {
                GatewayAccessPage(draft: $draft, check: check, host: host, checkAgain: checkAgain)
            } label: {
                HStack(spacing: 12) {
                    GlyphTile(symbol: "lock.shield.fill", ink: true, size: 30)
                    Text("Access")
                        .foregroundStyle(Theme.primaryText)
                    Spacer(minLength: 8)
                    Text(draft.summary)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                }
            }
        } header: {
            Text("Access")
        } footer: {
            Text("For a gateway behind an access gateway.")
        }
    }
}

/// The Access page, pushed from Edit Gateway on iPhone and iPad. Its fields edit the same draft
/// as the sheet; nothing is saved until Save.
struct GatewayAccessPage: View {
    @Binding var draft: GatewayAccessDraft
    let check: AccessCheck?
    let host: String
    let checkAgain: () async -> Void

    var body: some View {
        Form {
            if let check {
                AccessStatusSection(check: check, host: host, checkAgain: checkAgain)
            }
            GatewayAccessSections(draft: $draft)
        }
        .formStyle(.grouped)
        .navigationTitle("Access")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

/// The fields: how the app passes the access gateway, and the service token's ID, secret and
/// header names.
struct GatewayAccessSections: View {
    @Binding var draft: GatewayAccessDraft
    @State private var revealsSecret = false

    var body: some View {
        Section {
            Picker("Pass with", selection: $draft.method.animation(Theme.spring)) {
                Text("None").tag(GatewayAccess.Method.none)
                Text("Service token").tag(GatewayAccess.Method.serviceToken)
                // Saved by a newer build: shown, so the picker has its value, but not offered.
                if draft.method == .browserSignIn {
                    Text("Browser sign-in").tag(GatewayAccess.Method.browserSignIn)
                }
            }
        } header: {
            Text("Access gateway")
        } footer: {
            Text("For Cloudflare Access and similar gateways. Hermes's own API key is still sent.")
        }

        if draft.method == .serviceToken {
            Section {
                TextField("Client ID", text: $draft.clientID, prompt: Text("…access"))
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                HStack {
                    Group {
                        if revealsSecret {
                            TextField("Secret", text: $draft.secret, prompt: Text(secretPrompt))
                        } else {
                            SecureField("Secret", text: $draft.secret, prompt: Text(secretPrompt))
                        }
                    }
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    Button {
                        revealsSecret.toggle()
                    } label: {
                        Image(systemName: revealsSecret ? "eye" : "eye.slash")
                            .foregroundStyle(Theme.secondaryText)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(revealsSecret ? "Hide secret" : "Show secret")
                }
            } header: {
                Text("Service token")
            } footer: {
                Text("From the access gateway's dashboard. Kept in this device's Keychain.")
            }

            Section {
                TextField("ID", text: $draft.idHeader, prompt: Text(GatewayAccess.defaultIDHeader))
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                TextField("Secret", text: $draft.secretHeader, prompt: Text(GatewayAccess.defaultSecretHeader))
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
            } header: {
                Text("Headers")
            } footer: {
                Text("Cloudflare Access's names. Change them if your access gateway uses others.")
            }
        }
    }

    /// A saved secret shows as unchanged: it's never read back into the field.
    private var secretPrompt: String {
        draft.hasSavedSecret ? String(localized: "Unchanged") : String(localized: "Required")
    }
}

/// The status card that leads the Access page (`accessStatus`, `accessTokenRejected`,
/// `accessReady`): what happened, who said so, and Check Again.
struct AccessStatusSection: View {
    let check: AccessCheck
    let host: String
    let checkAgain: () async -> Void

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    SetupStateLabel(state: refusal == nil ? .ready : .notSetUp)
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(Theme.primaryText)
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryText)
                    if let refusal {
                        Label(refusal.source(host: host), systemImage: "lock.shield")
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
                if refusal != nil {
                    AccessCheckButton(checkAgain: checkAgain)
                }
            }
            .padding(.vertical, 6)
            .listRowBackground(refusal == nil ? Theme.successTint : Theme.dangerTint)
        }
    }

    private var refusal: AccessRefusal? {
        if case .refused(let refusal, _) = check { refusal } else { nil }
    }

    private var title: String {
        refusal?.title ?? String(localized: "Reaching Hermes through the access gateway")
    }

    private var detail: String {
        refusal?.detail ?? String(localized: "Service token accepted. Hermes answered with its key.")
    }
}

/// Check Again on the status card, in ink: it checks the settings on screen without saving them.
private struct AccessCheckButton: View {
    let checkAgain: () async -> Void
    @State private var isChecking = false

    var body: some View {
        Button {
            Task {
                isChecking = true
                await checkAgain()
                isChecking = false
            }
        } label: {
            HStack(spacing: 6) {
                if isChecking { Spinner() }
                Text(isChecking ? "Checking…" : "Check Again")
            }
        }
        .inkFilledButton()
        .disabled(isChecking)
    }
}
