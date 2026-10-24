import HermesKit
import HermesPush
import SwiftUI

/// The waiting card, stepped aside while the person types (`needsYouDock`,
/// `docs/quick-actions.md` §1): the whole question, its picks as chips, Deny and Allow beside a
/// short command, and with several waiting, which one of how many. Tap the question to bring the
/// card back.
struct NeedsYouDock: View {
    let conversation: ConversationModel
    let onExpand: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let items = conversation.waitingItems
        if let shown = WaitingItem.shown(items, selected: conversation.shownWaitingID) {
            VStack(alignment: .leading, spacing: 9) {
                header(shown.item, index: shown.index, count: items.count)
                HStack(spacing: 10) {
                    Button(action: onExpand) {
                        Text(subject(shown.item))
                            .font(isCommand(shown.item) ? .footnote.monospaced() : .footnote)
                            .foregroundStyle(Theme.primaryText)
                            // Never cut in the middle: it wraps, and the rest is in the card.
                            .lineLimit(showsWhole(shown.item) ? nil : (isLarge ? 2 : RequestDock.questionLines))
                            .truncationMode(.tail)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Shows the full card")
                    // Deny and Allow beside the command they answer.
                    if case .approval(let approval) = shown.item, RequestDock.answersHere(approval) {
                        decision(approval)
                    }
                }
                answers(shown.item)
            }
            .id(shown.item.id)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 22))
            .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: shown.item.id)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("needsYouDock")
        }
    }

    // MARK: Parts

    private func header(_ item: WaitingItem, index: Int, count: Int) -> some View {
        HStack(spacing: 10) {
            // Decorative: the title says what's waiting.
            Image(systemName: symbol(item))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.warning)
                .frame(width: 28, height: 28)
                .background(Theme.warningTint, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
            Text(isLarge ? String(localized: "Waiting for you") : String(localized: "\(conversation.askerName) is waiting for you"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.primaryText)
                .lineLimit(isLarge ? 1 : 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
            if count > 1 {
                WaitingStepper(conversation: conversation, items: conversation.waitingItems, index: index)
            }
            Button(action: onExpand) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                    .frame(width: 32, height: 32)
                    .background(Theme.controlFill, in: Circle())
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel("Show")
            .accessibilityHint("Shows the full card")
        }
    }

    /// Deny and Allow (Don't Save and Save for a memory), answering this request by its id.
    private func decision(_ approval: ApprovalRequest) -> some View {
        HStack(spacing: 8) {
            Button {
                conversation.respond(to: approval, with: .deny)
            } label: {
                Text(approval.isMemorySave ? String(localized: "Don't Save") : String(localized: "Deny"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.danger)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 34)
                    .background(Theme.controlFill, in: Capsule())
            }
            .buttonStyle(PressableStyle())
            Button {
                conversation.respond(to: approval, with: .once)
            } label: {
                Text(approval.isMemorySave ? String(localized: "Save") : String(localized: "Allow"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.inkForeground)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 34)
                    .background(Theme.ink, in: Capsule())
            }
            .buttonStyle(PressableStyle())
            .accessibilityHint(approval.isMemorySave ? "Saves this to memory" : "Allows this command once")
        }
        .fixedSize()
    }

    @ViewBuilder
    private func answers(_ item: WaitingItem) -> some View {
        switch item {
        case .approval(let approval) where RequestDock.answersHere(approval):
            EmptyView()
        case .approval(let approval):
            Text(approval.smartDenied ? String(localized: "Flagged by Hermes's safety check. Open it to answer.") : String(localized: "Open it to read it whole and answer."))
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
        case .request(let request):
            // At the largest text sizes the picks are on the card, one tap away: the dock stays
            // short enough to sit between the keyboard and the toolbar.
            let chips = isLarge ? [] : RequestDock.chips(for: request)
            if !chips.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(chips) { chip in
                        Button {
                            guard let result = RequestDock.pickedAnswer(chip, to: request) else { return }
                            conversation.answer(request, with: result, receipt: String(localized: "Answered · \(chip.label)"))
                        } label: {
                            Text(chip.label)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Theme.primaryText)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .frame(minHeight: 32)
                                .background(Theme.controlFill, in: Capsule())
                        }
                        .buttonStyle(PressableStyle())
                        .accessibilityHint("Answers with this")
                    }
                }
            }
            Text(hint(for: request, chips: chips))
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
        }
    }

    private var isLarge: Bool { dynamicTypeSize.isAccessibilitySize }

    // MARK: Words

    /// How this one is answered from here: a chip, words in the composer, or its card.
    private func hint(for request: HermesRequest, chips: [RequestDock.Chip]) -> String {
        guard let question = RequestDock.typedQuestion(for: request) else { return String(localized: "Open it to answer.") }
        if !chips.isEmpty { return String(localized: "Or type your own answer below.") }
        if !question.choices.isEmpty { return String(localized: "Open it to pick one, or type your answer below.") }
        return String(localized: "Type your answer below and send it.")
    }

    private func symbol(_ item: WaitingItem) -> String {
        switch item {
        case .approval(let approval):
            // A flagged command is answered on its card, never from here (`needsYouDockFlagged`).
            approval.isMemorySave ? "brain" : approval.smartDenied ? "exclamationmark.shield" : "hand.raised.fill"
        case .request(let request):
            switch request.kind {
            case .clarify, .choose: "questionmark.circle.fill"
            case .secret, .sudo, .vaultUnlock, .vaultSaveLogin, .vaultCode: "key.fill"
            case .connection: "link"
            }
        }
    }

    private func subject(_ item: WaitingItem) -> String {
        switch item {
        case .approval(let approval):
            if approval.isMemorySave { return approval.memoryText }
            if let fill = approval.paymentFill { return String(localized: "Fill your card on \(fill.site)?") }
            return approval.summary
        case .request(let request):
            if case .clarify(let questions) = request.kind, questions.count > 1 {
                return String(localized: "\(questions.count) questions. \(questions[0].question)")
            }
            return ConversationModel.title(of: request)
        }
    }

    private func isCommand(_ item: WaitingItem) -> Bool {
        if case .approval(let approval) = item { return approval.command != nil && !approval.isMemorySave }
        return false
    }

    /// A command with Allow beside it is shown whole, whatever the text size.
    private func showsWhole(_ item: WaitingItem) -> Bool {
        if case .approval(let approval) = item { return RequestDock.answersHere(approval) }
        return false
    }
}

/// "‹ 1 of 3 ›": what's waiting, one at a time; each is answered by its own id.
struct WaitingStepper: View {
    let conversation: ConversationModel
    let items: [WaitingItem]
    let index: Int

    var body: some View {
        HStack(spacing: 2) {
            Button {
                conversation.shownWaitingID = items[max(index - 1, 0)].id
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 28, height: 32)
                    .contentShape(Rectangle())
            }
            .disabled(index == 0)
            .accessibilityLabel("Previous")
            Text("\(index + 1) of \(items.count)")
                .font(.footnote.weight(.semibold).monospacedDigit())
                .foregroundStyle(Theme.secondaryText)
                .fixedSize()
                .accessibilityLabel("\(index + 1) of \(items.count) waiting")
            Button {
                conversation.shownWaitingID = items[min(index + 1, items.count - 1)].id
            } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 28, height: 32)
                    .contentShape(Rectangle())
            }
            .disabled(index >= items.count - 1)
            .accessibilityLabel("Next")
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(Theme.primaryText)
        .buttonStyle(.plain)
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
