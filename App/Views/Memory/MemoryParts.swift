import HermesKit
import SwiftUI

// The pieces every Memory screen is built from (`blocks/memory.elyx`): the fullness meter, an
// entry with its menu, a save waiting for review, the two-store tabs, the empty and off states.
// Content is never glass: entries sit on sheet cells.

/// How full a store is (`memoryMeter`, `memoryMeterFull`): from 90% it turns orange and says
/// Hermes will merge older entries.
struct MemoryMeter: View {
    let store: MemoryStoreKind
    let count: Int
    let fraction: Double

    private var nearlyFull: Bool { fraction >= 0.9 }
    private var percent: Int { Int((min(fraction, 1) * 100).rounded()) }

    private var label: String {
        let counted = MemoryCopy.count(count, in: store)
        return nearlyFull ? String(localized: "\(counted) · nearly full, Hermes will merge older ones") : counted
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(label)
                    .foregroundStyle(Theme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(nearlyFull ? "\(percent)%" : String(localized: "\(percent)% full"))
                    .foregroundStyle(nearlyFull ? Theme.warning : Theme.tertiaryText)
                    .monospacedDigit()
            }
            .font(.footnote)
            GeometryReader { geometry in
                Capsule()
                    .fill(Theme.controlFill)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(nearlyFull ? Theme.warning : Theme.secondaryText)
                            .frame(width: geometry.size.width * min(max(fraction, 0), 1))
                    }
            }
            .frame(height: 4)
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(MemoryCopy.count(count, in: store)), \(percent)% full"))
    }
}

/// One remembered thing (`memoryEntry`, `memoryEntryNew`): the text, "New in this chat", and
/// its … menu (also on a long press): Edit…, Copy, Forget.
struct MemoryEntryRow: View {
    let entry: MemoryEntry
    var isNew = false
    let edit: () -> Void
    let forget: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.text)
                    .foregroundStyle(Theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if isNew {
                    TagLabel(title: String(localized: "New in this chat"))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Menu {
                actions
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.tertiaryText)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle().inset(by: -8))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .contextMenu { actions }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(MemoryCopy.spoken(entry) + (isNew ? String(localized: ", new in this chat") : "")))
        .accessibilityAction(named: "Edit", edit)
        .accessibilityAction(named: "Copy") { Pasteboard.copy(entry.text) }
        .accessibilityAction(named: "Forget", forget)
    }

    @ViewBuilder
    private var actions: some View {
        Button("Edit…", systemImage: "pencil", action: edit)
        Button("Copy", systemImage: "doc.on.doc") { Pasteboard.copy(entry.text) }
        Divider()
        Button("Forget", systemImage: "trash", role: .destructive, action: forget)
    }
}

/// A save waiting for review (`memoryPendingRow`, `…Replace`, `…Remove`): what kind of change,
/// where it came from, the text, then Discard / Save (Keep / Forget for a removal).
struct MemoryPendingRow: View {
    let item: MemoryPending
    var compact = false
    let save: () -> Void
    let discard: () -> Void

    private var kind: (title: String, symbol: String) {
        switch item.action {
        case .add: (String(localized: "Add"), "plus")
        case .update: (String(localized: "Update"), "pencil")
        case .remove: (String(localized: "Forget"), "trash")
        }
    }

    private var origin: String {
        var parts: [String] = []
        if compact, let store = item.store { parts.append(MemoryCopy.storeLabel(store)) }
        parts.append(item.isBackground ? String(localized: "Background review") : String(localized: "While you were away"))
        return parts.joined(separator: " · ")
    }

    /// Read before the text: "Add to Hermes's notes".
    private var spokenAction: String {
        let store = MemoryCopy.storeLabel(item.store ?? .notes).lowercased()
        switch item.action {
        case .add: return String(localized: "Add to \(store)")
        case .update: return String(localized: "Update in \(store)")
        case .remove: return String(localized: "Forget from \(store)")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                TagLabel(title: kind.title, symbol: kind.symbol)
                Text(origin)
                    .font(.caption)
                    .foregroundStyle(Theme.tertiaryText)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(spokenAction))
            Text(item.text)
                .foregroundStyle(item.action == .remove ? Theme.secondaryText : Theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(action: discard) {
                    Text(item.action == .remove ? String(localized: "Keep") : String(localized: "Discard"))
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(Theme.controlFill, in: Capsule())
                        .contentShape(Capsule())
                }
                .foregroundStyle(Theme.primaryText)
                Button(action: save) {
                    Text(item.action == .remove ? String(localized: "Forget") : String(localized: "Save"))
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(Theme.ink, in: Capsule())
                        .contentShape(Capsule())
                }
                .foregroundStyle(Theme.inkForeground)
            }
            .font(.subheadline.weight(.semibold))
            .buttonStyle(PressableStyle())
        }
        .accessibilityElement(children: .contain)
    }
}

/// About You · Hermes's Notes: a full-width track with a raised pill on the chosen store, and
/// a count of saves to review on each (`memoryPage` tabs).
struct MemoryTabs: View {
    @Binding var selection: MemoryStoreKind
    var badges: [MemoryStoreKind: Int] = [:]

