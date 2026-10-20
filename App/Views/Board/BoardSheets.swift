import HermesKit
import SwiftUI

// MARK: - New Card (`newCard`)

/// Title and description, who works on it (faces, Hermes first, the gateway's default picked),
/// Let Hermes Write It Up (Triage), Starts After, Works In, and a rough size under the options.
struct NewCardSheet: View {
    let model: BoardModel
    let target: BoardModel.NewCardTarget

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var details = ""
    @State private var assignee: String?
    @State private var writeUp = false
    @State private var parents: Set<String> = []
    @State private var worksIn: NewBoardCard.WorksIn = .worktree
    @State private var estimate: BoardEstimate?
    @State private var isAdding = false
    @State private var configured = false
    @FocusState private var titleFocused: Bool

    private var canAdd: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isAdding && model.isOnline
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    label(String(localized: "Title"))
                    TextField(String(localized: "What needs doing"), text: $title)
                        .focused($titleFocused)
                        .font(.body)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 48)
                        .background(Theme.sheetCell, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    label(String(localized: "Description")).padding(.top, 10)
                    TextField(String(localized: "What should be done, and how you’ll know it’s done"), text: $details, axis: .vertical)
                        .font(.body)
                        .lineLimit(2...8)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(Theme.sheetCell, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    label(String(localized: "Who works on it")).padding(.top, 10)
                    assigneePicker
                    options.padding(.top, 10)
                    Text(footnote)
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                        .padding(.horizontal, 16)
                        .padding(.top, 2)
                        .animation(Theme.snappy, value: footnote)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(Theme.sheetBackground.ignoresSafeArea())
            .navigationTitle("New Card")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add Card", systemImage: "checkmark", action: add)
                        .buttonStyle(.glassProminent)
                        .tint(Theme.ink)
                        .disabled(!canAdd)
                }
            }
        }
        .task {
            guard !configured else { return }
            configured = true
            writeUp = target.triage
            assignee = model.defaultAssignee.flatMap { model.assignableProfiles.contains($0) ? $0 : nil } ?? model.assignableProfiles.first
            worksIn = NewBoardCard.WorksIn(rawValue: model.info?.defaultWorkspaceKind ?? "") ?? .scratch
            titleFocused = true
        }
        // A rough size, once typing pauses (the gateway's auxiliary model; never money).
        .task(id: "\(title)\n\(details)") {
            guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                estimate = nil
                return
            }
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            if let result = await model.estimate(title: title, body: details), result.ok { estimate = result }
        }
        #if os(iOS)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        #else
        .frame(width: 480, height: 600)
        #endif
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Theme.secondaryText)
            .padding(.horizontal, 16)
    }

    private var assigneePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.assignableProfiles, id: \.self) { profile in
                    let selected = assignee == profile
                    Button {
                        assignee = selected ? nil : profile
                    } label: {
                        HStack(spacing: 7) {
                            BoardFace(model: model, profile: profile, size: 18)
                            Text(model.name(of: profile))
                                .font(.subheadline.weight(selected ? .semibold : .regular))
                                .foregroundStyle(selected ? Theme.inkForeground : Theme.primaryText)
                        }
                        .padding(.leading, 10)
                        .padding(.trailing, 13)
                        .frame(height: 36)
                        .background(selected ? Theme.ink : Theme.sheetCell, in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(.horizontal, 2)
        }
        .scrollClipDisabled()
    }

    private var options: some View {
        VStack(spacing: 0) {
            Toggle(isOn: $writeUp) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Let Hermes Write It Up")
                        .foregroundStyle(Theme.primaryText)
                    Text("Starts in Triage; Hermes turns your note into a full card")
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            .tint(Theme.ink)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            divider
            NavigationLink {
                StartsAfterPicker(model: model, selection: $parents)
            } label: {
                optionRow(String(localized: "Starts After"), value: parents.isEmpty ? String(localized: "Nothing") : BoardCopy.cards(parents.count))
            }
            .buttonStyle(.plain)
            divider
            Menu {
                Picker("Works In", selection: $worksIn) {
                    Text("New worktree").tag(NewBoardCard.WorksIn.worktree)
                    Text("Project folder").tag(NewBoardCard.WorksIn.dir)
                    Text("Scratch folder").tag(NewBoardCard.WorksIn.scratch)
                }
            } label: {
                optionRow(String(localized: "Works In"), value: worksInTitle)
            }
            .buttonStyle(.plain)
        }
        .background(Theme.sheetCell, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var divider: some View {
        Rectangle().fill(Theme.separator).frame(height: 0.5).padding(.leading, 16)
    }

    private var worksInTitle: String {
        switch worksIn {
        case .worktree: String(localized: "New worktree")
        case .dir: String(localized: "Project folder")
        case .scratch: String(localized: "Scratch folder")
        }
    }

    private func optionRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(Theme.primaryText)
            Spacer()
            Text(value).foregroundStyle(Theme.secondaryText)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.tertiaryText)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 50)
        .contentShape(Rectangle())
    }

    /// "About 40k tokens · medium. Ada starts when a slot is free."
    private var footnote: String {
        var parts: [String] = []
        if let estimate { parts.append(BoardCopy.estimate(estimate) + ".") }
        if writeUp {
            parts.append(String(localized: "Hermes writes it up, then it waits in To Do."))
        } else if !parents.isEmpty {
            parts.append(String(localized: "It waits until the cards before it are done."))
        } else if let assignee {
            parts.append(String(localized: "\(model.name(of: assignee)) starts when a slot is free."))
        } else {
            parts.append(String(localized: "Nobody picks it up until you give it to someone."))
        }
        return parts.joined(separator: " ")
    }

    private func add() {
        isAdding = true
        let draft = NewBoardCard(title: title, body: details, assignee: assignee, parents: Array(parents), worksIn: worksIn)
        Task {
            let result = await model.add(draft, writeUp: writeUp)
            isAdding = false
            if result.ok { dismiss() }
        }
    }
}

