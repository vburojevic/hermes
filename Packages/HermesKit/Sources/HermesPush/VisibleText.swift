import Foundation

/// Text that asks to be approved (a command, its description) shown exactly as it would run.
/// Characters that draw nothing or reorder what's around them (bidi overrides and isolates,
/// zero-width spaces and joiners, control characters) would let `rm -rf ~` read as something
/// harmless, so each shows as its code (`⟨U+202E⟩`). Newlines and tabs stay as they are.
public enum VisibleText {
    public static func of(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: isHidden) else { return text }
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if isHidden(scalar) {
                out.append(contentsOf: "⟨U+\(String(scalar.value, radix: 16, uppercase: true).leftPadded(to: 4))⟩".unicodeScalars)
            } else {
                out.append(scalar)
            }
        }
        return String(out)
    }

    public static func of(_ text: String?) -> String? {
        text.map(of)
    }

    /// Short enough to read whole at a glance (one line, `limit` characters): a small surface
    /// (the dock, a banner, the Dynamic Island) offers Allow beside it only then. Anything longer
    /// gets the full card first.
    public static func fitsAtAGlance(_ text: String?, limit: Int) -> Bool {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines) else { return true }
        return text.count <= limit && !text.contains(where: \.isNewline)
    }

    static func isHidden(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0A, 0x09: false // newline, tab
        case 0x00...0x1F, 0x7F...0x9F: true // control characters (a carriage return included)
        case 0x061C, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069: true // bidi marks, overrides, isolates
        case 0x200B...0x200D, 0x2060...0x2064, 0xFEFF, 0x180E, 0x00AD: true // zero-width and invisible
        case 0x2028, 0x2029: true // line and paragraph separators
        default: false
        }
    }
}

private extension String {
    func leftPadded(to length: Int) -> String {
        count >= length ? self : String(repeating: "0", count: length - count) + self
    }
}