    @Namespace private var pill
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .subheadline) private var height: CGFloat = 32

    var body: some View {
        HStack(spacing: 2) {
            ForEach(MemoryStoreKind.allCases) { store in
                tab(store)
            }
        }
        .padding(3)
        .background(Theme.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 0.5))
        .animation(reduceMotion ? nil : Theme.snappy, value: selection)
        .accessibilityElement(children: .contain)
    }

    private func tab(_ store: MemoryStoreKind) -> some View {
        let isSelected = selection == store
        let badge = badges[store] ?? 0
        return Button {
            selection = store
        } label: {
            HStack(spacing: 6) {
                Text(MemoryCopy.storeTitle(store))
                    .font(.subheadline.weight(isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? Theme.primaryText : Theme.secondaryText)
                    .lineLimit(1)
                if badge > 0 {
                    Text("\(badge)")
                        .font(.caption2.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.inkForeground)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(Theme.ink, in: Capsule())
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: height)
            .background {
                if isSelected {
                    Capsule()
                        .fill(Palette.segmentSelected)
                        .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                        .matchedGeometryEffect(id: "pill", in: pill)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityValue(badge > 0 ? Text("\(badge) to review") : Text(""))
    }
}

/// "What Hermes on Studio Mac remembers" beside the gateway's avatar, or the Bot's face.
struct MemoryHeadline: View {
    let model: MemoryModel
    var extra: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Group {
                if let bot = model.bot, let roster = model.workspace.roster {
                    BotFace(appearance: roster.appearance(for: bot), size: 18)
                } else {
                    BotAvatar(bot: model.workspace.bot, size: 18)
                }
            }
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            .accessibilityHidden(true)
            Text(extra.map { "\(model.headline). \($0)" } ?? model.headline)
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Nothing remembered yet (`memoryEmpty`), or memory off (`memoryOff`).
struct MemoryEmptyState: View {
    let isOff: Bool
    let action: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "brain")
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(Theme.tertiaryText)
                .accessibilityHidden(true)
            Text(isOff ? String(localized: "Memory is off") : String(localized: "Nothing remembered yet"))
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.primaryText)
            Text(isOff
                 ? String(localized: "With memory on, Hermes keeps notes about you and your setup between chats, so you don't have to repeat yourself.")
                 : String(localized: "Hermes saves what's worth keeping as you chat: how you like things done, your setup, your projects. Or just tell it: “Remember that…”"))
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Group {
                if isOff {
                    Button(action: action) {
                        Text("Turn On Memory")
                            .padding(.horizontal, 16)
                            .frame(minHeight: 36)
                            .background(Theme.ink, in: Capsule())
                            .foregroundStyle(Theme.inkForeground)
                    }
                } else {
                    Button(action: action) {
                        Text("Tell Hermes Something")
                            .padding(.horizontal, 16)
                            .frame(minHeight: 36)
                            .background(Theme.controlFill, in: Capsule())
                            .foregroundStyle(Theme.primaryText)
                    }
                }
            }
            .font(.subheadline.weight(.semibold))
            .buttonStyle(PressableStyle())
            .padding(.top, 6)
        }
        .frame(maxWidth: 320)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity)
    }
}

/// A passing note at the bottom of the page: what a save replaced, a reset.
struct MemoryToast: ViewModifier {
    @Binding var text: String?

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let text {
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(3)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Theme.sheetCell, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.hairline))
                    .shadow(color: Theme.shadow, radius: 12, y: 4)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: text) {
                        AccessibilityNotification.Announcement(text).post()
                        try? await Task.sleep(for: .seconds(4))
                        withAnimation(Theme.snappy) { self.text = nil }
                    }
                    .onTapGesture { withAnimation(Theme.snappy) { self.text = nil } }
            }
        }
        .animation(Theme.snappy, value: text)
    }
}

/// The confirmations Memory always asks for (the gateway can't undo either): Forget, and Reset.
struct MemoryConfirmations: ViewModifier {
    let model: MemoryModel
    @Binding var forgetting: MemoryEntry?
    @Binding var resetting: Bool
    var onForgotten: () -> Void = {}

    func body(content: Content) -> some View {
        content
            .confirmationDialog("Forget this?", isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }),
                                titleVisibility: .visible, presenting: forgetting) { entry in
                Button("Forget", role: .destructive) {
                    // The entry goes at once; a refusal brings it back with a note.
                    Task { await model.forget(entry) }
                    onForgotten()
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("\(model.keeperName) won't remember it in new chats.")
            }
            .alert(Text("Reset \(model.keeperName)'s memory?"), isPresented: $resetting) {
                Button("Cancel", role: .cancel) {}
                Button("Reset", role: .destructive) { Task { await model.reset() } }
            } message: {
                Text("Everything \(model.keeperName) remembers about you and your setup on \(model.gatewayName) is erased (\(MemoryCopy.aboutCount(model.entries(in: .about).count)), \(MemoryCopy.notesCount(model.entries(in: .notes).count))). This can't be undone.")
            }
            .alert(model.refusal?.title ?? "", isPresented: Binding(get: { model.refusal != nil }, set: { if !$0 { model.refusal = nil } }),
                   presenting: model.refusal) { _ in
                Button("OK", role: .cancel) {}
            } message: { refusal in
                Text(refusal.message)
            }
    }
}
