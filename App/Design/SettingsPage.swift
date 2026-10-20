import SwiftUI

extension View {
    /// A page pushed inside a Mac Settings tab: its back button sits at the top of the page, named
    /// for the page it goes back to, with ⌘[. In the window's toolbar the system back button
    /// pushes the tab buttons aside while macOS keeps the tab highlight where it was, over the
    /// wrong tab. On iPhone and iPad the system back button stays.
    func settingsPage(back title: String) -> some View {
        modifier(SettingsPageBack(title: title))
    }
}

private struct SettingsPageBack: ViewModifier {
    let title: String
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .navigationBarBackButtonHidden()
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Label(title, systemImage: "chevron.backward")
                    }
                    .buttonStyle(.borderless)
                    .keyboardShortcut("[", modifiers: .command)
                    .accessibilityLabel(String(localized: "Back to \(title)"))
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 2)
            }
        #else
        content
        #endif
    }
}
