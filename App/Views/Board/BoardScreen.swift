import HermesKit
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// A project's Board (`boardRunning`, `boardBlocked`, `ipadBoard`, `macBoard`).
///
/// iPhone: one column at a time, swiping sideways, with the column switcher above; cards push.
/// iPad: columns side by side; landscape opens a card in the inspector, portrait as a sheet.
/// Mac: every column, the inspector on select, drag and drop by the workflow's moves, ⌘-click
/// to select several, ⌘→ / ⌘← to move the selected card.
struct BoardScreen: View {
    let workspace: BotWorkspace
    let projectID: String
    var onToggleSidebar: (() -> Void)?

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var width: CGFloat = 0
    @State private var targetedColumn: String?

    private var model: BoardModel { workspace.board(for: projectID) }
    private var projects: ProjectsModel { workspace.projects }

    private var isCompact: Bool {
        #if os(macOS)
        false
        #else
        horizontalSizeClass == .compact
        #endif
    }

    /// Columns beside an inspector (iPad landscape, Mac); iPad portrait opens a card as a sheet.
    private var usesInspector: Bool {
        #if os(macOS)
        true
        #else
        !isCompact && width >= 1000
        #endif
    }

    private var columnWidth: CGFloat {
        #if os(macOS)
        222
        #else
        255
        #endif
    }

