import Foundation

/// What the person's keyboard sends to the Bot Screen during Take Control (`docs/inspector.md`
/// §2.6): X11 keysyms, each pressed and released. Text arrives from the system's text input (so
/// iOS sends Backspace as `deleteBackward`, with nothing in a field to delete), keys that aren't
/// text from the hardware keyboard by their HID usage (iPhone, iPad) or key code (Mac).
public enum ScreenKeyboard {
    public struct Stroke: Equatable, Sendable {
        public var keysym: UInt32
        public var down: Bool

        public init(_ keysym: UInt32, down: Bool) {
            self.keysym = keysym
            self.down = down
        }
    }

    public struct Modifiers: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let shift = Modifiers(rawValue: 1 << 0)
        public static let control = Modifiers(rawValue: 1 << 1)
        public static let option = Modifiers(rawValue: 1 << 2)
    }

    /// Keys that aren't text.
    public enum Key: Equatable, Sendable {
        case backspace, tab, enter, escape, forwardDelete
        case left, up, right, down, home, end, pageUp, pageDown
        /// F1–F12.
        case function(Int)

        public var keysym: UInt32 {
            switch self {
            case .backspace: 0xFF08
            case .tab: 0xFF09
            case .enter: 0xFF0D
            case .escape: 0xFF1B
            case .forwardDelete: 0xFFFF
            case .home: 0xFF50
            case .left: 0xFF51
            case .up: 0xFF52
            case .right: 0xFF53
            case .down: 0xFF54
            case .pageUp: 0xFF55
            case .pageDown: 0xFF56
            case .end: 0xFF57
            case .function(let number): 0xFFBE + UInt32(max(1, min(12, number)) - 1)
            }
        }

        /// The system's text input already sends these (Backspace as `deleteBackward`, Return and
        /// Tab as text), so a hardware key handler leaves them to it unless a modifier is held.
        public var arrivesAsText: Bool {
            self == .backspace || self == .enter || self == .tab
        }
    }

    static let shiftKeysym: UInt32 = 0xFFE1
    static let controlKeysym: UInt32 = 0xFFE3
    static let altKeysym: UInt32 = 0xFFE9

    /// Text the keyboard inserted: one press per character, line breaks as Return and tabs as
    /// Tab. Characters with no keysym are skipped.
    public static func strokes(typing text: String) -> [Stroke] {
        var strokes: [Stroke] = []
        for character in text {
            let keysym = character == "\r\n" ? Key.enter.keysym : RFBMessages.keysym(for: character)
            guard let keysym else { continue }
            strokes += press(keysym)
        }
        return strokes
    }

    /// The keyboard's Backspace.
    public static var backspace: [Stroke] { press(Key.backspace.keysym) }

    /// A key with the modifiers held, pressed and released.
    public static func strokes(_ key: Key, modifiers: Modifiers = []) -> [Stroke] {
        wrapped(press(key.keysym), in: modifiers)
    }

    /// A character typed with Control held ("c" for ⌃C), as the screen's own Control key.
    public static func strokes(control character: Character, modifiers: Modifiers = .control) -> [Stroke] {
        guard let keysym = RFBMessages.keysym(for: Character(character.lowercased())) else { return [] }
        return wrapped(press(keysym), in: modifiers.union(.control))
    }

    /// One half of a held key (iPad's hardware keyboard sends down and up as they happen, so the
    /// screen repeats a held arrow itself).
    public static func strokes(_ key: Key, modifiers: Modifiers = [], down: Bool) -> [Stroke] {
        let held = modifierKeysyms(modifiers)
        if down { return held.map { Stroke($0, down: true) } + [Stroke(key.keysym, down: true)] }
        return [Stroke(key.keysym, down: false)] + held.reversed().map { Stroke($0, down: false) }
    }

    /// A hardware key by its USB HID usage (`UIKeyboardHIDUsage`), when it isn't text.
    public static func key(hidUsage: Int) -> Key? {
        switch hidUsage {
        case 0x28, 0x58: .enter
        case 0x29: .escape
        case 0x2A: .backspace
        case 0x2B: .tab
        case 0x3A...0x45: .function(hidUsage - 0x3A + 1)
        case 0x4A: .home
        case 0x4B: .pageUp
        case 0x4C: .forwardDelete
        case 0x4D: .end
        case 0x4E: .pageDown
        case 0x4F: .right
        case 0x50: .left
        case 0x51: .down
        case 0x52: .up
        default: nil
        }
    }

    /// A Mac key by its virtual key code (`NSEvent.keyCode`), when it isn't text.
    public static func key(macKeyCode: UInt16) -> Key? {
        switch macKeyCode {
        case 36, 76: .enter
        case 48: .tab
        case 51: .backspace
        case 53: .escape
        case 117: .forwardDelete
        case 115: .home
        case 119: .end
        case 116: .pageUp
        case 121: .pageDown
        case 123: .left
        case 124: .right
        case 125: .down
        case 126: .up
        case 122: .function(1)
        case 120: .function(2)
        case 99: .function(3)
        case 118: .function(4)
        case 96: .function(5)
        case 97: .function(6)
        case 98: .function(7)
        case 100: .function(8)
        case 101: .function(9)
        case 109: .function(10)
        case 103: .function(11)
        case 111: .function(12)
        default: nil
        }
    }

    private static func press(_ keysym: UInt32) -> [Stroke] {
        [Stroke(keysym, down: true), Stroke(keysym, down: false)]
    }

    private static func modifierKeysyms(_ modifiers: Modifiers) -> [UInt32] {
        var keysyms: [UInt32] = []
        if modifiers.contains(.control) { keysyms.append(controlKeysym) }
        if modifiers.contains(.option) { keysyms.append(altKeysym) }
        if modifiers.contains(.shift) { keysyms.append(shiftKeysym) }
        return keysyms
    }

    private static func wrapped(_ strokes: [Stroke], in modifiers: Modifiers) -> [Stroke] {
        let held = modifierKeysyms(modifiers)
        return held.map { Stroke($0, down: true) } + strokes + held.reversed().map { Stroke($0, down: false) }
    }
}
