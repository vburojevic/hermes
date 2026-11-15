import HermesKit
import SwiftUI
import UniformTypeIdentifiers

// A gateway's client certificate (`docs/connecting-and-voice.md` §11.9): the card on the Access
// page (`accessCertificate`) and the import, a .p12 or .pfx file from Files and then its
// password. The identity goes into the draft; it reaches the Keychain only when the gateway is
// saved, and the password is never kept.

/// The Client certificate section of the Access settings: what's imported, Replace and Remove, or
/// Import Certificate… when there's none.
struct ClientCertificateSection: View {
    @Binding var draft: GatewayAccessDraft
    let importCertificate: () -> Void

    var body: some View {
        Section {
            if let certificate = draft.certificate {
                card(certificate)
            } else {
                Button(Self.importTitle, action: importCertificate)
            }
        } header: {
            Text("Client certificate")
        } footer: {
            #if os(macOS)
            Text("For a proxy that asks for one: a .p12 or .pfx file and its password, kept in this Mac's Keychain. Works with either kind of access, or alone.")
            #else
            Text("For a proxy that asks for one. A .p12 or .pfx file from Files, kept in this device's Keychain. Works with either kind of access gateway, or alone.")
            #endif
        }
    }

    #if os(macOS)
    static let importTitle = String(localized: "Import…")
    #else
    static let importTitle = String(localized: "Import Certificate…")
    #endif

    @ViewBuilder
    private func card(_ certificate: ClientCertificate) -> some View {
        HStack(spacing: 12) {
            GlyphTile(symbol: certificate.isExpired() ? "xmark.seal.fill" : "checkmark.seal.fill", ink: true, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(certificate.fileName)
                    .foregroundStyle(Theme.primaryText)
                Text(keptLine)
                    .font(.footnote)
                    .foregroundStyle(draft.identity == nil ? Theme.warning : Theme.secondaryText)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        LabeledContent("Issued to", value: certificate.subject)
        LabeledContent("Issued by", value: certificate.issuer)
        LabeledContent(certificate.isExpired() ? "Expired" : "Expires") {
            Text(certificate.notAfter.formatted(date: .abbreviated, time: .omitted))
                .foregroundStyle(certificate.isExpired() ? Theme.danger : Theme.secondaryText)
        }
        #if os(macOS)
        HStack {
            Button("Replace…", action: importCertificate)
            Button("Remove") { withAnimation(Theme.spring) { draft.removeCertificate() } }
        }
        #else
        Button("Replace…", action: importCertificate)
        Button("Remove Certificate", role: .destructive) {
            withAnimation(Theme.spring) { draft.removeCertificate() }
        }
        #endif
    }

    /// Where the identity is: a gateway saved on another device lists its certificate, but the
    /// Keychain here doesn't have it, so nothing is sent until it's imported again.
    private var keptLine: String {
        guard draft.identity != nil else {
            return String(localized: "Not on this device. Replace it to use it here.")
        }
        #if os(macOS)
        return String(localized: "Kept in this Mac's Keychain")
        #else
        return String(localized: "Kept in this device's Keychain")
        #endif
    }
}

extension View {
    /// Picks a .p12 or .pfx file, asks for its password, and puts the certificate in `draft`.
    func certificateImport(isPresented: Binding<Bool>, draft: Binding<GatewayAccessDraft>) -> some View {
        modifier(CertificateImport(isPresented: isPresented, draft: draft))
    }
}

/// The import (`certificateImport`): the file picker, the password alert, and what went wrong.
private struct CertificateImport: ViewModifier {
    @Binding var isPresented: Bool
    @Binding var draft: GatewayAccessDraft

    /// The picked file, held only while its password is asked for.
    @State private var file: PickedFile?
    @State private var password = ""
    @State private var asksPassword = false
    @State private var triedWrongPassword = false
    @State private var failure: String?

    private struct PickedFile {
        let name: String
        let data: Data
    }

    /// Far larger than any certificate file, so a wrong pick isn't read whole.
    private static let sizeLimit = 1_000_000

    func body(content: Content) -> some View {
        content
            .fileImporter(isPresented: $isPresented, allowedContentTypes: [.pkcs12]) { result in
                pick(result)
            }
            .alert("Certificate password", isPresented: $asksPassword, presenting: file) { file in
                SecureField("Password", text: $password)
                Button("Cancel", role: .cancel) { finish() }
                Button("Import") { open(file) }
                    .keyboardShortcut(.defaultAction)
            } message: { file in
                if triedWrongPassword {
                    Text("That password didn't open \(file.name). Try again.")
                } else {
                    Text("Enter the password for \(file.name). The app keeps the certificate, not the password.")
                }
            }
            .alert(
                "Couldn't import the certificate",
                isPresented: Binding { failure != nil } set: { if !$0 { failure = nil } }
            ) {
                Button("OK", role: .cancel) { failure = nil }
            } message: {
                Text(failure ?? "")
            }
    }

    private func pick(_ result: Result<URL, any Error>) {
        guard case .success(let url) = result else { return }
        do {
            let read = try FileAttachment.read(url, limit: Self.sizeLimit)
            file = PickedFile(name: url.lastPathComponent, data: read.data)
            triedWrongPassword = false
            password = ""
            asksPassword = true
        } catch {
            failure = String(localized: "\(url.lastPathComponent) couldn't be read.")
        }
    }

    private func open(_ file: PickedFile) {
        do {
            let (certificate, identity) = try ClientCertificate.open(file.data, password: password, fileName: file.name)
            withAnimation(Theme.spring) { draft.useCertificate(certificate, identity: identity) }
            finish()
        } catch .wrongPassword {
            password = ""
            triedWrongPassword = true
            // The alert is still closing from this tap; it opens again once it has.
            Task { @MainActor in asksPassword = true }
        } catch .noIdentity {
            finish()
            failure = String(localized: "\(file.name) has no certificate with its private key. Export it again with the key included.")
        } catch {
            finish()
            failure = String(localized: "\(file.name) isn't a .p12 or .pfx file the app can read.")
        }
    }

    /// Forgets the file and the password.
    private func finish() {
        file = nil
        password = ""
        triedWrongPassword = false
    }
}