/// Starts After: the cards this one waits for.
private struct StartsAfterPicker: View {
    let model: BoardModel
    @Binding var selection: Set<String>

    private var candidates: [BoardCard] {
        model.allCards.filter { $0.column != "done" }
    }

    var body: some View {
        List {
            if candidates.isEmpty {
                Text("No cards to wait for.")
                    .foregroundStyle(Theme.secondaryText)
            }
            ForEach(candidates) { card in
                Button {
                    if selection.contains(card.id) { selection.remove(card.id) } else { selection.insert(card.id) }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(card.title).foregroundStyle(Theme.primaryText)
                            Text("\(model.columnTitle(card.column)) · \(model.name(of: card.assignee))")
                                .font(.footnote)
                                .foregroundStyle(Theme.secondaryText)
                        }
                        Spacer()
                        if selection.contains(card.id) {
                            Image(systemName: "checkmark")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(Theme.primaryText)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection.contains(card.id) ? .isSelected : [])
            }
        }
        .navigationTitle("Starts After")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

// MARK: - Assign To…

struct AssignCardSheet: View {
    let model: BoardModel
    let card: BoardCard

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(model.assignableProfiles, id: \.self) { profile in
                        row(profile)
                    }
                    row(nil)
                } footer: {
                    if card.column == "running" {
                        Text("It's running: giving it to someone else stops this run first.")
                    }
                }
            }
            .navigationTitle("Assign To")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #else
        .frame(width: 380, height: 420)
        #endif
    }

    private func row(_ profile: String?) -> some View {
        Button {
            Task { await model.assign(card, to: profile ?? "") }
            dismiss()
        } label: {
            HStack(spacing: 12) {
                if profile != nil {
                    BoardFace(model: model, profile: profile, size: 24)
                } else {
                    Image(systemName: "person.crop.circle.badge.xmark")
                        .font(.system(size: 18))
                        .foregroundStyle(Theme.secondaryText)
                        .frame(width: 24)
                }
                Text(profile == nil ? String(localized: "Nobody") : model.name(of: profile))
                    .foregroundStyle(Theme.primaryText)
                Spacer()
                if card.assignee == profile {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.primaryText)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(card.assignee == profile ? .isSelected : [])
    }
}

// MARK: - Reopen with Note…

/// The note goes on the card as a comment; then it's back in Ready for another attempt.
struct ReopenCardSheet: View {
    let model: BoardModel
    let card: BoardCard

    @Environment(\.dismiss) private var dismiss
    @State private var note = ""
    @State private var isSending = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                Text("What should change? The note goes on the card, and the card goes back to Ready for another try.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                TextField(String(localized: "Your note"), text: $note, axis: .vertical)
                    .focused($focused)
                    .lineLimit(4...12)
                    .textFieldStyle(.plain)
                    .padding(14)
                    .background(Theme.sheetCell, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                Spacer(minLength: 0)
            }
            .padding(16)
            .background(Theme.sheetBackground.ignoresSafeArea())
            .navigationTitle("Reopen with Note")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Reopen", systemImage: "arrow.uturn.backward") {
                        isSending = true
                        Task {
                            if await model.reopen(card, note: note) { dismiss() }
                            isSending = false
                        }
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Theme.ink)
                    .disabled(isSending || note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { focused = true }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #else
        .frame(width: 440, height: 320)
        #endif
    }
}

// MARK: - Edit

struct EditCardSheet: View {
    let model: BoardModel
    let card: BoardCard

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var details = ""
    @State private var loaded = false
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Title")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.secondaryText)
                        .padding(.horizontal, 16)
                    TextField(String(localized: "Title"), text: $title)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 48)
                        .background(Theme.sheetCell, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    Text("Description")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.secondaryText)
                        .padding(.horizontal, 16)
                        .padding(.top, 10)
                    TextField(String(localized: "Description"), text: $details, axis: .vertical)
                        .lineLimit(4...16)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(Theme.sheetCell, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                }
                .padding(16)
            }
            .background(Theme.sheetBackground.ignoresSafeArea())
            .navigationTitle("Edit Card")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", systemImage: "checkmark") {
                        isSaving = true
                        Task {
                            if await model.edit(card, title: title, body: details) { dismiss() }
                            isSaving = false
                        }
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Theme.ink)
                    .disabled(isSaving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .task {
            guard !loaded else { return }
            loaded = true
            title = card.title
            details = model.details[card.id]?.card.body ?? card.body ?? ""
        }
        #if os(iOS)
        .presentationDetents([.large])
        #else
        .frame(width: 480, height: 460)
        #endif
    }
}

