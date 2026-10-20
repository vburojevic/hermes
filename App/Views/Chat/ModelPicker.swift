import HermesKit
import SwiftUI

/// The title of the chat: which bot and model will answer. Tapping opens the picker.
struct ModelPickerButton: View {
    @Bindable var conversation: ConversationModel
    let workspace: BotWorkspace

    @State private var isPresented = false

    /// "Claude Sonnet 4.6" (`blocks/toolbars.elyx` `modelPicker`).
    private var title: String {
        if let model = conversation.model {
            return ModelNames.display(model.model)
        }
        if let key = conversation.stableKey, let model = workspace.session(forKey: key)?.model, !model.isEmpty {
            return ModelNames.display(model)
        }
        return workspace.defaultModelName.map(ModelNames.display) ?? workspace.bot.name
    }

    var body: some View {
        Button {
            isPresented = true
        } label: {
            HStack(spacing: 7) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.tertiaryText)
            }
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Model: \(title)")
        .accessibilityHint("Choose the model Hermes uses in this chat")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            ModelPickerView(conversation: conversation, workspace: workspace) {
                isPresented = false
            }
            .presentationCompactAdaptation(.sheet)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .task {
            if workspace.modelOptions == nil {
                await workspace.loadModelOptions()
            }
        }
    }
}

struct ModelPickerView: View {
    @Bindable var conversation: ConversationModel
    let workspace: BotWorkspace
    let onDone: () -> Void

    @State private var query = ""
    @State private var expandedProviders: Set<String> = []

    private var providers: [ModelProvider] {
        workspace.modelOptions?.usableProviders ?? []
    }

    /// Providers Hermes reports without credentials (`authenticated: false`): shown, not hidden,
    /// with the way to give them a key (`docs/setup.md` §4.3).
    private var needingKeys: [ModelProvider] {
        workspace.modelOptions?.providers.filter { $0.authenticated == false } ?? []
    }

    @State private var addingKeyFor: ModelProvider?

    var body: some View {
        Group {
            #if os(macOS)
            macBody
            #else
            listBody
            #endif
        }
        .sheet(item: $addingKeyFor) { provider in
            ProviderKeySheet(problem: ProviderProblem(kind: .key(envVar: nil), provider: provider.slug, providerLabel: provider.name),
                             gatewayName: workspace.bot.name) { key in
                try await workspace.saveProviderKey(key, slug: provider.slug)
            }
        }
    }

