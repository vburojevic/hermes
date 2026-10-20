import HermesKit
import SwiftUI

/// Memory (`screens/iphone/memory.elyx`: `memoryPage`, `memoryNotes`, `memoryOptions`,
/// `botMemory`; `screens/ipad/memory.elyx` → `ipadMemory`): what Hermes, or one Bot, remembers.
/// iPhone and iPad portrait: one store at a time under tabs, then the options. iPad landscape:
/// both stores side by side, the options behind the … button.
struct MemoryView: View {
    @Bindable var model: MemoryModel

    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var width: CGFloat = 0
    @State private var editing: MemoryEditTarget?
    @State private var forgetting: MemoryEntry?
    @State private var resetting = false
    @State private var showsProvider = false
    @State private var scrollsToOptions = false
    @State private var showsLearned = false

    /// iPad landscape (`ipadMemory`).
    private var isWide: Bool {
        #if os(iOS)
        sizeClass == .regular && width >= 900
        #else
        false
        #endif
    }

    var body: some View {
        ScrollView {
            Group {
                if isWide { wide } else { narrow }
            }
            .padding(.horizontal, isWide ? 24 : 16)
            .padding(.top, 4)
            .padding(.bottom, 24)
            .frame(maxWidth: isWide ? .infinity : Theme.readableWidth)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.sheetBackground)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .navigationTitle("Memory")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if isWide {
                ToolbarItem(placement: .primaryAction) { optionsMenu }
            }
        }
        .task(id: model.isOnline) {
            guard model.isOnline else { return }
            if model.list == nil {
                await model.load()
            } else if !model.hasLoadedPending {
                await model.loadPending()
            }
        }
        .refreshable { await model.load() }
        #if DEBUG
        .task { await openDebugRoute() }
        #endif
        .sheet(item: $editing) { target in
            MemoryEditSheet(model: model, target: target)
        }
        .navigationDestination(isPresented: $showsProvider) {
            MemoryProviderPicker(model: model)
        }
        // What Hermes Learned (`docs/memory.md` §3a): memories and skills over time, on the map.
        .navigationDestination(isPresented: $showsLearned) {
            LearnedHost(workspace: model.workspace, scope: model.scope) { showsLearned = false }
        }
        .modifier(MemoryConfirmations(model: model, forgetting: $forgetting, resetting: $resetting))
        .modifier(MemoryToast(text: $model.toast))
    }

    // MARK: iPhone, iPad portrait

    private var narrow: some View {
        ScrollViewReader { proxy in
            narrowContent
                .onChange(of: scrollsToOptions) { if scrollsToOptions { withAnimation { proxy.scrollTo("options", anchor: .top) } } }
        }
    }

    private var narrowContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            MemoryHeadline(model: model)
                .padding(.horizontal, 4)
            MemoryTabs(selection: $model.tab, badges: badges)
                .padding(.top, 14)
            if hasNotice {
                notice.padding(.top, 16)
            }
            if model.settings?.isOff == true {
                MemoryEmptyState(isOff: true) { Task { await model.turnOn() } }
                    .padding(.top, 20)
            } else {
                storeContent(model.tab)
                    .padding(.top, 14)
                footer
                    .padding(.top, 10)
                // The empty state has its own Tell Hermes Something.
                if !model.entries(in: model.tab).isEmpty || model.list == nil {
                    tellButton
                        .padding(.top, 20)
                }
            }
            options
                .padding(.top, 28)
                .id("options")
        }
    }

    #if DEBUG
    /// `-HERMES_MEMORY notes|options|edit:<n>|notes-edit:<n>|reset` (screenshots).
    private func openDebugRoute() async {
        guard let route = DebugFlags.memory else { return }
        for _ in 0..<40 where model.list == nil { try? await Task.sleep(for: .milliseconds(250)) }
        try? await Task.sleep(for: .milliseconds(400))
        if route.hasPrefix("notes") { model.tab = .notes }
        if route.hasSuffix("options") { scrollsToOptions = true }
        if route == "reset" { scrollsToOptions = true; resetting = true }
        if let colon = route.firstIndex(of: ":"), route.contains("edit"), let index = Int(route[route.index(after: colon)...]) {
            let entries = model.entries(in: model.tab)
            if entries.indices.contains(index) { editing = MemoryEditTarget(entry: entries[index], index: index) }
        }
    }
    #endif

    // MARK: iPad landscape

    private var wide: some View {
        VStack(alignment: .leading, spacing: 16) {
            MemoryHeadline(model: model, extra: String(localized: "It reads this at the start of every chat; changes apply from the next one."))
            if hasNotice { notice }
            if model.settings?.isOff == true {
                MemoryEmptyState(isOff: true) { Task { await model.turnOn() } }
            } else {
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 12) {
                        columnTitle(.about)
                        storeContent(.about)
                        tellButton.padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 12) {
                        columnTitle(.notes)
                        storeContent(.notes)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func columnTitle(_ store: MemoryStoreKind) -> some View {
        Text(MemoryCopy.storeTitle(store))
            .font(.title3.weight(.semibold))
            .foregroundStyle(Theme.primaryText)
            .accessibilityAddTraits(.isHeader)
    }

    /// The options on iPad landscape: Saving, the provider, Reset Memory….
    private var optionsMenu: some View {
        Menu {
            Section("Saving") {
                Toggle("Remember Things About You", isOn: storeBinding(.about))
                Toggle("Keep Notes About Your Setup", isOn: storeBinding(.notes))
                Toggle("Ask Before Saving", isOn: askBinding)
            }
            Button("Memory Provider: \(model.status?.activeTitle ?? String(localized: "Built-in"))", systemImage: "externaldrive") {
                showsProvider = true
            }
            Divider()
            Button("Reset Memory…", systemImage: "arrow.counterclockwise", role: .destructive) { resetting = true }
        } label: {
            Image(systemName: "ellipsis")
        }
        .disabled(!model.isOnline)
        .accessibilityLabel("Memory Options")
    }

    // MARK: One store

    private var badges: [MemoryStoreKind: Int] {
        Dictionary(uniqueKeysWithValues: MemoryStoreKind.allCases.map { ($0, model.pending(in: $0).count) })
    }

    @ViewBuilder
    private func storeContent(_ store: MemoryStoreKind) -> some View {
        let pending = model.pending(in: store)
        let entries = model.entries(in: store)
        VStack(alignment: .leading, spacing: 0) {
            if !pending.isEmpty {
                MemorySectionTitle(text: String(localized: "Waiting for Review · \(pending.count)"))
                MemoryCard {
                    ForEach(Array(pending.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { MemoryCardSeparator() }
                        MemoryPendingRow(item: item) {
                            Task { await model.approve(item) }
                        } discard: {
                            Task { await model.discard(item) }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                }
                .padding(.bottom, 16)
            }
            if model.list != nil, !entries.isEmpty {
                MemoryMeter(store: store, count: entries.count, fraction: model.fraction(in: store))
                    .padding(.bottom, 10)
            }
            if entries.isEmpty {
                if model.list != nil, model.settings?.isEnabled(store) != false {
                    MemoryCard {
                        MemoryEmptyState(isOff: false) { model.tellSomething() }
                            .padding(.horizontal, 16)
                    }
                } else if model.settings?.isEnabled(store) == false {
                    MemoryCard {
                        Text(store == .about
                             ? String(localized: "Remembering things about you is off. Turn it on below.")
                             : String(localized: "Keeping notes about your setup is off. Turn it on below."))
                            .font(.subheadline)
                            .foregroundStyle(Theme.secondaryText)
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else if model.isLoading || model.list == nil, model.isOnline {
                    MemoryCard {
                        SkeletonRows(count: 3)
                            .padding(16)
                    }
                }
            } else {
                MemoryCard {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { MemoryCardSeparator() }
                        MemoryEntryRow(entry: entry, isNew: model.isNew(entry)) {
                            editing = MemoryEditTarget(entry: entry, index: index)
                        } forget: {
                            forgetting = entry
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                }
            }
        }
    }

    private var footer: some View {
        Text(model.bot == nil
             ? "\(MemoryCopy.appliesNext) \(String(localized: "It also tidies these up as it learns."))"
             : String(localized: "\(model.keeperName) reads this at the start of every chat, so changes apply from your next one. Each Bot keeps its own memory, separate from Hermes and from other Bots."))
            .font(.footnote)
            .foregroundStyle(Theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
    }

    private var tellButton: some View {
        MemoryCard {
            Button {
                model.tellSomething()
            } label: {
                Text("Tell \(model.keeperName) Something to Remember…")
                    .foregroundStyle(Theme.link)
                    .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                    .padding(.horizontal, 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Options (`memoryOptions`)

    private var options: some View {
        VStack(alignment: .leading, spacing: 0) {
            MemorySectionTitle(text: String(localized: "Saving"))
            MemoryCard {
                MemoryToggleRow(title: String(localized: "Remember Things About You"), isOn: storeBinding(.about))
                MemoryCardSeparator()
                MemoryToggleRow(title: String(localized: "Keep Notes About Your Setup"), isOn: storeBinding(.notes))
                MemoryCardSeparator()
                MemoryToggleRow(title: String(localized: "Ask Before Saving"), subtitle: String(localized: "Review each change before it's kept"), isOn: askBinding)
            }
            .disabled(!model.isOnline || model.settings == nil)
            MemoryFootnote(text: String(localized: "\(model.keeperName) asks in the chat before it changes memory. Changes made while nobody can answer (tasks, background reviews) wait here for review."))

            MemorySectionTitle(text: String(localized: "What \(model.keeperName) Learned")).padding(.top, 22)
            MemoryCard {
                Button {
                    showsLearned = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles").foregroundStyle(Theme.primaryText)
                        Text("What \(model.keeperName) Learned").foregroundStyle(Theme.primaryText)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.tertiaryText)
                    }
                    .frame(minHeight: 52)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.needsBotMode)
            }
            MemoryFootnote(text: String(localized: "Memories and the skills \(model.keeperName) wrote, over time and on a map."))

            MemorySectionTitle(text: String(localized: "Where Memory Lives")).padding(.top, 22)
            MemoryCard {
                Button {
                    showsProvider = true
                } label: {
                    HStack(spacing: 8) {
                        Text("Memory Provider").foregroundStyle(Theme.primaryText)
                        Spacer()
                        Text(providerNotReady != nil ? String(localized: "\(model.status?.activeTitle ?? "") · not set up") : (model.status?.activeTitle ?? String(localized: "Built-in")))
                            .foregroundStyle(providerNotReady != nil ? Theme.warning : Theme.secondaryText)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.tertiaryText)
                    }
                    .frame(minHeight: 52)
                    .padding(.horizontal, 16)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .disabled(!model.isOnline)
            if let setup = providerNotReady {
                // The active provider isn't set up: Hermes falls back to built-in (`docs/setup.md` §4.4).
                VStack(alignment: .leading, spacing: 8) {
                    Text([setup.detail, setup.fallback].compactMap { $0 }.joined(separator: " "))
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                    SetupSteps(steps: setup.steps)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            } else {
                MemoryFootnote(text: String(localized: "Built-in memory is two small files on \(model.gatewayName). Other providers (Honcho, Mem0, …) add long-term recall; they are set up on the gateway."))
            }

            MemoryCard {
                Button {
                    resetting = true
                } label: {
                    Text("Reset Memory…")
                        .foregroundStyle(Theme.danger)
                        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                        .padding(.horizontal, 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .disabled(!model.isOnline)
            .padding(.top, 24)
            MemoryFootnote(text: String(localized: "Erases everything \(model.keeperName) remembers on \(model.gatewayName). Chats and skills stay."))
        }
    }

    private func storeBinding(_ store: MemoryStoreKind) -> Binding<Bool> {
        Binding(get: { model.settings?.isEnabled(store) ?? true },
                set: { value in Task { await model.setEnabled(store, value) } })
    }

    private var askBinding: Binding<Bool> {
        Binding(get: { model.settings?.askBeforeSaving ?? false },
                set: { value in Task { await model.setAskBeforeSaving(value) } })
    }

    /// The provider in use isn't set up on the gateway: its setup, else nil.
    private var providerNotReady: SetupStatus? {
        guard let memory = model.status else { return nil }
        var facts = model.workspace.setup.facts
        facts.botMode = .online
        facts.memory = memory
        let status = GatewaySetup.memory(facts)
        return status.state == .limited ? status : nil
    }

    // MARK: Offline

    private var hasNotice: Bool {
        model.needsBotMode || !model.isOnline || (model.loadError != nil && model.list == nil)
    }

    @ViewBuilder
    private var notice: some View {
        if model.needsBotMode {
            MemoryNotice(symbol: "server.rack", title: String(localized: "Turn on Bot Mode for \(model.gatewayName)"),
                         detail: String(localized: "Memory is read and edited over Bot Mode's connection."),
                         linksBotMode: model.workspace)
        } else if !model.isOnline {
            MemoryNotice(symbol: "wifi.slash", title: String(localized: "\(model.gatewayName) is offline"),
                         detail: String(localized: "Memory shows when it's back."))
        } else if let error = model.loadError, model.list == nil {
            MemoryNotice(symbol: "exclamationmark.triangle", title: String(localized: "Couldn't read memory"), detail: error)
        }
    }
}

// MARK: - Building blocks

/// A white card on the sheet's grey (`sheet-cell`, 26 pt corners).
struct MemoryCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.sheetCell, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }
}

struct MemoryCardSeparator: View {
    var body: some View {
        Rectangle()
            .fill(Theme.separator)
            .frame(height: 0.5)
            .padding(.leading, 16)
    }
}

/// "Waiting for Review · 2", "Saving" (`formSectionTitle`).
struct MemorySectionTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Theme.secondaryText)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .accessibilityAddTraits(.isHeader)
    }
}

struct MemoryFootnote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(Theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
            .padding(.top, 8)
    }
}

struct MemoryToggleRow: View {
    let title: String
    var subtitle: String?
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(Theme.primaryText)
                if let subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
        .padding(.vertical, subtitle == nil ? 0 : 6)
    }
}

/// Offline, no Bot Mode, or a read that failed.
struct MemoryNotice: View {
    let symbol: String
    let title: String
    let detail: String
    /// The gateway whose Bot Mode a button links (`docs/setup.md` §4.1).
    var linksBotMode: BotWorkspace?

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.primaryText)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if let linksBotMode {
                    BotModeLinkButton(workspace: linksBotMode)
                        .padding(.top, 6)
                }
            }
        } icon: {
            Image(systemName: symbol).foregroundStyle(Theme.warning)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.warningTint, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
