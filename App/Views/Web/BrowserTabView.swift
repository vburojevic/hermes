import HermesKit
import SwiftUI

/// Hermes's browser in this app (`webInApp`, `ipadWebInApp`, `macWebInApp`; `docs/web.md` §6): the
/// address, the page Hermes drives, and the bar that says what it's doing, with Take Over and Stop.
/// On a sign-in page it's the person's turn (`signInYourselfBar`, `webInAppYourTurn`).
struct BrowserTabView: View {
    let inspector: InspectorModel
    let controller: BrowserController

    var body: some View {
        VStack(spacing: 0) {
            addressBar
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            Divider().overlay(Theme.hairline)
            ZStack {
                Theme.canvas
                WebViewHost(webView: controller.webView)
                    .opacity(controller.asksForHost == nil ? 1 : 0)
                if let host = controller.asksForHost {
                    StateMessage(symbol: "network", title: String(localized: "Open a page on your network?"),
                                 message: controller.askedByHermes
                                    ? String(localized: "Hermes wants to open \(host), which is on this device's network. Pages there (a router, a NAS) open here only when you say so.")
                                    : String(localized: "This page tried to open \(host), which is on this device's network. Pages there (a router, a NAS) open here only when you say so."),
                                 actionTitle: String(localized: "Open \(host)"), action: controller.allowAskedHost)
                        .background(Theme.canvas)
                } else if let note = stateNote {
                    StateMessage(symbol: note.symbol, title: note.title, message: note.message)
                        .background(Theme.canvas)
                }
            }
            // An inset, not an overlay: the page scrolls clear of the bar, so a sign-in form's
            // last field is never under it.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if showsBar {
                    BrowserDrivingBar(controller: controller, conversation: inspector.conversation)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(Theme.snappy, value: showsBar)
        }
    }

    /// The bar shows while Hermes drives, on a sign-in page and while the person has control.
    private var showsBar: Bool {
        controller.state == .attached && (controller.currentStep != nil || controller.isSignInPage || controller.personHasControl
            || inspector.conversation?.isWorking == true)
    }

