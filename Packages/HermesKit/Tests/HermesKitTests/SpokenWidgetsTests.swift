import Foundation
import Testing
@testable import HermesKit

/// Listen to the brief (`docs/voice.md` §3): widgets as words, a stack as a brief.
struct SpokenWidgetsTests {
    private static func example(_ name: String) throws -> WidgetPayload {
        let json = try #require(WidgetSpec.shared.examples().first { $0.name == name }?.json)
        guard case .ready(let payload) = WidgetReader.read(json) else {
            Issue.record("\(name) didn't read")
            throw CancellationError()
        }
        return payload
    }

    @Test func stackIsABriefOfItsWidgets() throws {
        let stack = try Self.example("stack-1")
        let words = SpokenWidgets.words(of: stack, locale: Locale(identifier: "en_US"))
        let parts = words.text.components(separatedBy: "\n\n")
        // The intro, then each widget's own words in order: never the stack's, which repeats them.
        #expect(parts.first == "Your Friday brief: Morning brief.")
        #expect(parts.count == 1 + stack.children.count)
        #expect(Array(parts.dropFirst()) == stack.children.map(\.envelope.fallbackText))
        #expect(!words.text.contains(stack.envelope.fallbackText))
        #expect(words.isPrivate)
    }

    @Test func newerChildRevisionWins() throws {
        let stack = try Self.example("stack-1")
        var newer = try #require(stack.children.first)
        newer.envelope.rev += 1
        newer.envelope.fallbackText = "Updated summary."
        let words = SpokenWidgets.words(of: stack, stored: { $0 == newer.id ? newer : nil }, locale: Locale(identifier: "en_US"))
        #expect(words.text.components(separatedBy: "\n\n")[1] == "Updated summary.")
    }

    @Test func replyTextReadsWidgetsAsWords() throws {
        let stack = try Self.example("stack-1")
        let directive = "Here's today.\n\n::widget{id=\"\(stack.id)\" alt=\"Morning brief\"}\n\nAnything else?"
        let words = SpokenWidgets.words(of: directive, inlineWidgets: true, stored: { $0 == stack.id ? stack : nil }, locale: Locale(identifier: "en_US"))
        #expect(words.text.hasPrefix("Here's today.\n\nYour Friday brief: Morning brief."))
        #expect(words.text.hasSuffix("Anything else?"))

        // Not in the store: its alt.
        let unknown = SpokenWidgets.words(of: directive, inlineWidgets: true, stored: { _ in nil })
        #expect(unknown.text == "Here's today.\n\nMorning brief\n\nAnything else?")
        #expect(!unknown.isPrivate)

        // Plain prose is untouched.
        #expect(SpokenWidgets.words(of: "Just words.", inlineWidgets: true, stored: { _ in nil }) == .init(text: "Just words."))
    }
}
