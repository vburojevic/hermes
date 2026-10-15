import Foundation

/// A Bot's body (`docs/bot-faces.md` §1): Hermes Bot Mode's seven flat shapes.
public enum FaceShape: String, CaseIterable, Sendable, Codable {
    case circle, squircle, pill, triangle, hexagon, cloud, drop

    /// Hermes's `defaultShapeFor`: the shape a Bot gets from its name when none is picked.
    public static func forName(_ name: String) -> FaceShape {
        // Hermes walks code points (`for … of`) and takes each one's first UTF-16 unit.
        let hash = name.unicodeScalars.reduce(UInt32(0)) { $0 &* 31 &+ UInt32(String($1).utf16.first ?? 0) }
        return allCases[Int(hash % UInt32(allCases.count))]
    }
}

/// A Bot's colour in sRGB, and the eye colours that go with it (§2).
public struct FaceColor: Hashable, Sendable, Codable {
    /// 0…1.
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// The saturation and lightness of every Bot hue (Hermes `profile-color.ts`).
    public static let saturation = 0.68
    public static let lightness = 0.58

    /// `hsl(H, 68%, 58%)`.
    public static func hue(_ degrees: Double) -> FaceColor {
        FaceColor(hue: degrees, saturation: saturation, lightness: lightness)
    }

    /// The colour a Bot without a pick wears: its name's hue (`profileColor`).
    public static func forName(_ name: String) -> FaceColor {
        hue(Double(nameHash(name) % 360))
    }

    /// The default profile's violet (`PRIMARY_AVATAR_COLOR`).
    public static let defaultViolet = FaceColor(hex: 0x8B5CF6)

    /// The picker's twelve swatches, H = 0, 30 … 330.
    public static let swatches: [FaceColor] = (0..<12).map { hue(Double($0 * 30)) }

    /// Hermes's `hashString`: `h = h × 31 + code unit`, unsigned 32-bit.
    public static func nameHash(_ text: String) -> UInt32 {
        text.utf16.reduce(UInt32(0)) { $0 &* 31 &+ UInt32($1) }
    }

    public init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    /// CSS HSL (`hsl(h s% l%)`), converted the way browsers do.
    public init(hue: Double, saturation: Double, lightness: Double) {
        let h = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        let a = saturation * min(lightness, 1 - lightness)
        func channel(_ n: Double) -> Double {
            let k = (n + h / 30).truncatingRemainder(dividingBy: 12)
            return lightness - a * max(-1, min(k - 3, 9 - k, 1))
        }
        self.init(red: channel(0), green: channel(8), blue: channel(4))
    }

    /// The two forms Hermes stores: `#rrggbb` and `hsl(h s% l%)` (commas allowed).
    public init?(css text: String) {
        let value = text.trimmingCharacters(in: .whitespaces).lowercased()
        if value.hasPrefix("#") {
            var digits = String(value.dropFirst())
            if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
            guard digits.count == 6, let rgb = UInt32(digits, radix: 16) else { return nil }
            self.init(hex: rgb)
            return
        }
        if value.hasPrefix("hsl") {
            let numbers = value.drop { $0 != "(" }.dropFirst()
                .split(whereSeparator: { " ,%/)".contains($0) }).compactMap { Double($0.replacingOccurrences(of: "deg", with: "")) }
            guard numbers.count >= 3 else { return nil }
            self.init(hue: numbers[0], saturation: numbers[1] / 100, lightness: numbers[2] / 100)
            return
        }
        return nil
    }

    /// 0.2126 R + 0.7152 G + 0.0722 B on 0–255 (Hermes `isDarkColor`).
    public var luminance: Double { (0.2126 * red + 0.7152 * green + 0.0722 * blue) * 255 }

    /// Below 110 the eyes turn cream (red, violet and blue among the swatches).
    public var isDark: Bool { luminance < 110 }

    /// WCAG relative luminance, for the Increase Contrast outline.
    public var relativeLuminance: Double {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// Contrast ratio against another colour.
    public func contrast(with other: FaceColor) -> Double {
        let a = relativeLuminance, b = other.relativeLuminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    public static let white = FaceColor(red: 1, green: 1, blue: 1)
    public static let black = FaceColor(red: 0, green: 0, blue: 0)
}

/// One RGBA colour of a face's parts.
public struct FaceInk: Hashable, Sendable {
    public var red, green, blue, alpha: Double

    public init(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// `faces.eye-on-dark`: cream, `rgba(232, 220, 195, 0.95)`.
    public static let eyeOnDark = FaceInk(232 / 255, 220 / 255, 195 / 255, 0.95)
    /// `faces.eye-on-light`: `rgba(0, 0, 0, 0.85)`.
    public static let eyeOnLight = FaceInk(0, 0, 0, 0.85)
    /// `faces.sparkle-on-dark`: `rgba(0, 0, 0, 0.6)`.
    public static let sparkleOnDark = FaceInk(0, 0, 0, 0.6)
    /// `faces.sparkle-on-light`: `rgba(255, 255, 255, 0.85)`.
    public static let sparkleOnLight = FaceInk(1, 1, 1, 0.85)
}

extension FaceColor {
    /// The eyes, and the closed and happy strokes.
    public var eye: FaceInk { isDark ? .eyeOnDark : .eyeOnLight }
    /// The catchlight follows the pupil: a dark one on cream eyes, a white one on dark eyes.
    public var catchlight: FaceInk { isDark ? .sparkleOnDark : .sparkleOnLight }
}

/// How a Bot looks (Hermes `botAppearance`): its shape and colour.
public struct FaceLook: Hashable, Sendable, Codable {
    public var shape: FaceShape
    public var color: FaceColor

    public init(shape: FaceShape, color: FaceColor) {
        self.shape = shape
        self.color = color
    }

    /// Hermes's rules: a stored pick wins; otherwise the shape and hue come from the name. The
    /// default profile wears the violet squircle unless the person customised it.
    public init(profile: String, shape storedShape: String? = nil, color storedColor: String? = nil, customized: Bool = false) {
        let name = profile.trimmingCharacters(in: .whitespaces)
        if name.lowercased() == "default" && !customized {
            self.init(shape: .squircle, color: .defaultViolet)
            return
        }
        let shape = storedShape.flatMap { FaceShape(rawValue: $0) } ?? FaceShape.forName(name)
        let color = storedColor.flatMap(FaceColor.init(css:)) ?? (name.isEmpty ? .defaultViolet : .forName(name))
        self.init(shape: shape, color: color)
    }
}
