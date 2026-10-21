import HermesKit
import HermesPush
import LocalAuthentication
import SwiftUI

/// A card fill waiting for the person's OK (`approvalPayment`, `docs/web.md` §4): the card's name,
/// the page, and Don't Fill / Fill Card. Fill Card asks for Face ID, Touch ID or the device's
/// passcode first and then answers `once`; there's never an Always, and this card is the only
/// place it's answered (not a notification, the dock, a batch or Talk).
struct PaymentApprovalCard: View {
    let approval: ApprovalRequest
    var asker: String = "Hermes"
    var deadline: Date?
    let onChoice: (ApprovalChoice) -> Void

    @State private var isConfirming = false
    @State private var problem: String?

    private var fill: PaymentFill? { approval.paymentFill }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            RequestHeader(symbol: "creditcard.fill", title: title, subtitle: String(localized: "\(asker) · checkout"), deadline: deadline)
            Text("\(asker) wants to enter your saved card into this checkout page.")
                .font(.subheadline)
                .foregroundStyle(Theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                GlyphTile(symbol: "creditcard", size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(fill?.label ?? String(localized: "A saved card"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(2)
                    Text(fill?.origin ?? approval.summary)
                        .font(.footnote.monospaced())
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityElement(children: .combine)
            FinePrint(text: String(localized: "The number and CVC never enter the chat. Approve only if you mean to pay here. \(asker) asks every time."))
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            CardFooter(secondary: String(localized: "Don't Fill"), onSecondary: { onChoice(.deny) },
                       primary: String(localized: "Fill Card"), primaryEnabled: !isConfirming, onPrimary: confirm)
                .accessibilityHint(Text("Fill Card asks for Face ID or Touch ID first"))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Card fill needs your OK")
    }

    /// "Fill your card on amazon.com?"
    private var title: String {
        guard let fill else { return String(localized: "Fill your card?") }
        return String(localized: "Fill your card on \(fill.site)?")
    }

    private func confirm() {
        isConfirming = true
        problem = nil
        let reason = fill.map { String(localized: "Fill \($0.label) on \($0.site)") } ?? String(localized: "Fill your card")
        Task {
            let outcome = await OwnerCheck.confirm(reason)
            isConfirming = false
            switch outcome {
            case .confirmed: onChoice(.once)
            case .cancelled: break
            case .unavailable:
                problem = String(localized: "Filling a card needs Face ID, Touch ID or a passcode on this device. Turn one on in Settings, or answer on another device.")
            }
        }
    }
}

/// The device owner, checked before an answer that spends: Face ID or Touch ID, with the passcode
/// (the Mac's password) as the system's fallback. Fails closed: a device with neither can't answer.
enum OwnerCheck {
    enum Outcome { case confirmed, cancelled, unavailable }

    static func confirm(_ reason: String) async -> Outcome {
        let context = LAContext()
        context.localizedCancelTitle = String(localized: "Cancel")
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return .unavailable }
        // The reply comes on a private queue: only its outcome crosses back.
        let code: LAError.Code? = await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, error in
                continuation.resume(returning: success ? nil : (error as? LAError)?.code ?? .authenticationFailed)
            }
        }
        switch code {
        case nil: return .confirmed
        case .biometryNotEnrolled?, .biometryNotAvailable?, .passcodeNotSet?: return .unavailable
        default: return .cancelled
        }
    }
}
