import HermesKit
import SwiftUI

// How a feature that needs something configured says so (`docs/setup.md` §2,
// `docs/design-to-swiftui.md` §8): its state, the fix the app can make, the steps to take
// elsewhere and what still works, drawn the same way for every feature. Each view takes a
// `SetupStatus` from the feature's producer; the actions stay with the feature.

/// "Ready", "Partly set up", "Not set up", "Checking…", "Can't check".
struct SetupStateLabel: View {
    let state: SetupStatus.State

    var body: some View {
        HStack(spacing: 5) {
            if state == .checking {
                Spinner()
            } else {
                Image(systemName: symbol)
                    .foregroundStyle(color)
                    .imageScale(.medium)
            }
            Text(Self.title(state))
                .foregroundStyle(Theme.secondaryText)
        }
        .font(.caption)
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    static func title(_ state: SetupStatus.State) -> String {
        switch state {
        case .checking: String(localized: "Checking…")
        case .ready: String(localized: "Ready")
        case .limited: String(localized: "Partly set up")
        case .notSetUp: String(localized: "Not set up")
        case .unknown: String(localized: "Can't check")
        }
    }

    private var symbol: String {
        switch state {
        case .ready: "checkmark.circle.fill"
        case .limited: "exclamationmark.circle.fill"
        case .notSetUp: "circle.dashed"
        case .unknown, .checking: "questionmark.circle"
        }
    }

    private var color: Color {
        switch state {
        case .ready: Theme.success
        case .limited: Theme.warning
        case .notSetUp: Theme.secondaryText
        case .unknown, .checking: Theme.tertiaryText
        }
    }
}

/// The steps to set a feature up elsewhere, numbered when there's more than one, each with its
/// command to copy.
struct SetupSteps: View {
    let steps: [SetupStep]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if steps.count > 1 {
                        Text("\(index + 1).")
                            .monospacedDigit()
                            .foregroundStyle(Theme.secondaryText)
                            .accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(step.text)
                            .foregroundStyle(Theme.primaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        if let command = step.command {
                            SetupCommand(command: command)
                        }
                    }
                }
            }
        }
        .font(.subheadline)
    }
}

/// A command or config line, monospaced and selectable, with a Copy button.
struct SetupCommand: View {
    let command: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 4) {
            Text(command)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(Theme.primaryText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)
                .padding(.leading, 12)
            Button {
                Pasteboard.copy(command)
                copied = true
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(copied ? Theme.success : Theme.secondaryText)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(copied ? Text("Copied") : Text("Copy"))
            .accessibilityHint(Text(command))
            .help("Copy")
        }
        .surface(radius: 10)
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}

/// Check Again: asks once more, with a spinner while it does.
struct SetupCheckButton: View {
    let check: () async -> Void
    var style = Style.row
    @State private var isChecking = false

    enum Style {
        /// A Form row.
        case row
        /// A capsule, in cards and full-area messages.
        case card
    }

    var body: some View {
        let button = Button {
            Task {
                isChecking = true
                await check()
                isChecking = false
            }
        } label: {
            if style == .row {
                // A Label, so its glyph lines up with Learn More's.
                Label {
                    Text(isChecking ? "Checking…" : "Check Again")
                } icon: {
                    if isChecking { Spinner() } else { Image(systemName: "arrow.clockwise") }
                }
            } else {
                HStack(spacing: 6) {
                    if isChecking { Spinner() }
                    Text(isChecking ? "Checking…" : "Check Again")
                }
            }
        }
        .disabled(isChecking)
        switch style {
        case .row: button
        case .card: button.cardButton()
        }
    }
}

/// Learn More: Hermes Agent's page about the feature.
struct SetupDocsLink: View {
    let url: URL

    var body: some View {
        if WebLink.isWeb(url) {
            Link(destination: url) {
                Label("Learn More", systemImage: "book")
            }
        }
    }
}

// MARK: - In a Form

/// A fix that asks first (it restarts Hermes, or changes how the dashboard runs). The dialog
/// hangs off the fix button itself, so on iPad and the Mac it points at the button.
struct SetupConfirmation {
    var title: String
    var message: String
    var action: String
}