    var body: some View {
        @Bindable var model = model
        Group {
            if model.workflow == nil {
                placeholder
            } else if isCompact {
                phoneBoard
            } else {
                columnsBoard
            }
        }
        .background(background.ignoresSafeArea())
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .modifier(BoardCardPresentation(model: model, isCompact: isCompact, usesInspector: usesInspector))
        .toolbar { toolbar }
        #if os(macOS)
        .navigationTitle(String(localized: "\(model.projectName) Board"))
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        #else
        .navigationTitle("")
        .toolbarTitleDisplayMode(.inline)
        #endif
        .safeAreaBar(edge: .top) { ConnectionBanner(workspace: workspace) }
        .overlay(alignment: .bottom) { noticeView }
        .onAppear { model.appear() }
        .onDisappear { model.disappear() }
        .sheet(item: $model.newCard) { target in NewCardSheet(model: model, target: target) }
        .sheet(item: $model.assigning) { card in AssignCardSheet(model: model, card: card) }
        .sheet(item: $model.reopening) { card in ReopenCardSheet(model: model, card: card) }
        .sheet(item: $model.editing) { card in EditCardSheet(model: model, card: card) }
        .sheet(item: $model.watching) { card in WatchRunSheet(model: model, card: card) }
        .confirmationDialog(
            String(localized: "Delete “\(model.deleting?.title ?? "")”?"),
            isPresented: Binding(get: { model.deleting != nil }, set: { if !$0 { model.deleting = nil } }),
            titleVisibility: .visible,
            presenting: model.deleting
        ) { card in
            Button("Delete Card", role: .destructive) { Task { await model.delete(card) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("It's removed from the board on \(model.gatewayName) for good, with its comments and history. Archive keeps it.")
        }
        .onChange(of: model.phase) { pickOpeningColumn() }
        .onChange(of: model.snapshot.cards.count) { pickOpeningColumn() }
        #if os(macOS)
        .onKeyPress(.rightArrow, phases: .down) { press in
            guard press.modifiers.contains(.command), model.openCardID != nil else { return .ignored }
            Task { await model.moveOpenCard(forward: true) }
            return .handled
        }
        .onKeyPress(.leftArrow, phases: .down) { press in
            guard press.modifiers.contains(.command), model.openCardID != nil else { return .ignored }
            Task { await model.moveOpenCard(forward: false) }
            return .handled
        }
        .onKeyPress(.escape) {
            guard !model.selection.isEmpty || model.openCardID != nil else { return .ignored }
            model.selection = []
            model.openCardID = nil
            return .handled
        }
        #endif
    }

    private var background: Color {
        #if os(macOS)
        Theme.sheetBackground
        #else
        Theme.canvas
        #endif
    }

    /// The iPhone opens on the most urgent column once the cards are in.
    private func pickOpeningColumn() {
        guard model.visibleColumn == nil, model.phase == .ready, !model.allCards.isEmpty || model.workflow != nil else { return }
        model.visibleColumn = model.urgentColumn
    }

    @ViewBuilder
    private var placeholder: some View {
        switch model.phase {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unavailable(let message), .failed(let message):
            StateMessage(symbol: "square.grid.2x2", title: String(localized: "The board isn't available"), message: message,
                         actionTitle: String(localized: "Try Again")) {
                Task { await model.reload() }
            }
        case .ready:
            EmptyView()
        }
    }

    // MARK: Summary lines

    /// "Hermes App · 19 cards · Hermes and 3 Bots working".
    private var phoneSubtitle: String {
        var parts = [model.projectName, BoardCopy.cards(model.allCards.count)].filter { !$0.isEmpty }
        if let working = workingLine { parts.append(working) }
        return parts.joined(separator: " · ")
    }

    private var workingLine: String? {
        let names = model.workingAssignees
        guard !names.isEmpty else { return nil }
        let hermes = names.contains("default") || names.contains { workspace.roster?.bot(named: $0)?.isDefault == true }
        let bots = names.count - (hermes ? 1 : 0)
        switch (hermes, bots) {
        case (true, 0): return String(localized: "Hermes working")
        case (true, 1): return String(localized: "Hermes and 1 Bot working")
        case (true, _): return String(localized: "Hermes and \(bots) Bots working")
        case (false, 1): return String(localized: "\(model.name(of: names[0])) working")
        default: return String(localized: "\(bots) Bots working")
        }
    }

    /// "19 cards · 2 running · 1 needs you".
    private var columnsSubtitle: String {
        var parts = [BoardCopy.cards(model.allCards.count)]
        if model.runningCount > 0 { parts.append(String(localized: "\(model.runningCount) running")) }
        if model.needsYouCount > 0 { parts.append(String(localized: "\(model.needsYouCount) needs you")) }
        return parts.joined(separator: " · ")
    }

    // MARK: iPhone (`boardRunning`, `boardBlocked`)

    private var currentColumn: String {
        model.visibleColumn ?? model.urgentColumn ?? model.columns.first?.key ?? ""
    }

    private var phoneBoard: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Board")
                    .font(.largeTitle.bold())
                    .foregroundStyle(Theme.primaryText)
                    .accessibilityAddTraits(.isHeader)
                HStack(spacing: 8) {
                    ProjectTile(appearance: projects.appearance(projectID), size: 20)
                    Text(phoneSubtitle)
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
            columnChips
            TabView(selection: Binding(get: { currentColumn }, set: { key in withAnimation(Theme.snappy) { model.visibleColumn = key } })) {
                ForEach(model.columns) { column in
                    phoneColumn(column)
                        .tag(column.key)
                }
            }
            #if os(iOS)
            .tabViewStyle(.page(indexDisplayMode: .never))
            #endif
        }
    }

    /// The column switcher: a tab bar to VoiceOver ("Running, 2 cards, tab 4 of 7").
    private var columnChips: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(model.columns) { column in
                        let count = model.cards(in: column.key).count
                        let attention = column.key == "blocked" ? model.needsYouCount : 0
                        ColumnChip(title: column.title, count: count, attention: attention, isSelected: currentColumn == column.key) {
                            withAnimation(Theme.snappy) { model.visibleColumn = column.key }
                        }
                        .id(column.key)
                        .accessibilityLabel(chipLabel(column, count: count, attention: attention))
                        .accessibilityAddTraits(currentColumn == column.key ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 2)
            }
            .scrollClipDisabled()
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isTabBar)
            .onChange(of: currentColumn, initial: true) { _, key in
                withAnimation(Theme.snappy) { proxy.scrollTo(key, anchor: .center) }
            }
        }
        .padding(.bottom, 8)
    }

    private func chipLabel(_ column: BoardColumn, count: Int, attention: Int) -> String {
        var label = "\(column.title), \(BoardCopy.cards(count))"
        if attention > 0 { label += ", " + String(localized: "\(attention) needs you") }
        return label
    }

    private func phoneColumn(_ column: BoardColumn) -> some View {
        let cards = model.cards(in: column.key)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                BoardColumnHeader(title: column.title, count: cards.count, onAdd: addAction(column))
                    .padding(.top, 6)
                ForEach(cards) { card in
                    cardButton(card)
                }
                if cards.isEmpty { emptyColumn(column) }
                columnFootnote(column)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        .refreshable { await model.reload() }
    }

    private func addAction(_ column: BoardColumn) -> (() -> Void)? {
        guard column.isDropTarget else { return nil }
        return { model.newCard = BoardModel.NewCardTarget(triage: column.key == "triage") }
    }

    private func emptyColumn(_ column: BoardColumn) -> some View {
        Text(emptyText(column))
            .font(.footnote)
            .foregroundStyle(Theme.tertiaryText)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
    }

    private func emptyText(_ column: BoardColumn) -> String {
        switch column.key {
        case "running": String(localized: "Nothing's running. Cards in Ready start when a slot is free.")
        case "blocked": String(localized: "Nothing's stuck.")
        case "review": String(localized: "Nothing to review.")
        case "ready": String(localized: "No cards waiting to start.")
        default: String(localized: "No cards.")
        }
    }

    @ViewBuilder
    private func columnFootnote(_ column: BoardColumn) -> some View {
        if column.key == "running", let limit = model.maxRunning {
            Text(limit == 1
                 ? String(localized: "Hermes runs 1 card at a time on \(model.gatewayName).")
                 : String(localized: "Hermes runs up to \(limit) cards at once on \(model.gatewayName)."))
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
        }
    }

    /// A card that opens (pushed on iPhone, the inspector or a sheet elsewhere), with its
    /// long-press menu, and the gateway's warning under it when nothing will pick it up.
    private func cardButton(_ card: BoardCard) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                open(card)
            } label: {
                BoardCardView(model: model, card: card, isSelected: !isCompact && (model.openCardID == card.id || model.selection.contains(card.id)))
            }
            .buttonStyle(PressableStyle())
            .contextMenu { BoardCardMenuItems(model: model, card: card) }
            if let warning = model.warnings[card.id] {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }

    private func open(_ card: BoardCard) {
        #if os(macOS)
        // ⌘-click picks several for Move, Assign and Archive.
        if NSEvent.modifierFlags.contains(.command) {
            if model.selection.isEmpty, let open = model.openCardID { model.selection.insert(open) }
            if model.selection.contains(card.id) { model.selection.remove(card.id) } else { model.selection.insert(card.id) }
            model.openCardID = nil
            return
        }
        model.selection = []
        #endif
        model.openCardID = card.id
    }

    // MARK: iPad and Mac (`ipadBoard`, `macBoard`)

    private var columnsBoard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ProjectTile(appearance: projects.appearance(projectID), size: isMac ? 24 : 26)
                Text("\(model.projectName) Board")
                    .font(isMac ? .title3.weight(.semibold) : .title2.weight(.semibold))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Text(columnsSubtitle)
                    .font(isMac ? .caption : .subheadline)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            if model.selection.count > 1 { bulkBar }
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(model.columns) { column in
                        columnPanel(column)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.automatic)
        }
        .padding(.top, isMac ? 12 : 4)
    }

    private var isMac: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    /// The columns a dragged card can't go to dim.
    private func isDimmed(_ column: BoardColumn) -> Bool {
        guard let id = model.draggingCardID, let card = model.card(id), card.column != column.key else { return false }
        return !(model.workflow?.allows(from: card.column, to: column.key) ?? false)
    }

    private func columnPanel(_ column: BoardColumn) -> some View {
        let cards = model.cards(in: column.key)
        let targeted = targetedColumn == column.key && !isDimmed(column) && model.draggingCardID.flatMap(model.card)?.column != column.key
        return VStack(alignment: .leading, spacing: 10) {
            BoardColumnHeader(title: column.title, count: cards.count, onAdd: addAction(column))
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(cards) { card in
                        cardButton(card)
                            .draggable(card.id)
                            .modifier(DragSessionTracker(model: model, cardID: card.id))
                    }
                    if cards.isEmpty { emptyColumn(column) }
                    columnFootnote(column)
                }
                .padding(.bottom, 8)
            }
            .scrollIndicators(.never)
        }
        .padding(10)
        .frame(width: columnWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.controlFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Theme.ink, lineWidth: targeted ? 1.5 : 0)
        }
        .opacity(isDimmed(column) ? 0.4 : 1)
        .animation(Theme.snappy, value: model.draggingCardID)
        .dropDestination(for: String.self) { ids, _ in
            drop(ids, on: column)
        } isTargeted: { isTargeted in
            if isTargeted { targetedColumn = column.key } else if targetedColumn == column.key { targetedColumn = nil }
        }
    }

    /// A drop moves the card if the workflow allows it; anything else snaps back.
    private func drop(_ ids: [String], on column: BoardColumn) -> Bool {
        defer {
            model.draggingCardID = nil
            targetedColumn = nil
        }
        guard let id = ids.first, let card = model.card(id), card.column != column.key,
              model.workflow?.allows(from: card.column, to: column.key) == true else { return false }
        Task { await model.move(card, to: column.key) }
        return true
    }

    /// ⌘-clicked cards: Move, Assign and Archive at once (`POST /tasks/bulk`).
    private var bulkBar: some View {
        let ids = Array(model.selection)
        let columns = model.workflow?.columns.filter(\.isDropTarget) ?? []
        return HStack(spacing: 10) {
            Text(BoardCopy.cards(ids.count) + String(localized: " selected"))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.primaryText)
            Spacer()
            Menu("Move To") {
                ForEach(columns) { column in
                    Button(column.title) { Task { await model.move(ids, to: column.key) } }
                }
            }
            .fixedSize()
            Menu("Assign To") {
                ForEach(model.assignableProfiles, id: \.self) { profile in
                    Button(model.name(of: profile)) { Task { await model.assign(ids, to: profile) } }
                }
            }
            .fixedSize()
            Button("Archive", systemImage: "archivebox") { Task { await model.archive(ids) } }
            Button("Clear", systemImage: "xmark") { model.selection = [] }
                .labelStyle(.iconOnly)
                .help("Clear Selection")
        }
        .controlSize(.regular)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 20)
    }

    // MARK: Toolbar and notices

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        #if os(iOS)
        ToolbarItem(placement: .topBarLeading) {
            Button {
                workspace.selection = .project(projectID)
            } label: {
                Image(systemName: "chevron.left")
            }
            .accessibilityLabel(String(localized: "Back to \(model.projectName)"))
        }
        #else
        if let onToggleSidebar {
            ToolbarItem(placement: .navigation) {
                Button(action: onToggleSidebar) { SidebarGlyph() }
                    .accessibilityLabel("Show sidebar")
            }
        }
        ToolbarSpacer(.flexible)
        #endif
        if !isCompact {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Show", selection: Binding(get: { model.assigneeFilter }, set: { model.assigneeFilter = $0 })) {
                        Text("Everyone's Cards").tag(String?.none)
                        ForEach(model.assignableProfiles, id: \.self) { profile in
                            Text(model.name(of: profile)).tag(String?.some(profile))
                        }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                        .symbolVariant(model.assigneeFilter == nil ? .none : .circle.fill)
                }
                .accessibilityLabel("Show cards for")
                .help("Show cards for")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            #if os(macOS)
            Button("New Card") { model.newCard = BoardModel.NewCardTarget() }
                .inkDefaultButton()
                .help("New Card (⌘N)")
                .disabled(!model.isOnline || model.workflow == nil)
            #else
            Button("New Card", systemImage: "plus") { model.newCard = BoardModel.NewCardTarget() }
                .disabled(!model.isOnline || model.workflow == nil)
            #endif
        }
    }

    @ViewBuilder
    private var noticeView: some View {
        if let notice = model.notice {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(Theme.danger)
                Text(notice)
                    .font(.subheadline)
                    .foregroundStyle(Theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Dismiss", systemImage: "xmark") { withAnimation(Theme.snappy) { model.notice = nil } }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.secondaryText)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: 520)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: notice) {
                try? await Task.sleep(for: .seconds(6))
                withAnimation(Theme.snappy) { model.notice = nil }
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// How a card opens: pushed on iPhone, in the inspector on iPad landscape and the Mac, as a sheet
/// on iPad portrait.
private struct BoardCardPresentation: ViewModifier {
    @Bindable var model: BoardModel
    let isCompact: Bool
    let usesInspector: Bool

    func body(content: Content) -> some View {
        if isCompact {
            content
                .navigationDestination(item: $model.openCardID) { id in
                    BoardCardDetailView(model: model, cardID: id)
                }
        } else if usesInspector {
            content
                .inspector(isPresented: Binding(get: { model.openCardID != nil }, set: { if !$0 { model.openCardID = nil } })) {
                    Group {
                        if let id = model.openCardID {
                            BoardCardDetailView(model: model, cardID: id, inInspector: true)
                                .id(id)
                        }
                    }
                    .inspectorColumnWidth(min: 320, ideal: 380, max: 460)
                }
        } else {
            content
                .sheet(item: Binding(get: { model.openCardID.map(OpenCard.init) }, set: { model.openCardID = $0?.id })) { open in
                    NavigationStack {
                        BoardCardDetailView(model: model, cardID: open.id)
                            .toolbar {
                                ToolbarItem(placement: .cancellationAction) {
                                    Button("Done", systemImage: "xmark") { model.openCardID = nil }
                                }
                            }
                    }
                    .presentationDetents([.large])
                }
        }
    }

    private struct OpenCard: Identifiable {
        let id: String
    }
}

/// Which card is being dragged, so the columns it can't go to dim (iOS 27, macOS 26).
private struct DragSessionTracker: ViewModifier {
    let model: BoardModel
    let cardID: String

    func body(content: Content) -> some View {
        if #available(iOS 27.0, macOS 26.0, *) {
            content.onDragSessionUpdated { session in
                switch session.phase {
                case .initial, .active:
                    if model.draggingCardID != cardID { model.draggingCardID = cardID }
                case .ended, .dataTransferCompleted:
                    model.draggingCardID = nil
                default:
                    break
                }
            }
        } else {
            content
        }
    }
}