// MARK: - Watch

/// The run's live chat, read-only: the worker's chat in the card's folder, refreshed every 3 s.
/// Without one (an older gateway, a run just starting), the worker's output instead.
struct WatchRunSheet: View {
    let model: BoardModel
    let card: BoardCard

    @Environment(\.dismiss) private var dismiss
    @State private var sessionID: String?
    @State private var messages: [SessionMessage] = []
    @State private var searched = false

    private var current: BoardCard { model.card(card.id) ?? card }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if sessionID != nil, !visibleMessages.isEmpty {
                            ForEach(Array(visibleMessages.enumerated()), id: \.offset) { index, message in
                                messageView(message).id(index)
                            }
                        } else if searched {
                            output
                        } else {
                            SkeletonRows().padding(.top, 8)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(16)
                    .frame(maxWidth: Theme.readableWidth)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: messages.count) { proxy.scrollTo("end", anchor: .bottom) }
            }
            .background(Theme.canvas.ignoresSafeArea())
            .navigationTitle(current.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", systemImage: "xmark") { dismiss() }
                }
                if let sessionID, model.isOwnProfile(current.assignee) {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Open in Chats", systemImage: "bubble.left.and.text.bubble.right") {
                            model.openWorkerChat(sessionID, card: current)
                            dismiss()
                        }
                    }
                }
            }
            .safeAreaBar(edge: .top) {
                HStack(spacing: 8) {
                    BoardFace(model: model, profile: current.assignee, size: 18, working: current.column == "running")
                    Text(statusLine)
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }
        }
        .task(id: card.id) { await follow() }
        #if os(iOS)
        .presentationDetents([.large])
        #else
        .frame(width: 560, height: 640)
        #endif
    }

    private var statusLine: String {
        let who = model.name(of: current.assignee)
        if current.column == "running" { return String(localized: "\(who) is working · live") }
        return String(localized: "\(who) · \(model.columnTitle(current.column))")
    }

    private var visibleMessages: [SessionMessage] {
        messages.filter { message in
            switch message.role {
            case "user", "assistant": !message.content.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !message.toolCalls.isEmpty
            default: false
            }
        }
    }

    @ViewBuilder
    private func messageView(_ message: SessionMessage) -> some View {
        if message.role == "user" {
            Text(message.content.text)
                .font(.subheadline)
                .foregroundStyle(Theme.primaryText)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                let text = message.content.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { MarkdownView(text: text) }
                ForEach(Array(message.toolCalls.enumerated()), id: \.offset) { _, call in
                    Label(call.name.replacingOccurrences(of: "_", with: " "), systemImage: "wrench.and.screwdriver")
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                }
            }
        }
    }

    private var output: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("The run's output")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.secondaryText)
            let lines = model.logs[card.id]?.lastLines(80) ?? []
            Text(lines.isEmpty ? String(localized: "Nothing yet.") : lines.joined(separator: "\n"))
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(Theme.primaryText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func follow() async {
        while !Task.isCancelled {
            if sessionID == nil { sessionID = await model.workerChat(for: current) }
            searched = true
            if let sessionID, let transcript = try? await model.transcript(of: sessionID, profile: current.assignee),
               transcript.messages != messages {
                messages = transcript.messages
            }
            // A card that isn't running has a worker chat that isn't moving.
            try? await Task.sleep(for: .seconds(current.column == "running" ? 3 : 30))
        }
    }
}
