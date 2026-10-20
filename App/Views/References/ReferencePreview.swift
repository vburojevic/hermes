import HermesKit
import SwiftUI

/// What a pill previews.
enum PreviewItem: Hashable {
    case reference(MessageReference)
    case skill(String)
}

/// A pill's preview (`referencePreview`, `referencePreviewSkill`, `referencePreviewFile`): what
/// it is, its status, then Remove (in the composer) and Open.
struct ReferencePreviewCard: View {
    let item: PreviewItem
    /// Composer only.
    var onRemove: (() -> Void)?
    var onDismiss: () -> Void = {}

    @Environment(\.references) private var references
    @State private var peek: GatewayFile.Peek?
    @State private var isPeeking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch item {
            case .reference(let reference) where reference.kind == .bot:
                botCard(reference.value)
            case .reference(let reference):
                fileCard(GatewayFile(path: reference.value, isFolder: reference.kind == .folder))
            case .skill(let name):
                skillCard(name)
            }
            buttons
        }
        .padding(16)
        .frame(width: 300, alignment: .leading)
        .task(id: item) {
            guard case .reference(let reference) = item, reference.kind != .bot else { return }
            isPeeking = true
            peek = await references.peek(GatewayFile(path: reference.value, isFolder: reference.kind == .folder))
            isPeeking = false
        }
    }

    // MARK: Kinds

    @ViewBuilder
    private func botCard(_ handle: String) -> some View {
        let bot = references.bot(handle: handle)
        HStack(spacing: 10) {
            if let bot, let roster = references.roster {
                BotFace(appearance: roster.appearance(for: bot), size: 36)
            } else {
                tile("at")
            }
            header(title: bot?.title ?? "@" + handle, subtitle: String(localized: "@\(handle) · Bot"))
        }
        if let role = bot?.role, !role.isEmpty {
            Text(role)
                .font(.subheadline)
                .foregroundStyle(Theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        let online = references.roster?.isConnected == true
        HStack(spacing: 6) {
            Circle()
                .fill(online ? Theme.success : Theme.tertiaryText)
                .frame(width: 7, height: 7)
            Text(online ? String(localized: "Online · \(references.gatewayName)") : String(localized: "Offline · \(references.gatewayName)"))
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func skillCard(_ name: String) -> some View {
        let entry = references.skill(name)
        HStack(spacing: 10) {
            tile("book.closed")
            header(title: name, subtitle: [String(localized: "Skill"), entry?.category].compactMap { $0 }.joined(separator: " · "))
        }
        if let summary = entry?.summary, !summary.isEmpty {
            Text(summary)
                .font(.subheadline)
                .foregroundStyle(Theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func fileCard(_ file: GatewayFile) -> some View {
        HStack(spacing: 10) {
            tile(file.isFolder ? "folder" : "doc.text")
            header(title: file.name, subtitle: [file.directory, references.gatewayName, peek?.sizeText].compactMap { $0 }.joined(separator: " · "))
        }
        if let text = peek?.text, !text.isEmpty {
            Text(verbatim: Self.firstLines(text))
                .font(.caption.monospaced())
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(5)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityLabel(Text("First lines: \(Self.firstLines(text))"))
        } else if isPeeking {
            SkeletonRows(count: 3, twoLines: false)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        }
    }

    static func firstLines(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).prefix(5).joined(separator: "\n")
    }

    private func tile(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Theme.primaryText)
            .frame(width: 36, height: 36)
            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityHidden(true)
    }

    private func header(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: title)
                .font(.headline)
                .foregroundStyle(Theme.primaryText)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(verbatim: subtitle)
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Actions

    private var openTitle: String {
        switch item {
        case .reference(let reference) where reference.kind == .bot: String(localized: "Open Chat")
        case .reference: String(localized: "Open File")
        case .skill: String(localized: "Show Skill")
        }
    }

    private var canOpen: Bool {
        switch item {
        case .reference(let reference) where reference.kind == .bot: references.bot(handle: reference.value) != nil
        case .reference: references.roster != nil
        case .skill: references.workspace != nil
        }
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            if let onRemove {
                Button {
                    onDismiss()
                    onRemove()
                } label: {
                    Text("Remove").frame(maxWidth: .infinity)
                }
                .buttonStyle(PreviewButtonStyle())
            }
            if canOpen {
                Button {
                    onDismiss()
                    open()
                } label: {
                    Text(openTitle).frame(maxWidth: .infinity)
                }
                .buttonStyle(PreviewButtonStyle())
            }
        }
    }

    private func open() {
        switch item {
        case .reference(let reference) where reference.kind == .bot:
            if let bot = references.bot(handle: reference.value) { references.openChat(with: bot) }
        case .reference(let reference):
            references.openFile(reference)
        case .skill(let name):
            references.showSkill(name)
        }
    }
}

/// The preview's two buttons: grey capsules, the same weight.
private struct PreviewButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Theme.primaryText)
            .frame(height: 36)
            .background(Theme.surfaceRaised, in: Capsule())
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Capsule())
    }
}

/// A file on the gateway, opened from its pill: the start of it, in mono.
struct GatewayFileSheet: View {
    let file: GatewayFile

    @Environment(\.dismiss) private var dismiss
    @Environment(\.references) private var references
    @State private var peek: GatewayFile.Peek?
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            ScrollView {
                Group {
                    if let text = peek?.text {
                        Text(verbatim: text)
                            .font(Theme.Typography.code)
                            .foregroundStyle(Theme.primaryText)
                            .textSelection(.enabled)
                    } else if loaded {
                        Text("Hermes couldn't read this file on \(references.gatewayName).")
                            .foregroundStyle(Theme.secondaryText)
                    } else {
                        SkeletonRows(count: 4, twoLines: false)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .background(Theme.canvas)
            .navigationTitle(file.name)
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
        .frame(minWidth: 520, minHeight: 480)
        #endif
        .task {
            peek = await references.peek(file, bytes: 60_000)
            loaded = true
        }
    }
}