    /// A provider without a key: its name, and Add Key… when Bot Mode can take one.
    private func needsKeyRow(_ provider: ModelProvider) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.name).foregroundStyle(Theme.primaryText)
                Text(provider.warning ?? String(localized: "No key on \(workspace.bot.name)"))
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer()
            if workspace.roster?.isConnected == true {
                Button("Add Key…") { addingKeyFor = provider }
                    .cardButton()
                    .controlSize(.small)
            }
        }
    }

    #if os(macOS)
    /// The Mac's compact popover (`screens/mac/sheets.elyx` `macModelPicker`): search, then the
    /// models with their provider and price.
    private var macBody: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Theme.tertiaryText)
                TextField("Search models", text: $query)
                    .textFieldStyle(.plain)
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Theme.controlFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(8)
            ScrollView {
                VStack(spacing: 2) {
                    macRow(title: String(localized: "Gateway default"), subtitle: workspace.defaultModelName, isSelected: conversation.model == nil) {
                        select(nil)
                    }
                    ForEach(providers) { provider in
                        let models = visibleModels(for: provider)
                        if !models.isEmpty {
                            Divider().padding(.vertical, 4)
                            ForEach(models, id: \.self) { model in
                                macRow(
                                    title: ModelNames.display(model),
                                    subtitle: [provider.name, provider.isCurrent && model == workspace.modelOptions?.model ? String(localized: "Default") : nil, provider.pricing?[model].flatMap(shortPrice)].compactMap { $0 }.joined(separator: " · "),
                                    isSelected: conversation.model == ModelSelection(provider: provider.slug, model: model),
                                    isDisabled: provider.isUnavailable(model)
                                ) {
                                    select(ModelSelection(provider: provider.slug, model: model))
                                }
                            }
                            if query.isEmpty && provider.models.count > models.count {
                                Button("Show all \(provider.models.count)") { expandedProviders.insert(provider.slug) }
                                    .buttonStyle(.plain)
                                    .font(.caption)
                                    .foregroundStyle(Theme.secondaryText)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                            }
                        }
                    }
                    if !needingKeys.isEmpty {
                        Divider().padding(.vertical, 4)
                        ForEach(needingKeys) { provider in
                            needsKeyRow(provider)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                        }
                    }
                    if workspace.modelOptions == nil, let error = workspace.modelOptionsError {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(error).font(.caption).foregroundStyle(Theme.secondaryText)
                            Button("Try Again") { Task { await workspace.loadModelOptions(refresh: true) } }
                                .controlSize(.small)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                    } else if workspace.modelOptions == nil {
                        SkeletonRows(count: 3).padding(10)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
            Divider()
            HStack {
                Text(providers.isEmpty ? String(localized: "No other models on this gateway") : String(localized: "\(providers.reduce(0) { $0 + $1.models.count }) models"))
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
                Button {
                    Task { await workspace.loadModelOptions(refresh: true) }
                } label: {
                    if workspace.isRefreshingModels {
                        Spinner(size: .mini)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.secondaryText)
                .help("Refresh models from all providers")
                .disabled(workspace.isRefreshingModels)
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
        }
        .frame(width: 300, height: 380)
    }

    private func macRow(title: String, subtitle: String?, isSelected: Bool, isDisabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.bold))
                    .opacity(isSelected ? 1 : 0)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.callout)
                        .foregroundStyle(isDisabled ? Theme.tertiaryText : Theme.primaryText)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(isSelected ? Theme.rowSelected : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func shortPrice(_ pricing: ModelProvider.Pricing) -> String? {
        if pricing.free == true { return String(localized: "Free") }
        guard let input = pricing.input, let output = pricing.output else { return nil }
        return "\(input) / \(output)"
    }
    #endif

    private var listBody: some View {
        NavigationStack {
            List {
                Section {
                    row(
                        title: String(localized: "Gateway default"),
                        subtitle: workspace.defaultModelName,
                        isSelected: conversation.model == nil
                    ) {
                        select(nil)
                    }
                }
                ForEach(providers) { provider in
                    let models = visibleModels(for: provider)
                    if !models.isEmpty {
                        Section {
                            ForEach(models, id: \.self) { model in
                                row(
                                    title: ModelNames.display(model),
                                    subtitle: model.contains("/") ? model : provider.pricing?[model].flatMap(priceLabel),
                                    isSelected: conversation.model == ModelSelection(provider: provider.slug, model: model),
                                    isDisabled: provider.isUnavailable(model)
                                ) {
                                    select(ModelSelection(provider: provider.slug, model: model))
                                }
                            }
                            if query.isEmpty && provider.models.count > models.count {
                                Button("Show all \(provider.models.count)") {
                                    expandedProviders.insert(provider.slug)
                                }
                                .font(.footnote.weight(.medium))
                            }
                        } header: {
                            HStack {
                                Text(provider.name)
                                if provider.isCurrent {
                                    Text("Default")
                                        .font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Theme.surfaceRaised, in: Capsule())
                                }
                            }
                        } footer: {
                            if let warning = provider.warning {
                                Text(warning)
                            }
                        }
                    }
                }
                if !needingKeys.isEmpty {
                    Section {
                        ForEach(needingKeys) { provider in
                            needsKeyRow(provider)
                        }
                    } header: {
                        Text("Needs a key")
                    } footer: {
                        Text("Hermes on \(workspace.bot.name) has no key for these. Or add one there with `hermes model`.")
                    }
                }
                if workspace.modelOptions == nil, let error = workspace.modelOptionsError {
                    Section {
                        Text(error).foregroundStyle(Theme.secondaryText)
                        Button("Try Again") { Task { await workspace.loadModelOptions(refresh: true) } }
                    }
                } else if workspace.modelOptions == nil {
                    Section { SkeletonRows(count: 3) }
                } else if providers.isEmpty {
                    Section {
                        Text("Hermes didn't report any other models. Configure providers with `hermes model` on the gateway.")
                            .font(.footnote)
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
            }
            #if os(macOS)
            .listStyle(.inset)
            #else
            .listStyle(.insetGrouped)
            #endif
            .searchable(text: $query, prompt: "Search models")
            .navigationTitle("Model")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                }
                ToolbarItem(placement: Self.refreshPlacement) {
                    Button {
                        Task { await workspace.loadModelOptions(refresh: true) }
                    } label: {
                        if workspace.isRefreshingModels {
                            Spinner()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .help("Refresh models from all providers")
                    .accessibilityLabel("Refresh models")
                    .disabled(workspace.isRefreshingModels)
                }
            }
        }
        #if os(macOS)
        .frame(width: 380, height: 520)
        #endif
    }

    private static var refreshPlacement: ToolbarItemPlacement {
        #if os(iOS)
        .topBarLeading
        #else
        .automatic
        #endif
    }

    private func visibleModels(for provider: ModelProvider) -> [String] {
        if !query.isEmpty {
            return provider.models.filter {
                $0.localizedCaseInsensitiveContains(query) || provider.name.localizedCaseInsensitiveContains(query)
            }
        }
        if expandedProviders.contains(provider.slug) {
            return provider.models
        }
        let featured = (provider.featuredModels ?? []).filter(provider.models.contains)
        var shortlist = featured.isEmpty ? Array(provider.models.prefix(6)) : featured
        if let selected = conversation.model, selected.provider == provider.slug, !shortlist.contains(selected.model) {
            shortlist.insert(selected.model, at: 0)
        }
        return shortlist
    }

    private func priceLabel(_ pricing: ModelProvider.Pricing) -> String? {
        if pricing.free == true { return String(localized: "Free") }
        guard let input = pricing.input, let output = pricing.output else { return nil }
        return String(localized: "\(input) in · \(output) out per 1M")
    }

    private func select(_ selection: ModelSelection?) {
        conversation.model = selection
        workspace.rememberModelChoice(selection, effort: conversation.reasoningEffort)
        onDone()
    }

    private func row(title: String, subtitle: String?, isSelected: Bool, isDisabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(isDisabled ? Theme.tertiaryText : Theme.primaryText)
                    if let subtitle, subtitle != title {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(Theme.tertiaryText)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.primaryText)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
