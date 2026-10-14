import HermesKit
import SwiftUI

// The pieces every request card is built from (`blocks/actions.elyx`): header, choice rows,
// fields, fine print, code box, answer tiles and the footer pair.

extension View {
    /// The docked request card: one Liquid Glass panel above the composer.
    func requestCard() -> some View {
        self
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }
}

/// Kind tile, title, who's asking, how long Hermes will wait, and the … menu (`actionHeader`).
struct RequestHeader<MenuContent: View>: View {
    let symbol: String
    var tint: Color = Theme.warning
    var tileFill: Color = Theme.warningTint
    let title: String
    let subtitle: String
    var deadline: Date?
    @ViewBuilder var menu: () -> MenuContent

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tileFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Theme.primaryText)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            if let deadline {
                CountdownChip(deadline: deadline)
            }
            if MenuContent.self != EmptyView.self {
                Menu(content: menu) {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.secondaryText)
                        .frame(width: 30, height: 30)
                        .background(Theme.controlFill, in: Circle())
                        .contentShape(Circle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("More")
            }
        }
    }
}

extension RequestHeader where MenuContent == EmptyView {
    init(symbol: String, tint: Color = Theme.warning, tileFill: Color = Theme.warningTint, title: String, subtitle: String, deadline: Date? = nil) {
        self.init(symbol: symbol, tint: tint, tileFill: tileFill, title: title, subtitle: subtitle, deadline: deadline, menu: { EmptyView() })
    }
}

/// How long Hermes keeps waiting ("4:52").
struct CountdownChip: View {
    let deadline: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = max(0, deadline.timeIntervalSince(context.date))
            Label(Duration.seconds(remaining).formatted(.time(pattern: .minuteSecond)), systemImage: "timer")
                .labelStyle(.titleAndIcon)
                .font(.caption.monospacedDigit())
                .foregroundStyle(remaining < 30 ? Theme.danger : Theme.secondaryText)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(Theme.controlFill, in: Capsule())
                .accessibilityLabel(Text("Waits \(Duration.seconds(remaining).formatted(.units(allowed: [.minutes, .seconds], width: .wide)))"))
        }
    }
}

/// A tappable answer (`choiceRow`, `checkRow`): radio or checkbox, label and detail.
struct ChoiceRow: View {
    enum Style { case radio, check }

    let label: String
    var detail: String?
    var style: Style = .radio
    var isSelected = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 18))
                    .foregroundStyle(isSelected ? Theme.primaryText : Theme.placeholderText)
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(.subheadline)
                        .foregroundStyle(Theme.primaryText)
                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(minHeight: 46)
            .background(isSelected && style == .check ? Theme.surfaceRaised : Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                if isSelected, style == .radio {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.primaryText, lineWidth: 2)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var symbol: String {
        switch style {
        case .radio: isSelected ? "checkmark.circle.fill" : "circle"
        case .check: isSelected ? "checkmark.square" : "square"
        }
    }
}

/// "Something else…": becomes a field with Send (`otherRow`).
struct OtherAnswerRow: View {
    @Binding var text: String
    @Binding var isEditing: Bool
    let onSend: (String) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if isEditing {
                HStack(spacing: 8) {
                    TextField("Your answer", text: $text, axis: .vertical)
                        .font(.subheadline)
                        .lineLimit(1...4)
                        .textFieldStyle(.plain)
                        .focused($focused)
                        .onSubmit { send() }
                    Button(action: send) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Theme.inkForeground)
                            .frame(width: 28, height: 28)
                            .background(Theme.ink, in: Circle())
                    }
                    .buttonStyle(PressableStyle())
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Send")
                }
                .padding(.leading, 14)
                .padding(.trailing, 8)
                .padding(.vertical, 8)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .onAppear { focused = true }
            } else {
                Button {
                    isEditing = true
                } label: {
                    Label("Something else…", systemImage: "pencil")
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryText)
                        .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
                        .padding(.horizontal, 14)
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hairline, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(PressableStyle())
            }
        }
    }

    private func send() {
        let answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { return }
        onSend(answer)
    }
}

/// A masked value (`maskedField`): reveal on the right; Paste only in empty key fields on
/// iPhone and iPad.
struct MaskedField: View {
    let placeholder: String
    @Binding var text: String
    var symbol = "key"
    var isPassword = false
    var allowsPaste = true
    var onSubmit: () -> Void = {}

