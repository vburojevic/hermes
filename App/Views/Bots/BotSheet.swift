import HermesKit
import SwiftUI

/// Create a Bot, or change one's name, role and look.
struct BotSheet: View {
    enum Mode: Equatable {
        case create
        case edit(String)
    }

    let roster: BotRoster
    let mode: Mode
    /// The gateway, for What <Bot> Remembers (Edit Bot).
    var workspace: BotWorkspace?
    /// Called with the Bot's profile name when it was created or saved.
    let onDone: (String?) -> Void

    @State private var draft = BotDraft()
    @State private var copiesSetup = true
    @State private var isSaving = false
    @State private var error: String?
    @State private var originalRole: String?
    @State private var loaded = false
    @State private var isDelighted = false
    @State private var celebrations = 0
    @State private var typingPauses = 0
    private enum Field: Hashable { case name, role }
    @FocusState private var focus: Field?

    private var editingName: String? {
        if case .edit(let name) = mode { name } else { nil }
    }

    private var bot: BotProfile? { editingName.flatMap(roster.bot(named:)) }

    private var previewProfile: String {
        editingName ?? roster.uniqueSlug(for: draft.title.isEmpty ? "bot" : draft.title)
    }

    private func preview(for profile: String) -> BotAppearance {
        if let bot, roster.photos[bot.name] != nil, draft == BotDraft(bot: bot, appearance: roster.appearance(for: bot)) {
            return roster.appearance(for: bot)
        }
        return BotAppearance(profile: profile, shape: draft.shape.rawValue, color: draft.colorValue, customized: true)
    }

    private var canSave: Bool {
        !draft.title.trimmingCharacters(in: .whitespaces).isEmpty && !isSaving && roster.isConnected
    }

