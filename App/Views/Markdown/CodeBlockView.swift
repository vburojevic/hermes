import HermesMarkdown
import SwiftUI

/// A fenced code block: language label, copy button, horizontally scrolling tinted code.
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

            ScrollView(.horizontal, showsIndicators: false) {
                Text(Self.highlight(code, language: language, caches: caches))
                    .font(Theme.Typography.code)
                    .lineSpacing(2)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
                    .padding(.top, 2)
            }
        }
        .surface()
        .sensoryFeedback(.success, trigger: copied) { _, new in new }
    }

    static func highlight(_ code: String, language: String?, caches: Bool = true) -> AttributedString {
        var result = AttributedString()
        let tokens = caches ? MarkdownCache.tokens(for: code, language: language) : CodeHighlighter.tokenize(code, language: language)
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

    private static func color(for kind: CodeHighlighter.Token.Kind) -> Color {
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