/// A feature's setup as a Form section (Settings pages): the state and what it means, what still
/// works, the fix, the steps, Check Again and Learn More. A ready feature is one row.
struct SetupSection<Controls: View>: View {
    let status: SetupStatus
    var showsTitle = true
    var check: (() async -> Void)?
    var fix: (() -> Void)?
    var confirm: SetupConfirmation?
    @ViewBuilder var controls: Controls
    @State private var confirming = false

    init(
        _ status: SetupStatus,
        showsTitle: Bool = true,
        check: (() async -> Void)? = nil,
        fix: (() -> Void)? = nil,
        confirm: SetupConfirmation? = nil,
        @ViewBuilder controls: () -> Controls
    ) {
        self.status = status
        self.showsTitle = showsTitle
        self.check = check
        self.fix = fix
        self.confirm = confirm
        self.controls = controls()
    }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                SetupStateLabel(state: status.state)
                if let detail = status.detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(Theme.primaryText)
                }
                if let fallback = status.fallback {
                    Text(fallback)
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .combine)

            if status.state != .checking {
                controls
                if let title = status.fix?.title, let fix {
                    Button(title) {
                        if confirm == nil { fix() } else { confirming = true }
                    }
                    .confirmationDialog(confirm?.title ?? "", isPresented: $confirming, titleVisibility: .visible) {
                        Button(confirm?.action ?? title, action: fix)
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text(confirm?.message ?? "")
                    }
                }
            }
            if status.showsSteps {
                SetupSteps(steps: status.steps)
                    .padding(.vertical, 4)
            }
            if status.state != .ready, let check {
                SetupCheckButton(check: check)
            }
            if status.showsDocs, let docs = status.docs {
                SetupDocsLink(url: docs)
            }
        } header: {
            if showsTitle { Text(status.title) }
        }
    }
}

extension SetupSection where Controls == EmptyView {
    init(_ status: SetupStatus, showsTitle: Bool = true, check: (() async -> Void)? = nil, fix: (() -> Void)? = nil,
         confirm: SetupConfirmation? = nil) {
        self.init(status, showsTitle: showsTitle, check: check, fix: fix, confirm: confirm) { EmptyView() }
    }
}

/// A feature's own setup page, for `SetupRow`s whose feature has no page of its own.
struct FeatureSetupPage: View {
    let status: SetupStatus
    var check: (() async -> Void)?
    var fix: (() -> Void)?

    var body: some View {
        Form {
            SetupSection(status, showsTitle: false, check: check, fix: fix)
        }
        .formStyle(.grouped)
        .navigationTitle(status.title)
    }
}

/// A Settings row for a feature: its name, what its state means and the state, opening its page.
struct SetupRow<Destination: View>: View {
    let status: SetupStatus
    let symbol: String
    @ViewBuilder var destination: Destination
    @Environment(\.dynamicTypeSize) private var typeSize

    init(_ status: SetupStatus, symbol: String, @ViewBuilder destination: () -> Destination) {
        self.status = status
        self.symbol = symbol
        self.destination = destination()
    }

    var body: some View {
        NavigationLink {
            destination
        } label: {
            HStack(spacing: 12) {
                GlyphTile(symbol: symbol, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(status.title)
                        .foregroundStyle(Theme.primaryText)
                    if let line = Self.line(status) {
                        Text(line)
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                    }
                    // Large text: the state under the name, so neither is squeezed.
                    if typeSize.isAccessibilitySize {
                        SetupStateLabel(state: status.state)
                    }
                }
                Spacer(minLength: 8)
                if !typeSize.isAccessibilitySize {
                    SetupStateLabel(state: status.state)
                }
            }
        }
    }

    /// What's in use when ready, otherwise what's missing; what still works when that's all
    /// there is.
    static func line(_ status: SetupStatus) -> String? {
        status.detail ?? status.fallback
    }
}

// MARK: - Outside a Form

/// A feature's setup as a card, on pages that aren't Forms (the top of a page, a panel, the
/// Inspector): the same parts as `SetupSection`, with the fix as the card's one ink button.
struct SetupCard<Controls: View>: View {
    let status: SetupStatus
    var check: (() async -> Void)?
    var fix: (() -> Void)?
    @ViewBuilder var controls: Controls

