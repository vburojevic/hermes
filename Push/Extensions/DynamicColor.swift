import SwiftUI
import UIKit

// The extensions' copy of the app's dynamic colour initialiser (App/Design/Theme.swift), so they
// can share App/Design/Palette.swift: light, dark and Increase Contrast values.
nonisolated extension Color {
    init(light: Color, dark: Color, increasedContrastLight: Color? = nil, increasedContrastDark: Color? = nil) {
        self.init(uiColor: UIColor { @Sendable traits in
            let isDark = traits.userInterfaceStyle == .dark
            let color = traits.accessibilityContrast == .high
                ? (isDark ? increasedContrastDark ?? dark : increasedContrastLight ?? light)
                : (isDark ? dark : light)
            return UIColor(color)
        })
    }
}

/// The Hermes wing (App/Design/HermesMarkPath.swift) as a shape.
nonisolated struct HermesWing: Shape {
    func path(in rect: CGRect) -> Path {
        Path(HermesMarkPath.path(in: rect))
    }
}