    @State private var revealed = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(Theme.tertiaryText)
            Group {
                if revealed {
                    TextField(placeholder, text: $text)
                } else {
                    SecureField(placeholder, text: $text)
                }
            }
            .font(.body)
            .textFieldStyle(.plain)
            .focused($focused)
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .textContentType(isPassword ? .password : nil)
            #endif
            .onSubmit(onSubmit)
            Button {
                revealed.toggle()
            } label: {
                Image(systemName: revealed ? "eye.slash" : "eye")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.tertiaryText)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(revealed ? "Hide" : "Show")
            #if os(iOS)
            if allowsPaste, !isPassword, text.isEmpty {
                PasteButton(payloadType: String.self) { values in
                    if let value = values.first { text = value.trimmingCharacters(in: .whitespacesAndNewlines) }
                }
                .labelStyle(.titleOnly)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .tint(Theme.surfaceRaised)
            }
            #endif
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(height: 46)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(focused ? Theme.link : Theme.hairline, lineWidth: focused ? 2 : 1)
        }
    }
}

/// A plain value inside a card (usernames, optional settings).
struct PlainField: View {
    let placeholder: String
    @Binding var text: String
    var symbol: String?
    var contentType: TextContentKind = .none

    enum TextContentKind { case none, username }

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.tertiaryText)
            }
            TextField(placeholder, text: $text)
                .font(.body)
                .textFieldStyle(.plain)
                .focused($focused)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .textContentType(contentType == .username ? .username : nil)
                #endif
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(focused ? Theme.link : Theme.hairline, lineWidth: focused ? 2 : 1)
        }
    }
}

/// Where a value goes and how long it's kept (`finePrint`). Part of the trust model: keep it.
struct FinePrint: View {
    var symbol = "lock.shield"
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(Theme.tertiaryText)
            Text(text)
                .font(.footnote)
                .foregroundStyle(Theme.tertiaryText)
        }
    }
}

/// A command or variable in monospace, with an optional risk chip (`codeBox`).
struct CodeBox: View {
    let text: String
    var risk: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(Theme.Typography.code)
                    .foregroundStyle(Theme.primaryText)
                    .textSelection(.enabled)
                    .fixedSize()
            }
            if let risk, !risk.isEmpty {
                TagLabel(title: risk, symbol: "exclamationmark.triangle.fill", style: .danger)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
    }
}

/// One answer with its scope spelled out (`actionTile`): every option visible at once.
struct ActionTile: View {
    enum Style { case normal, primary, danger }

    let symbol: String
    let title: String
    let detail: String
    var style: Style = .normal
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(titleColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(titleColor)
                        .lineLimit(2)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(detailColor)
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 11)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity, minHeight: 82, alignment: .topLeading)
            .background(fill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                if style != .primary {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(style == .danger ? Theme.dangerBorder : Theme.hairline, lineWidth: 0.5)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(title), \(detail)"))
    }

    private var fill: Color {
        switch style {
        case .normal: Theme.surface
        case .primary: Theme.ink
        case .danger: Theme.dangerWash
        }
    }

    private var titleColor: Color {
        switch style {
        case .normal: Theme.primaryText
        case .primary: Theme.inkForeground
        case .danger: Theme.danger
        }
    }

    private var detailColor: Color {
        switch style {
        case .normal: Theme.secondaryText
        case .primary: Theme.inkForegroundSecondary
        case .danger: Theme.secondaryText
        }
    }
}

/// The footer pair: secondary on the left, primary on the right, equal widths.
struct CardFooter: View {
    let secondary: String
    let onSecondary: () -> Void
    let primary: String
    var primaryEnabled = true
    let onPrimary: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onSecondary) {
                Text(secondary)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.primaryText)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Theme.controlFill, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(PressableStyle())
            .keyboardShortcut(.cancelAction)
            Button(action: onPrimary) {
                Text(primary)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.inkForeground)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Theme.ink.opacity(primaryEnabled ? 1 : 0.35), in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(PressableStyle())
            .disabled(!primaryEnabled)
            .keyboardShortcut(.defaultAction)
        }
    }
}
