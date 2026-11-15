import HermesKit
import SwiftUI

// A gateway's Access settings (`docs/connecting-and-voice.md` §11): how the app gets past an access
// gateway or a proxy that asks for a client certificate in front of Hermes. iPhone and iPad open them as their own page from Edit Gateway's
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
    /// The gateway's address and name, for the sign-in page and the status card.
    let gateway: URL?
    let name: String
    let checkAgain: () async -> Void

    var body: some View {
        Section {
            NavigationLink {
                GatewayAccessPage(draft: $draft, check: check, host: host, gateway: gateway, name: name, checkAgain: checkAgain)
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
            Text("For a gateway behind an access gateway or a proxy that asks for a certificate.")
        }
    }
}

/// The Access page, pushed from Edit Gateway on iPhone and iPad. Its fields edit the same draft
/// as the sheet; nothing is saved until Save.
struct GatewayAccessPage: View {
    @Binding var draft: GatewayAccessDraft
    let check: AccessCheck?
    let host: String
    let gateway: URL?
    let name: String
    let checkAgain: () async -> Void
    @State private var importsCertificate = false
    @State private var signsIn = false

    var body: some View {
        Form {
            if let check {
                AccessStatusSection(
                    check: check, host: host, name: name, checkAgain: checkAgain, settings: draft,
                    importCertificate: { importsCertificate = true }, signIn: { signsIn = true }
                )
            }
            GatewayAccessSections(draft: $draft, signIn: { signsIn = true }) { importsCertificate = true }
        }
        .formStyle(.grouped)
        .certificateImport(isPresented: $importsCertificate, draft: $draft)
        .accessSignIn(isPresented: $signsIn, gateway: gateway, draft: $draft, checkAgain: checkAgain)
        .navigationTitle("Access")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

/// The fields: how the app passes the access gateway, the service token's ID, secret and header
/// names, and the client certificate. The view that holds them presents the import
/// (`certificateImport`), so the status card's Replace… opens the same one.
struct GatewayAccessSections: View {
    @Binding var draft: GatewayAccessDraft
    /// Opens the access gateway's sign-in page (`accessSignIn`).
    let signIn: () -> Void
    let importCertificate: () -> Void
    @State private var revealsSecret = false

    var body: some View {
        Section {
            Picker("Pass with", selection: $draft.method.animation(Theme.spring)) {
                Text("None").tag(GatewayAccess.Method.none)
                Text("Service token").tag(GatewayAccess.Method.serviceToken)
                Text("Browser sign-in").tag(GatewayAccess.Method.browserSignIn)
            }
        } header: {
            Text("Access gateway")
        } footer: {
            Text("None, Service token or Browser sign-in. For Cloudflare Access and similar gateways. Hermes's own API key is still sent.")
        }

        if draft.method == .browserSignIn {
            BrowserSignInSection(draft: $draft, signIn: signIn)
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

        ClientCertificateSection(draft: $draft, importCertificate: importCertificate)
    }

    /// A saved secret shows as unchanged: it's never read back into the field.
    private var secretPrompt: String {
        draft.hasSavedSecret ? String(localized: "Unchanged") : String(localized: "Required")
    }
}

/// The Browser sign-in section (`accessPage` and its sign-in variants): who is signed in and until
/// when, with Sign Out; or Sign In… when nobody is, or the sign-in ran out. Signing in or out
/// changes the draft, saved with the gateway like the rest.
struct BrowserSignInSection: View {
    @Binding var draft: GatewayAccessDraft
    let signIn: () -> Void

    var body: some View {
        let session = draft.session
        let expired = session?.isExpired() == true
        Section {
            HStack(spacing: 12) {
                GlyphTile(symbol: "person.crop.circle.fill", ink: session != nil, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.title(session))
                        .foregroundStyle(session == nil ? Theme.secondaryText : Theme.primaryText)
                    if let subtitle = Self.subtitle(session, signedOutAt: draft.signedOutAt) {
                        Text(subtitle)
                            .font(.footnote)
                            .foregroundStyle(expired ? Theme.warning : Theme.secondaryText)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            if session == nil || expired {
                Button("Sign In…", action: signIn)
            } else {
                Button("Sign Out") { withAnimation(Theme.spring) { draft.signOut() } }
            }
        } header: {
            Text("Browser sign-in")
        } footer: {
            Text("Opens the access gateway's sign-in page. The app keeps the session it gives, never your password.")
        }
    }

    static func title(_ session: AccessSession?) -> String {
        guard let session else { return String(localized: "Not signed in") }
        return session.email ?? String(localized: "Signed in")
    }

    static func subtitle(_ session: AccessSession?, signedOutAt: Date?) -> String? {
        guard let session else {
            return signedOutAt.map { String(localized: "Signed out on \($0.formatted(Self.when))") }
        }
        guard let expires = session.expires else {
            return String(localized: "Signed in on \(session.signedInAt.formatted(Self.when))")
        }
        return session.isExpired()
            ? String(localized: "Sign-in ended \(expires.formatted(Self.when))")
            : String(localized: "Signed in until \(expires.formatted(Self.when))")
    }

    /// "Nov 21 at 3:40 PM".
    private static let when = Date.FormatStyle.dateTime.month(.abbreviated).day().hour().minute()
}

extension View {
    /// Signs in for `draft`: the page's session goes into it, then the settings on screen are
    /// checked again, so the status card says whether the access gateway lets the app through.
    func accessSignIn(
        isPresented: Binding<Bool>, gateway: URL?, draft: Binding<GatewayAccessDraft>,
        checkAgain: @escaping () async -> Void
    ) -> some View {
        accessSignIn(isPresented: isPresented, gateway: gateway, identity: draft.wrappedValue.identity) { session in
            if let session {
                withAnimation(Theme.spring) { draft.wrappedValue.signedIn(session) }
            }
            Task { await checkAgain() }
        }
    }
}

/// The status card that leads the Access page (`accessStatus`, `accessTokenRejected`,
/// `accessReady`, `accessCertNeeded`, `accessCertRejected`, `accessCertExpired`): what happened,
/// who said so, and Check Again, with Import Certificate… or Replace… when it's the certificate.
struct AccessStatusSection: View {
    let check: AccessCheck
    let host: String
    /// The gateway's name, as the card says it ("Sign in to reach Home Server").
    var name: String = "Hermes"
    let checkAgain: () async -> Void
    /// The settings checked, for what the Ready card says got through.
    var settings: GatewayAccessDraft?
    var importCertificate: (() -> Void)?
    /// Opens the access gateway's sign-in page, offered when the access gateway wants a sign-in.
    var signIn: (() -> Void)?

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
                if let refusal {
                    HStack(spacing: 8) {
                        if refusal.isSignIn, let signIn {
                            Button("Sign In…", action: signIn)
                                .cardButton()
                        }
                        if refusal.isCertificate, let importCertificate {
                            Button(refusal == .certificateNeeded ? ClientCertificateSection.importTitle : String(localized: "Replace…"),
                                   action: importCertificate)
                                .cardButton()
                        }
                        AccessCheckButton(checkAgain: checkAgain)
                    }
                }
            }
            .padding(.vertical, 6)
            .listRowBackground(tint)
        }
    }

    private var refusal: AccessRefusal? {
        if case .refused(let refusal, _) = check { refusal } else { nil }
    }

    /// A sign-in the access gateway wants is the person's to give, not something broken.
    private var tint: Color {
        guard let refusal else { return Theme.successTint }
        return refusal.isSignIn ? Theme.warningTint : Theme.dangerTint
    }

    private var title: String {
        if let refusal { return refusal.title(gateway: name) }
        return settings?.method == GatewayAccess.Method.none
            ? String(localized: "Reaching Hermes through the proxy")
            : String(localized: "Reaching Hermes through the access gateway")
    }

    private var detail: String {
        if let refusal { return refusal.detail(gateway: name) }
        if settings?.method == .browserSignIn {
            return settings?.usesClientCertificate == true
                ? String(localized: "Sign-in and certificate accepted. Hermes answered with its key.")
                : String(localized: "Sign-in accepted. Hermes answered with its key.")
        }
        switch (settings?.method == .serviceToken || settings == nil, settings?.usesClientCertificate == true) {
        case (true, true): return String(localized: "Service token and certificate accepted. Hermes answered with its key.")
        case (false, true): return String(localized: "Certificate accepted. Hermes answered with its key.")
        default: return String(localized: "Service token accepted. Hermes answered with its key.")
        }
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
