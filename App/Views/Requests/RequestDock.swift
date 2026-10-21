import HermesKit
import HermesPush
import SwiftUI

/// The waiting card, stepped aside while the person types (`needsYouDock`): what's waiting, with
/// Deny and Allow right here for an approval. Tap to bring the card back.
struct NeedsYouDock: View {
    let conversation: ConversationModel
    let onExpand: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: conversation.pendingApproval?.isMemorySave == true ? "brain" : (conversation.pendingApproval != nil ? "hand.raised.fill" : "questionmark.circle.fill"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.warning)
                .frame(width: 32, height: 32)
                .background(Theme.warningTint, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            Button(action: onExpand) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(conversation.askerName) is waiting for you")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(1)
                    Text(subject)
                        .font(conversation.pendingApproval?.command != nil ? .footnote.monospaced() : .footnote)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(answersHere ? 2 : 1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows the full card")
            if let approval = conversation.pendingApproval, answersHere {
                Button {
                    conversation.respond(to: approval, with: .deny)
                } label: {
                    Text(approval.isMemorySave ? String(localized: "Don't Save") : String(localized: "Deny"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.danger)
                        .padding(.horizontal, 14)
                        .frame(height: 34)
                        .background(Theme.controlFill, in: Capsule())
                }
                .buttonStyle(PressableStyle())
                Button {
                    conversation.respond(to: approval, with: .once)
                } label: {
                    Text(approval.isMemorySave ? String(localized: "Save") : String(localized: "Allow"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.inkForeground)
                        .padding(.horizontal, 14)
                        .frame(height: 34)
                        .background(Theme.ink, in: Capsule())
                }
                .buttonStyle(PressableStyle())
                .accessibilityHint(approval.isMemorySave ? "Saves this to memory" : "Allows this command once")
            } else {
                Button(action: onExpand) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.primaryText)
                        .frame(width: 34, height: 34)
                        .background(Theme.controlFill, in: Circle())
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel("Show")
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
    }

    /// Deny and Allow right here only for one short command shown whole; anything longer (or
    /// flagged, a card fill, or one of several) opens the card to be read first.
    private var answersHere: Bool {
        guard let approval = conversation.pendingApproval, conversation.waitingApprovals.isEmpty, !approval.smartDenied,
              !approval.isPaymentFill else { return false }
        return VisibleText.fitsAtAGlance(approval.isMemorySave ? approval.memoryText : approval.summary, limit: 44)
    }

    private var subject: String {
        if let approval = conversation.pendingApproval {
            if approval.isMemorySave { return approval.memoryText }
            if let fill = approval.paymentFill { return String(localized: "Fill your card on \(fill.site)?") }
            let more = conversation.waitingApprovals.count
            return more > 0 ? String(localized: "\(more + 1) commands") : approval.summary
        }
        guard let request = conversation.requests.first else { return "" }
        return ConversationModel.title(of: request)
    }
}

extension AnyTransition {
    /// A request card coming out of the composer: it grows up from its bottom edge, coming into
    /// focus (`Theme.cardMotion`). Answered, it sinks back the same way, quicker, as the chat
    /// takes its place.
    static let risesFromComposer = AnyTransition.asymmetric(
        insertion: .modifier(active: RisesFromComposer(progress: 0), identity: RisesFromComposer(progress: 1)),
        removal: .modifier(active: RisesFromComposer(progress: 0), identity: RisesFromComposer(progress: 1))
            .animation(.smooth(duration: 0.26))
    )
}

private struct RisesFromComposer: ViewModifier {
    var progress: Double

    func body(content: Content) -> some View {
        content
            .scaleEffect(0.9 + 0.1 * progress, anchor: .bottom)
            .blur(radius: 6 * (1 - progress))
            .opacity(progress)
    }
}

/// A settled request, one line in the chat (`approvalReceipt`, `approvalResolved`,
/// `requestTimedOut`…). A session allow links to the chat's permissions.
struct ReceiptRow: View {
    let notice: Notice
    let conversation: ConversationModel
    @State private var showsPermissions = false

    private var symbol: String {
        let kind = String(notice.kind.dropFirst("receipt:".count))
        return kind == "session" ? "checkmark.shield.fill" : kind
    }

    private var isSession: Bool { notice.kind == "receipt:session" }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(isSession ? Theme.success : Theme.tertiaryText)
            Text(notice.text)
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            if isSession {
                Button("Manage") { showsPermissions = true }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.link)
                    .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 2)
        .sheet(isPresented: $showsPermissions) {
            ChatPermissionsSheet(conversation: conversation)
        }
    }
}

/// What's allowed in this chat (`qaPermissions`): the scopes allowed from approval cards and
/// "allow everything". Hermes has no call to revoke a single grant yet, so the sheet says how.
struct ChatPermissionsSheet: View {
    let conversation: ConversationModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(isOn: Binding(get: { conversation.allowsEverything }, set: { conversation.setAllowsEverything($0) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Allow Everything in This Chat")
                            Text("\(conversation.askerName) runs any command here without asking, until the chat ends.")
                                .font(.footnote)
                                .foregroundStyle(Theme.secondaryText)
                        }
                    }
                    .tint(Theme.danger)
                }
                Section {
                    if conversation.sessionGrants.isEmpty {
                        Text("Nothing allowed for this chat yet.")
                            .foregroundStyle(Theme.secondaryText)
                    } else {
                        ForEach(conversation.sessionGrants, id: \.self) { grant in
                            Label(grant.capitalized(with: .current), systemImage: "checkmark.shield.fill")
                                .symbolRenderingMode(.hierarchical)
                        }
                    }
                } header: {
                    Text("Allowed in This Chat")
                } footer: {
                    Text("These end with the chat. Commands you always allow apply in every chat; review them with /approvals.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Chat Permissions")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 360)
        #endif
        .presentationDetents([.medium, .large])
    }
}
