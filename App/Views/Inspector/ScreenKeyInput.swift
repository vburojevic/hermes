import HermesKit
import SwiftUI

/// The keyboard during Take Control (`docs/inspector.md` §2.6): an invisible view that holds focus
/// and sends what's typed to the Bot Screen. Not a text field: an empty field gets no Backspace on
/// iOS (`deleteBackward` only reaches a field with text), and autocorrect and smart punctuation
/// would rewrite what's sent. Text comes through the system's text input, so the software
/// keyboard, dictation and other languages' keyboards work; keys that aren't text (arrows,
/// Escape, ⌃C) come straight from the hardware keyboard.
struct ScreenKeyInput {
    let screen: ScreenController
    /// Up while the person types into the screen; the view lets it go when it loses focus.
    @Binding var isActive: Bool
}

#if os(iOS)
extension ScreenKeyInput: UIViewRepresentable {
    func makeUIView(context: Context) -> KeyCatcher {
        let view = KeyCatcher()
        view.isAccessibilityElement = false
        return view
    }

    func updateUIView(_ view: KeyCatcher, context: Context) {
        view.send = { [weak screen] strokes in screen?.send(strokes) }
        view.resigned = { isActive = false }
        let wantsFocus = isActive
        // Becoming first responder mid-update raises the keyboard while SwiftUI lays out.
        Task { @MainActor in
            if wantsFocus, !view.isFirstResponder { _ = view.becomeFirstResponder() }
            if !wantsFocus, view.isFirstResponder { _ = view.resignFirstResponder() }
        }
    }

    final class KeyCatcher: UIView, UIKeyInput {
        var send: ([ScreenKeyboard.Stroke]) -> Void = { _ in }
        var resigned: () -> Void = {}
        /// Hardware keys handled here, by HID usage, until they come up: held keys go up on the
        /// screen then; a ⌃ letter was sent whole when it went down.
        private var held: [Int: (ScreenKeyboard.Key, ScreenKeyboard.Modifiers)?] = [:]

        override var canBecomeFirstResponder: Bool { true }

        override func resignFirstResponder() -> Bool {
            let resigned = super.resignFirstResponder()
            if resigned { self.resigned() }
            return resigned
        }

        // Always "has text", so Backspace on an empty input still calls deleteBackward.
        var hasText: Bool { true }

        func insertText(_ text: String) {
            send(ScreenKeyboard.strokes(typing: text))
        }

        func deleteBackward() {
            send(ScreenKeyboard.backspace)
        }

        // What's sent is exactly what was typed.
        var autocorrectionType: UITextAutocorrectionType = .no
        var autocapitalizationType: UITextAutocapitalizationType = .none
        var spellCheckingType: UITextSpellCheckingType = .no
        var smartQuotesType: UITextSmartQuotesType = .no
        var smartDashesType: UITextSmartDashesType = .no
        var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
        var inlinePredictionType: UITextInlinePredictionType = .no
        var keyboardType: UIKeyboardType = .default
        var returnKeyType: UIReturnKeyType = .default

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            var others = Set<UIPress>()
            for press in presses where !(press.key.map(handle) ?? false) {
                others.insert(press)
            }
            if !others.isEmpty { super.pressesBegan(others, with: event) }
        }

        override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            let others = release(presses)
            if !others.isEmpty { super.pressesEnded(others, with: event) }
        }

        override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            let others = release(presses)
            if !others.isEmpty { super.pressesCancelled(others, with: event) }
        }

        private func release(_ presses: Set<UIPress>) -> Set<UIPress> {
            var others = Set<UIPress>()
            for press in presses {
                guard let code = press.key?.keyCode.rawValue, let entry = held.removeValue(forKey: code) else {
                    others.insert(press)
                    continue
                }
                if let (key, modifiers) = entry { send(ScreenKeyboard.strokes(key, modifiers: modifiers, down: false)) }
            }
            return others
        }

        /// A key this view sends itself: one that isn't text, or Backspace, Return and Tab with a
        /// modifier the text system would drop. ⌘ shortcuts stay the app's. ⌃ and a letter is
        /// sent as Control and the letter.
        private func handle(_ key: UIKey) -> Bool {
            guard !key.modifierFlags.contains(.command) else { return false }
            let code = key.keyCode.rawValue
            let modifiers = Self.modifiers(key.modifierFlags)
            if let special = ScreenKeyboard.key(hidUsage: code) {
                if special.arrivesAsText, modifiers.isEmpty { return false }
                held[code] = (special, modifiers)
                send(ScreenKeyboard.strokes(special, modifiers: modifiers, down: true))
                return true
            }
            if modifiers.contains(.control), let character = key.charactersIgnoringModifiers.first {
                held[code] = .some(nil)
                send(ScreenKeyboard.strokes(control: character, modifiers: modifiers))
                return true
            }
            return false
        }

        private static func modifiers(_ flags: UIKeyModifierFlags) -> ScreenKeyboard.Modifiers {
            var modifiers: ScreenKeyboard.Modifiers = []
            if flags.contains(.shift) { modifiers.insert(.shift) }
            if flags.contains(.control) { modifiers.insert(.control) }
            if flags.contains(.alternate) { modifiers.insert(.option) }
            return modifiers
        }
    }
}
#else
extension ScreenKeyInput: NSViewRepresentable {
    func makeNSView(context: Context) -> KeyCatcher {
        KeyCatcher()
    }

    func updateNSView(_ view: KeyCatcher, context: Context) {
        view.send = { [weak screen] strokes in screen?.send(strokes) }
        view.resigned = { isActive = false }
        let wantsFocus = isActive
        Task { @MainActor in
            guard let window = view.window else { return }
            if wantsFocus, window.firstResponder !== view { window.makeFirstResponder(view) }
            if !wantsFocus, window.firstResponder === view { window.makeFirstResponder(nil) }
        }
    }

    /// Keys by key code, text from the event's characters: no input method, so nothing is
    /// corrected or substituted on the way.
    final class KeyCatcher: NSView {
        var send: ([ScreenKeyboard.Stroke]) -> Void = { _ in }
        var resigned: () -> Void = {}

        override var acceptsFirstResponder: Bool { true }

        override func resignFirstResponder() -> Bool {
            let resigned = super.resignFirstResponder()
            if resigned { self.resigned() }
            return resigned
        }

        override func keyDown(with event: NSEvent) {
            // ⌘ shortcuts stay the app's (Hand Back, closing the tab, the menus).
            guard !event.modifierFlags.contains(.command) else { return super.keyDown(with: event) }
            let modifiers = Self.modifiers(event.modifierFlags)
            if let key = ScreenKeyboard.key(macKeyCode: event.keyCode) {
                send(ScreenKeyboard.strokes(key, modifiers: modifiers))
            } else if modifiers.contains(.control), let character = event.charactersIgnoringModifiers?.first {
                send(ScreenKeyboard.strokes(control: character, modifiers: modifiers))
            } else if let text = event.characters, !text.isEmpty {
                send(ScreenKeyboard.strokes(typing: text))
            }
        }

        private static func modifiers(_ flags: NSEvent.ModifierFlags) -> ScreenKeyboard.Modifiers {
            var modifiers: ScreenKeyboard.Modifiers = []
            if flags.contains(.shift) { modifiers.insert(.shift) }
            if flags.contains(.control) { modifiers.insert(.control) }
            if flags.contains(.option) { modifiers.insert(.option) }
            return modifiers
        }
    }
}
#endif