    init(
        _ status: SetupStatus,
        check: (() async -> Void)? = nil,
        fix: (() -> Void)? = nil,
        @ViewBuilder controls: () -> Controls
    ) {
        self.status = status
        self.check = check
        self.fix = fix
        self.controls = controls()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(status.title)
                        .font(.headline)
                        .foregroundStyle(Theme.primaryText)
                    Spacer(minLength: 8)
                    SetupStateLabel(state: status.state)
                }
                if let detail = status.detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(Theme.primaryText)
                }
                if let fallback = status.fallback {
                    Text(fallback)
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)

            if status.state != .checking {
                controls
            }
            if status.showsSteps {
                SetupSteps(steps: status.steps)
            }
            SetupActions(status: status, check: check, fix: fix)
        }
        .padding(16)
        .surface(radius: Theme.Radius.card)
    }
}

extension SetupCard where Controls == EmptyView {
    init(_ status: SetupStatus, check: (() async -> Void)? = nil, fix: (() -> Void)? = nil) {
        self.init(status, check: check, fix: fix) { EmptyView() }
    }
}

/// A full-area message for a panel or page whose feature isn't set up (the Board without Bot
/// Mode, Learned without the curator): `StateMessage`'s layout with the steps and actions.
struct SetupMessage: View {
    let status: SetupStatus
    let symbol: String
    /// The title, when the feature's name alone doesn't say it ("The Board needs Bot Mode").
    var headline: String?
    var check: (() async -> Void)?
    var fix: (() -> Void)?

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(Theme.tertiaryText)
                    .padding(.bottom, 4)
                    .accessibilityHidden(true)
                Text(headline ?? status.title)
                    .font(.headline)
                    .foregroundStyle(Theme.primaryText)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                if let detail = status.detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryText)
                        .multilineTextAlignment(.center)
                }
                if let fallback = status.fallback {
                    Text(fallback)
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryText)
                        .multilineTextAlignment(.center)
                }
                if status.showsSteps {
                    SetupSteps(steps: status.steps)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .surface(radius: Theme.Radius.card)
                        .padding(.top, 4)
                }
                SetupActions(status: status, check: check, fix: fix, centred: true)
                    .padding(.top, 6)
            }
            .frame(maxWidth: 440)
            .padding(32)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .defaultScrollAnchor(.center, for: .alignment)
    }
}

/// A card's or message's buttons: the fix in ink, Check Again beside it, Learn More last.
private struct SetupActions: View {
    let status: SetupStatus
    var check: (() async -> Void)?
    var fix: (() -> Void)?
    var centred = false

    private var fixTitle: String? {
        guard status.state != .checking, fix != nil else { return nil }
        return status.fix?.title
    }

    private var showsCheck: Bool { status.state != .ready && check != nil }
    private var docs: URL? { status.showsDocs ? status.docs : nil }

    var body: some View {
        if fixTitle != nil || showsCheck || docs != nil {
            VStack(alignment: centred ? .center : .leading, spacing: 10) {
                if fixTitle != nil || showsCheck {
                    HStack(spacing: 10) {
                        if showsCheck, let check {
                            SetupCheckButton(check: check, style: .card)
                        }
                        if let fixTitle, let fix {
                            Button(fixTitle, action: fix)
                                .inkFilledButton()
                        }
                    }
                }
                if let docs {
                    SetupDocsLink(url: docs)
                        .font(.subheadline)
                }
            }
            .frame(maxWidth: centred ? nil : .infinity, alignment: .leading)
        }
    }
}

/// One line where a feature runs on its fallback or can't run (the Talk screen, the Listen
/// player): what's happening and why, with a button to its setup.
struct SetupNote: View {
    let status: SetupStatus
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: status.state == .limited ? "info.circle" : "exclamationmark.circle")
                .foregroundStyle(Theme.secondaryText)
                .accessibilityHidden(true)
            Text(text)
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if let action {
                Button(actionTitle ?? String(localized: "Set Up…"), action: action)
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.link)
                    .fontWeight(.medium)
            }
        }
        .font(.footnote)
        .accessibilityElement(children: .combine)
    }

    private var text: String {
        status.state == .limited ? (status.fallback ?? status.detail ?? status.title) : (status.detail ?? status.title)
    }
}
