import HermesKit
import HermesPush
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
            .task { await openDebugSheet() }
            #endif
    }

    private struct SetupTarget: Identifiable {
        let id: UUID
    }

    #if DEBUG
    /// `-HERMES_PUSH_OPEN prime|setup|settings|ask|tidied|botchat:<session>|botreply:<profile>|chatreply:<profile>:<session>`
    /// (screenshots and UI tests; `ask` requests permission straight away; `tidied` opens a tidy's
    /// notice as a tap would, `botchat:` a reply's in that chat with no profile, as the primary
    /// Bot's arrive, `botreply:` a Bot's reply after 20 s, time to deliver it off the socket, and
    /// `chatreply:` a reply's in that chat tagged with that profile after 8 s, through what a click
    /// on the Mac's own notification runs there).
    private func openDebugSheet() async {
        let flag = UserDefaults.standard.string(forKey: "HERMES_PUSH_OPEN") ?? ""
        if flag.hasPrefix("chatreply:") {
            let parts = flag.dropFirst("chatreply:".count).split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return }
            try? await Task.sleep(for: .seconds(8))
            guard let gateway = push.model?.selectedBotID else { return }
            var notice = PushNotice(kind: .reply, id: "reply-debug", body: "Done.", summary: "Chat", sessionID: parts[1],
                                    gateway: .init(id: gateway.uuidString, name: ""))
            notice.profile = parts[0]
            notice.sentAt = .now
            #if os(macOS)
            MacNotifier.shared.open(notice)
            #else
            push.open(notice)
            #endif
            return
        }
        if flag.hasPrefix("botchat:") {
            try? await Task.sleep(for: .seconds(6))
            let chat = String(flag.dropFirst("botchat:".count))
            push.open(PushNotice(kind: .reply, id: "reply-debug", body: "Done.", summary: "Bot Chat", sessionID: chat))
            return
        }
        if flag.hasPrefix("botreply:") {
            try? await Task.sleep(for: .seconds(20))
            var notice = PushNotice(kind: .reply, id: "reply-debug", body: "Done.", summary: "Bot Chat")
            notice.profile = String(flag.dropFirst("botreply:".count))
            notice.sentAt = .now
            push.open(notice)
            return
        }
        switch flag {
        case "prime": push.prime = .approval
        case "setup": push.setupGateway = push.model?.selectedBotID
        case "settings": push.showSettings = true
        case "ask": await push.requestAuthorization()
        case "tidied":
            try? await Task.sleep(for: .seconds(4))
            push.open(PushNotice(kind: .tidied, id: "tidy-debug", body: "Merged 1 overlapping skill."))
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
