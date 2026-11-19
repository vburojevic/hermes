#if os(macOS)
import AppKit
import SwiftUI

/// The Mac's search fields (the sidebar's and the ⌘K palette's), an `NSTextField` of their own
/// (`docs/search.md` §3). A SwiftUI `TextField` there hears only what's typed through the field
/// editor, so text an accessibility client set while the field wasn't being edited (Voice Control,
/// VoiceOver, automation) showed in the field and never reached the search, which kept showing the
/// results for the text before it.
struct MacSearchField: NSViewRepresentable {
    /// The keys the field offers its owner while it's being edited, before handling them itself.
    enum Key {
        case up
        case down
        case escape
        /// Return, or ⌘Return to open in a new window.
        case open(newWindow: Bool)
        /// ⌘ and a digit.
        case command(digit: Int)
    }

    @Binding var text: String
    let prompt: String
    var font: NSFont = .systemFont(ofSize: 13)
    /// Bumped to put the field in focus (⌥⌘F, Show All Results).
    var focusRequest = 0
    /// Puts the field in focus as it appears (the palette).
    var focusesOnAppear = false
    /// Answers whether the owner took the key. Esc the owner leaves clears the field.
    var onKey: (Key) -> Bool = { _ in false }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, focusRequest: focusRequest, onKey: onKey)
    }

    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = font
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.stringValue = text
        field.delegate = context.coordinator
        field.focusesOnAppear = focusesOnAppear
        let coordinator = context.coordinator
        field.onSet = { [weak coordinator] value in coordinator?.take(value) }
        field.onKey = { [weak coordinator] key in coordinator?.onKey(key) ?? false }
        return field
    }

    func updateNSView(_ field: Field, context: Context) {
        let coordinator = context.coordinator
        coordinator.text = $text
        coordinator.onKey = onKey
        if field.stringValue != text {
            field.stringValue = text
        }
        // The placeholder names the field, as it did for the SwiftUI field, with no label beside
        // it that VoiceOver could read out a second time.
        if field.placeholderString != prompt {
            field.placeholderString = prompt
        }
        if coordinator.focusRequest != focusRequest {
            coordinator.focusRequest = focusRequest
            field.window?.makeFirstResponder(field)
        }
    }

    /// Hands every change on to the search: typed ones through the delegate, set ones through
    /// `onSet`.
    final class Field: NSTextField {
        override class var cellClass: AnyClass? {
            get { Cell.self }
            set {}
        }

        var focusesOnAppear = false
        var onKey: ((Key) -> Bool)?

        var onSet: ((String) -> Void)? {
            get { (cell as? Cell)?.onSet }
            set { (cell as? Cell)?.onSet = newValue }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard focusesOnAppear, let window else { return }
            focusesOnAppear = false
            window.makeFirstResponder(self)
        }

        /// ⌘Return and ⌘-digits arrive as key equivalents, which reach the window's views before
        /// the menus, so the menus' ⌘1 and ⌘2 wait while the owner takes them.
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard currentEditor() != nil, let onKey,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
            else { return super.performKeyEquivalent(with: event) }
            let key: Key?
            if event.keyCode == 36 || event.keyCode == 76 {
                key = .open(newWindow: true)
            } else if let digit = event.charactersIgnoringModifiers.flatMap(Int.init), (1...9).contains(digit) {
                key = .command(digit: digit)
            } else {
                key = nil
            }
            if let key, onKey(key) { return true }
            return super.performKeyEquivalent(with: event)
        }
    }

    /// An accessibility client's write lands in the cell, not in `NSTextField`'s own setters, so
    /// the cell is where a set value is heard. Overriding the field's `setAccessibilityValue`
    /// instead takes the write away from AppKit, and nothing is set at all. While the field is
    /// edited the delegate hears every change, and reading the cell's value then sets it again
    /// from the field editor, which would land back here, so the cell stays out of it.
    final class Cell: NSTextFieldCell {
        var onSet: ((String) -> Void)?

        /// Its own field editor, so the window's shared one keeps its settings: a search term is
        /// searched as typed, never corrected, replaced or completed first.
        private lazy var editor: NSTextView = {
            let editor = NSTextView()
            editor.isFieldEditor = true
            editor.isAutomaticSpellingCorrectionEnabled = false
            editor.isAutomaticTextReplacementEnabled = false
            editor.inlinePredictionType = .no
            return editor
        }()

        override func fieldEditor(for controlView: NSView) -> NSTextView? {
            editor
        }

        override var objectValue: Any? {
            didSet {
                guard (controlView as? NSControl)?.currentEditor() == nil else { return }
                onSet?(stringValue)
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var focusRequest: Int
        var onKey: (Key) -> Bool

        init(text: Binding<String>, focusRequest: Int, onKey: @escaping (Key) -> Bool) {
            self.text = text
            self.focusRequest = focusRequest
            self.onKey = onKey
        }

        func take(_ value: String) {
            if text.wrappedValue != value {
                text.wrappedValue = value
            }
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            take(field.stringValue)
        }

        /// ↑, ↓, Esc and Return go to the owner first; Esc it leaves clears the field when it has
        /// text.
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)):
                return onKey(.up)
            case #selector(NSResponder.moveDown(_:)):
                return onKey(.down)
            case #selector(NSResponder.insertNewline(_:)):
                return onKey(.open(newWindow: NSApp.currentEvent?.modifierFlags.contains(.command) == true))
            case #selector(NSResponder.cancelOperation(_:)):
                if onKey(.escape) { return true }
                guard !text.wrappedValue.isEmpty else { return false }
                text.wrappedValue = ""
                return true
            default:
                return false
            }
        }
    }
}
#endif