    var body: some View {
        // Computed once per update: each read derives a unique slug from the roster.
        let profile = previewProfile
        let preview = preview(for: profile)
        NavigationStack {
            Form {
                Section {
                    // The Mac sheet is compact (`screens/mac/sheets.elyx` `macNewBot`): the face
                    // beside its name; iPhone and iPad give it the stage.
                    Self.headerLayout {
                        // It watches you name it (`docs/bot-faces.md` §5.5): eyes on the Name field
                        // while it has focus, a blink when typing pauses, and a morph to each shape.
                        BotFace(
                            appearance: preview, size: Self.faceSize,
                            mood: isSaving ? .thinking : (isDelighted ? .happy : (focus != nil ? .listening : .idle)),
                            look: focus == .name ? CGVector(dx: Self.isCompact ? 0.6 : 0, dy: 1) : nil,
                            blinks: typingPauses, boopable: true
                        )
                        .overlay {
                            SparkleBurst(color: preview.color, trigger: celebrations)
                        }
                        .padding(.top, Self.isCompact ? 0 : 10)
                        .sensoryFeedback(.success, trigger: celebrations)
                        .accessibilityLabel(Text("Preview of \(draft.title.isEmpty ? String(localized: "the new Bot") : draft.title)"))
                        VStack(alignment: Self.isCompact ? .leading : .center, spacing: 2) {
                            if Self.isCompact {
                                Text(draft.title.isEmpty ? String(localized: "New Bot") : draft.title)
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(Theme.primaryText)
                                    .lineLimit(1)
                            }
                            if editingName == nil {
                                Group {
                                    if draft.title.isEmpty {
                                        Text("Name your Bot").font(.footnote)
                                    } else {
                                        Text("@\(profile)").font(.footnote.monospaced())
                                    }
                                }
                                .foregroundStyle(Theme.secondaryText)
                                .contentTransition(.numericText())
                                .animation(Theme.snappy, value: profile)
                            } else if let bot {
                                Text("@\(bot.mentionTag)")
                                    .font(.footnote.monospaced())
                                    .foregroundStyle(Theme.secondaryText)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Self.isCompact ? 6 : 14)
                    .listRowBackground(Color.clear)
                }

                Section {
                    TextField("Name", text: $draft.title, prompt: Text("Research Buddy"))
                        .focused($focus, equals: .name)
                        .task(id: draft.title) {
                            // A blink when typing pauses for 0.8 s.
                            guard loaded, focus == .name, !draft.title.isEmpty else { return }
                            try? await Task.sleep(for: .seconds(0.8))
                            if !Task.isCancelled { typingPauses += 1 }
                        }
                        .submitLabel(draft.role.isEmpty ? .next : .done)
                        .onSubmit { focus = draft.role.isEmpty ? .role : nil }
                    TextField("Role", text: $draft.role, prompt: Text("Digs through papers and the web for answers"), axis: .vertical)
                        .lineLimit(1...4)
                        .focused($focus, equals: .role)
                } footer: {
                    Text("The role tells the Bot who it is. You can refine it later in its chat.")
                }

                // Edit Bot → What <Bot> Remembers (`editBot`): the Bot's own memory.
                if let editingName, let workspace {
                    Section("Memory") {
                        MemorySettingsRow(workspace: workspace, scope: .bot(editingName))
                    }
                }

                Section("Look") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(BotAppearance.Shape.allCases, id: \.self) { shape in
                                Button {
                                    draft.shape = shape
                                } label: {
                                    BotFace(appearance: BotAppearance(profile: profile, shape: shape.rawValue, color: draft.colorValue, customized: true), size: Self.isCompact ? 26 : 34)
                                        .padding(6)
                                        .background(
                                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                .strokeBorder(shape == draft.shape ? Theme.primaryText : .clear, lineWidth: 2)
                                        )
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(shape.label)
                                .accessibilityAddTraits(shape == draft.shape ? .isSelected : [])
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Self.isCompact ? 4 : 8), count: Self.isCompact ? 12 : 6), spacing: 10) {
                        ForEach(BotDraft.hues, id: \.self) { hue in
                            Button {
                                draft.hue = hue
                            } label: {
                                Circle()
                                    .fill(Color(hue: Double(hue) / 360, saturation: 0.68, lightness: 0.58))
                                    .frame(width: Self.isCompact ? 20 : 28, height: Self.isCompact ? 20 : 28)
                                    .overlay {
                                        if hue == draft.hue {
                                            Circle().strokeBorder(Theme.primaryText, lineWidth: 2).padding(-4)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, minHeight: Self.isCompact ? 30 : 40)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(BotDraft.colorName(hue))
                            .accessibilityAddTraits(hue == draft.hue ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, 6)
                }

                if editingName == nil {
                    Section {
                        Toggle("Start from Hermes's setup", isOn: $copiesSetup)
                    } footer: {
                        Text("Copies the model, keys and settings of your main Hermes profile, so the new Bot can answer straight away. Its memory and chat start empty.")
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
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(editingName == nil ? "New Bot" : "Edit Bot")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onDone(nil) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(editingName == nil ? "Create" : "Save", action: save)
                            .disabled(!canSave)
                    }
                }
            }
            .onAppear(perform: populate)
            .onChange(of: draft.shape) { delight() }
            .onChange(of: draft.hue) { delight() }
            .interactiveDismissDisabled(isSaving)
        }
        #if os(iOS)
        .presentationDragIndicator(.visible)
        #endif
    }

    /// New Bot / Edit Bot preview (`docs/bot-faces.md` §4).
    private static let faceSize: CGFloat = 88
    #if os(macOS)
    private static let isCompact = true
    #else
    private static let isCompact = false
    #endif

    /// The face beside its name on the Mac; above it elsewhere.
    @ViewBuilder
    private static func headerLayout<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if isCompact {
            HStack(spacing: 14) { content() }
        } else {
            VStack(spacing: 12) { content() }
        }
    }

    /// A happy squint for a moment: it likes the new look.
    private func delight() {
        guard loaded else { return }
        isDelighted = true
        Task {
            try? await Task.sleep(for: .seconds(0.9))
            isDelighted = false
        }
    }

    private func populate() {
        guard !loaded else { return }
        loaded = true
        if let bot {
            draft = BotDraft(bot: bot, appearance: roster.appearance(for: bot))
            originalRole = bot.role
        } else {
            draft.hue = BotDraft.hues.randomElement() ?? 210
            draft.shape = BotAppearance.Shape.allCases.randomElement() ?? .squircle
            focus = .name
        }
    }

    private func save() {
        guard canSave else { return }
        isSaving = true
        error = nil
        Task {
            do {
                if let name = editingName {
                    try await roster.updateBot(name, draft: draft, originalRole: originalRole)
                    AccessibilityNotification.Announcement(String(localized: "Saved")).post()
                    onDone(name)
                } else {
                    let name = try await roster.createBot(draft, copySetupFromPrimary: copiesSetup)
                    // A moment to celebrate before the sheet goes.
                    celebrations += 1
                    isDelighted = true
                    AccessibilityNotification.Announcement(String(localized: "\(draft.title) is ready")).post()
                    try? await Task.sleep(for: .seconds(0.95))
                    onDone(name)
                }
            } catch {
                self.error = BotRoster.describe(error)
                AccessibilityNotification.Announcement(self.error ?? "").post()
            }
            isSaving = false
        }
    }
}
