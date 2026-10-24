import Foundation
import Testing
@testable import HermesKit

@Suite("Screen keyboard")
struct ScreenKeyboardTests {
    private typealias Stroke = ScreenKeyboard.Stroke

    private func press(_ keysym: UInt32) -> [Stroke] {
        [Stroke(keysym, down: true), Stroke(keysym, down: false)]
    }

    @Test func backspaceIsTheScreensBackSpace() {
        // iOS calls deleteBackward with nothing in the hidden field: it still reaches the screen.
        #expect(ScreenKeyboard.backspace == press(0xFF08))
        #expect(ScreenKeyboard.strokes(.backspace) == press(0xFF08))
    }

    @Test func typedTextIsOnePressPerCharacter() {
        #expect(ScreenKeyboard.strokes(typing: "Hi") == press(0x48) + press(0x69))
        // Return and Tab arrive from the text system as text.
        #expect(ScreenKeyboard.strokes(typing: "\n") == press(0xFF0D))
        #expect(ScreenKeyboard.strokes(typing: "\r\n") == press(0xFF0D))
        #expect(ScreenKeyboard.strokes(typing: "\t") == press(0xFF09))
        // Beyond Latin-1, X11's Unicode keysyms.
        #expect(ScreenKeyboard.strokes(typing: "é€") == press(0xE9) + press(0x0100_20AC))
        // A cluster with no single keysym is skipped, not sent in pieces.
        #expect(ScreenKeyboard.strokes(typing: "👍🏽").isEmpty)
    }

    @Test func modifiersWrapTheKey() {
        #expect(ScreenKeyboard.strokes(.left, modifiers: .shift)
            == [Stroke(0xFFE1, down: true), Stroke(0xFF51, down: true), Stroke(0xFF51, down: false), Stroke(0xFFE1, down: false)])
        // ⌃C reaches a terminal on the screen as Control and c, whatever the case typed.
        #expect(ScreenKeyboard.strokes(control: "C")
            == [Stroke(0xFFE3, down: true)] + press(0x63) + [Stroke(0xFFE3, down: false)])
        #expect(ScreenKeyboard.strokes(control: "c", modifiers: [.control, .option])
            == [Stroke(0xFFE3, down: true), Stroke(0xFFE9, down: true)] + press(0x63)
            + [Stroke(0xFFE9, down: false), Stroke(0xFFE3, down: false)])
    }

    @Test func heldKeysGoDownAndUpApart() {
        // So the screen repeats a held arrow itself.
        #expect(ScreenKeyboard.strokes(.down, modifiers: .control, down: true) == [Stroke(0xFFE3, down: true), Stroke(0xFF54, down: true)])
        #expect(ScreenKeyboard.strokes(.down, modifiers: .control, down: false) == [Stroke(0xFF54, down: false), Stroke(0xFFE3, down: false)])
    }

    @Test func hardwareKeysByHIDUsage() {
        #expect(ScreenKeyboard.key(hidUsage: 0x2A) == .backspace)
        #expect(ScreenKeyboard.key(hidUsage: 0x28) == .enter)
        #expect(ScreenKeyboard.key(hidUsage: 0x2B) == .tab)
        #expect(ScreenKeyboard.key(hidUsage: 0x29) == .escape)
        #expect(ScreenKeyboard.key(hidUsage: 0x4C) == .forwardDelete)
        #expect([0x50, 0x52, 0x4F, 0x51].compactMap { ScreenKeyboard.key(hidUsage: $0) } == [.left, .up, .right, .down])
        #expect(ScreenKeyboard.key(hidUsage: 0x3A) == .function(1) && ScreenKeyboard.key(hidUsage: 0x45) == .function(12))
        #expect(ScreenKeyboard.key(hidUsage: 0x04) == nil) // "a" is text
        #expect(ScreenKeyboard.Key.backspace.arrivesAsText && !ScreenKeyboard.Key.left.arrivesAsText)
    }

    @Test func macKeysByKeyCode() {
        #expect(ScreenKeyboard.key(macKeyCode: 51) == .backspace)
        #expect(ScreenKeyboard.key(macKeyCode: 36) == .enter && ScreenKeyboard.key(macKeyCode: 76) == .enter)
        #expect(ScreenKeyboard.key(macKeyCode: 48) == .tab)
        #expect(ScreenKeyboard.key(macKeyCode: 117) == .forwardDelete)
        #expect([123, 126, 124, 125].compactMap { ScreenKeyboard.key(macKeyCode: $0) } == [.left, .up, .right, .down])
        #expect(ScreenKeyboard.key(macKeyCode: 0) == nil) // "a" is text
    }

    @Test func keysymsMatchX11() {
        #expect(ScreenKeyboard.Key.escape.keysym == 0xFF1B)
        #expect(ScreenKeyboard.Key.forwardDelete.keysym == 0xFFFF)
        #expect(ScreenKeyboard.Key.home.keysym == 0xFF50 && ScreenKeyboard.Key.end.keysym == 0xFF57)
        #expect(ScreenKeyboard.Key.pageUp.keysym == 0xFF55 && ScreenKeyboard.Key.pageDown.keysym == 0xFF56)
        #expect(ScreenKeyboard.Key.function(1).keysym == 0xFFBE && ScreenKeyboard.Key.function(12).keysym == 0xFFC9)
    }
}
