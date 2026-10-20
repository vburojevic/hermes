import HermesMarkdown
import SwiftUI

/// A fenced code block: language label, copy button, horizontally scrolling tinted code. A block
/// with a very long line wraps instead, and a very long block shows its start (`CodeBlockLayout`):
/// one text run past a few thousand points draws nothing at all.
struct CodeBlockView: View {
    let language: String?
    let code: String

    @State private var copied = false
    @Environment(\.markdownCaches) private var caches

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(CodeHighlighter.displayName(for: language) ?? String(localized: "Code"))
                    .font(Theme.Typography.caption.weight(.medium))
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
                Button {
                    Pasteboard.copy(code)
                    withAnimation(Theme.snappy) { copied = true }
                    Task {
                        try? await Task.sleep(for: .seconds(1.6))
                        withAnimation(Theme.snappy) { copied = false }
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "square.on.square")
                        .font(Theme.Typography.caption.weight(.medium))
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.secondaryText)
                .accessibilityLabel(copied ? Text("Copied") : Text("Copy code"))
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 6)

            let shown = CodeBlockLayout.shown(code)
            if CodeBlockLayout.wraps(shown.text) {
                Text(Self.highlight(shown.text, language: language, caches: caches))
                    .font(Theme.Typography.code)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, shown.hidden > 0 ? 6 : 14)
                    .padding(.top, 2)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(Self.highlight(shown.text, language: language, caches: caches))
                        .font(Theme.Typography.code)
                        .lineSpacing(2)
                        .fixedSize(horizontal: true, vertical: true)
                        .padding(.horizontal, 14)
                        .padding(.bottom, shown.hidden > 0 ? 6 : 14)
                        .padding(.top, 2)
                }
            }
            if shown.hidden > 0 {
                Text("\(shown.hidden) more characters. Copy copies all of it.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.tertiaryText)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            }
        }
        .surface()
        .sensoryFeedback(.success, trigger: copied) { _, new in new }
    }

    static func highlight(_ code: String, language: String?, caches: Bool = true) -> AttributedString {
        guard caches else {
            // Still streaming: the finished lines are highlighted once, the arriving one each time.
            return MarkdownCache.streamingHighlight(code, language: language) {
                attributed(CodeHighlighter.tokenize($0, language: language))
            }
        }
        return MarkdownCache.highlighted(code, language: language, build: attributed)
    }

    /// Off the main thread too: `MarkdownCache.prewarm` builds a transcript's code ahead.
    nonisolated static func attributed(_ tokens: [CodeHighlighter.Token]) -> AttributedString {
        var result = AttributedString()
        for token in tokens {
            var run = AttributedString(token.text)
            run.foregroundColor = color(for: token.kind)
            if token.kind == .inserted || token.kind == .deleted {
                run.backgroundColor = color(for: token.kind).opacity(0.12)
            }
            result += run
        }
        return result
    }

    nonisolated private static func color(for kind: CodeHighlighter.Token.Kind) -> Color {
        switch kind {
        case .plain: Theme.primaryText
        case .keyword: Theme.Syntax.keyword
        case .type: Theme.Syntax.type
        case .string: Theme.Syntax.string
        case .number: Theme.Syntax.number
        case .comment: Theme.Syntax.comment
        case .function: Theme.Syntax.function
        case .property: Theme.Syntax.property
        case .meta: Theme.Syntax.meta
        case .inserted: Theme.Syntax.inserted
        case .deleted: Theme.Syntax.deleted
        }
    }
}