    private var addressBar: some View {
        HStack(spacing: 8) {
            Button {
                controller.webView.goBack()
            } label: {
                Image(systemName: "chevron.backward")
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.borderless)
            .disabled(!controller.canGoBack || !controller.personHasControl)
            .accessibilityLabel("Back")
            Button {
                controller.webView.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.borderless)
            .disabled(!controller.personHasControl)
            .accessibilityLabel("Reload")
            HStack(spacing: 6) {
                Image(systemName: controller.address.hasPrefix("https") || !controller.address.contains("://") ? "lock.fill" : "globe")
                    .font(.caption)
                    .foregroundStyle(Theme.tertiaryText)
                    .accessibilityHidden(true)
                Text(controller.address.isEmpty ? String(localized: "Waiting for Hermes") : controller.address)
                    .font(.footnote)
                    .foregroundStyle(controller.address.isEmpty ? Theme.tertiaryText : Theme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text("in this app")
                    .font(.caption2)
                    .foregroundStyle(Theme.tertiaryText)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Theme.surface, in: Capsule())
            .accessibilityElement(children: .combine)
        }
        .foregroundStyle(Theme.primaryText)
    }

    private struct Note {
        let symbol: String
        let title: String
        let message: String
    }

    /// The app's browser isn't Hermes's right now: why, in words. A page that's open stays usable
    /// (the person may be back from fetching a code to finish signing in).
    private var stateNote: Note? {
        if !controller.address.isEmpty, controller.state == .off || controller.state == .reconnecting { return nil }
        switch controller.state {
        case .attached:
            return nil
        case .connecting:
            return Note(symbol: "safari", title: String(localized: "Connecting to Hermes"), message: String(localized: "Hermes's browser steps for this chat run here once it's connected."))
        case .reconnecting:
            return Note(symbol: "wifi.exclamationmark", title: String(localized: "Reconnecting"), message: String(localized: "Hermes keeps waiting for the page while the app reconnects."))
        case .off:
            if inspector.conversation?.workspace?.inAppBrowser.isOn == true {
                return Note(symbol: "safari", title: String(localized: "Hermes's browser for this chat"),
                            message: String(localized: "Hermes uses it again with your next message here."))
            }
            return Note(symbol: "safari", title: String(localized: "Not Hermes's browser right now"), message: BrowserControlCopy.offNote)
        case .refused(let refusal):
            return Note(symbol: "exclamationmark.triangle", title: String(localized: "Hermes can't use this app's browser"), message: BrowserControlCopy.refusal(refusal, gateway: inspector.conversation?.gatewayName ?? ""))
        }
    }
}

/// `agentDrivingBar` for the app's browser, and `signInYourselfBar` when a page asks for a
/// password: Hermes waits while the person signs in with Passwords.
struct BrowserDrivingBar: View {
    let controller: BrowserController
    let conversation: ConversationModel?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: controller.personHasControl ? "hand.raised.fill" : (controller.isSignInPage ? "key.fill" : "safari"))
                .font(.system(size: 15))
                .foregroundStyle(Theme.primaryText)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.updatesFrequently)
            if controller.personHasControl {
                Button("Hand Back") { controller.handBack() }
                    .font(.footnote.weight(.semibold))
                    .cardButton()
            } else {
                Button("Take Over") { controller.takeOver() }
                    .font(.footnote.weight(.medium))
                    .cardButton()
                // Stop only while there's a turn to stop (a sign-in page stays after the reply).
                if conversation?.isWorking == true {
                    stopButton
                }
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(height: 52)
        .frame(maxWidth: 460)
        .glassEffect(.regular, in: Capsule())
        .onChange(of: title) { _, title in
            AccessibilityNotification.Announcement(title).post()
        }
    }

    private var stopButton: some View {
        Button {
            conversation?.stop()
        } label: {
            Image(systemName: "stop.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Theme.inkForeground)
                .frame(width: 34, height: 34)
                .background(Theme.ink, in: Circle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("Stop Hermes")
    }

    private var site: String { controller.siteTitle ?? String(localized: "the site") }

    private var title: String {
        if controller.personHasControl { return String(localized: "You're in control") }
        if controller.isSignInPage { return String(localized: "Your turn: sign in to \(site)") }
        return controller.currentStep ?? String(localized: "Hermes is using this page")
    }

    private var detail: String {
        if controller.personHasControl {
            return controller.isSignInPage ? String(localized: "Sign in with Passwords, then hand it back.") : String(localized: "Hermes waits until you hand the page back.")
        }
        if controller.isSignInPage { return String(localized: "Use Passwords, then hand it back.") }
        return String(localized: "\(site) · step \(controller.stepCount)")
    }
}

/// The app's browser in words (`docs/web.md` §6.6).
enum BrowserControlCopy {
    static var offNote: String {
        #if os(macOS)
        String(localized: "Hermes uses this app's browser for a chat when Browser is set to In this app, while Hermes runs.")
        #else
        String(localized: "Hermes uses this app's browser for a chat when Browser is set to In this app, while the app is open.")
        #endif
    }

    static func refusal(_ refusal: BrowserControlRefusal, gateway: String) -> String {
        switch refusal {
        case .turnedOff: String(localized: "In this app is off on \(gateway). Turn it on in Settings → Browser.")
        case .needsNewerHermes: String(localized: "This needs a newer Hermes Agent on \(gateway). Update it in Settings → Setup → Hermes Agent, or run hermes update there.")
        case .needsAPIKey: String(localized: "\(gateway)'s API server has no key, and Hermes lets only an app with the key drive its browser. Set API_SERVER_KEY there.")
        case .keyRefused: String(localized: "\(gateway) didn't accept this app's key. Check it in Edit Gateway.")
        case .unknownSession: String(localized: "Hermes doesn't know this chat yet. Send a message, then it can use the browser here.")
        case .needsSignIn: String(localized: "Bot Mode on \(gateway) signs in automatically, and Hermes lets only a signed-in app drive its browser. Sign in to Bot Mode with a password or a session token in Edit Gateway.")
        case .other(let message): String(localized: "Hermes said: \(message)")
        }
    }
}
