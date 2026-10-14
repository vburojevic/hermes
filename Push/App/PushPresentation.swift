import HermesKit
import SwiftUI

/// The push sheets, on every window's root: the permission ask, Set Up Push, and Settings →
/// Notifications when the system's "Hermes Notification Settings" link opens the app.
struct PushPresentation: ViewModifier {
    @Bindable private var push = PushCenter.shared

    func body(content: Content) -> some View {
        content
            .sheet(item: $push.prime) { reason in
                PermissionPrimeSheet(reason: reason)
            }
            .sheet(item: Binding(get: { push.setupGateway.map(SetupTarget.init) }, set: { push.setupGateway = $0?.id })) { target in
                PushSetupSheet(gatewayID: target.id)
            }
            .sheet(isPresented: $push.showSettings) {
                NavigationStack {
                    NotificationSettingsView()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { push.showSettings = false }
                            }
                        }
                }
                #if os(macOS)
                .frame(width: 520, height: 600)
                #endif
            }
            #if DEBUG
            .task { openDebugSheet() }
            #endif
    }

    private struct SetupTarget: Identifiable {
        let id: UUID
    }

    #if DEBUG
    /// `-HERMES_PUSH_OPEN prime|setup|settings|ask` (screenshots and UI tests; `ask` requests
    /// permission straight away).
    private func openDebugSheet() {
        switch UserDefaults.standard.string(forKey: "HERMES_PUSH_OPEN") {
        case "prime": push.prime = .approval
        case "setup": push.setupGateway = push.model?.selectedBotID
        case "settings": push.showSettings = true
        case "ask": Task { await push.requestAuthorization() }
        default: break
        }
    }
    #endif
}

extension View {
    func pushPresentation() -> some View {
        modifier(PushPresentation())
    }
}
