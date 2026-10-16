import HermesKit
import SwiftUI
import WebKit

/// A Preview tab (`macInspectorPreview`, `inspectorSheet`): the URL bar, the page in the app's own
/// web view, and while Hermes drives it, the floating `agentDrivingBar`. A localhost page this
/// device can't reach shows `reachNote` instead.
struct PreviewTabView: View {
    let inspector: InspectorModel
    let controller: PreviewController
    let tab: InspectorTab

    @Environment(\.openURL) private var openURL

    private var isDriving: Bool { inspector.driving?.tabID == tab.id }

    var body: some View {
        VStack(spacing: 0) {
            URLBar(controller: controller)
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            Divider().overlay(Theme.hairline)
            ZStack(alignment: .bottom) {
                Theme.canvas
                PreviewWebView(controller: controller)
                    .opacity(isUnreachable ? 0 : 1)
                if case .unreachable(let host) = controller.reach {
                    ReachNote(inspector: inspector, controller: controller, host: host)
                } else if case .failed(let message) = controller.reach {
                    StateMessage(symbol: "exclamationmark.triangle", title: String(localized: "This page didn't load"), message: message,
                                 actionTitle: String(localized: "Try Again"), action: controller.reload)
                        .background(Theme.canvas)
                }
                if isDriving || (inspector.personInControl && inspector.hermesTabs.contains(tab.id)) {
                    DrivingBar(inspector: inspector, conversation: inspector.conversation)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 14)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(Theme.snappy, value: isDriving)
            .animation(Theme.snappy, value: inspector.personInControl)
        }
    }

    private var isUnreachable: Bool {
        if case .unreachable = controller.reach { return true }
        if case .failed = controller.reach { return true }
        return false
    }
}

/// `urlBar`: back, forward, reload, the address (and where it runs), open outside.
private struct URLBar: View {
    let controller: PreviewController

    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(spacing: 4) {
            button("chevron.left", label: "Back", enabled: controller.canGoBack, action: controller.goBack)
            button("chevron.right", label: "Forward", enabled: controller.canGoForward, action: controller.goForward)
            button(controller.isLoading ? "xmark" : "arrow.clockwise", label: controller.isLoading ? "Stop Loading" : "Reload", enabled: true) {
                if controller.isLoading { controller.webView.stopLoading() } else { controller.reload() }
            }
            field
            button("safari", label: "Open in Browser", enabled: externalURL != nil) {
                if let externalURL { openURL(externalURL) }
            }
        }
        .frame(height: 36)
    }

    private var externalURL: URL? {
        guard let url = controller.loadedURL, url.scheme == "http" || url.scheme == "https" else { return nil }
        return url
    }

    private var field: some View {
        HStack(spacing: 6) {
            Image(systemName: controller.target.isLocalhost ? "desktopcomputer" : (controller.loadedURL?.scheme == "https" ? "lock.fill" : "globe"))
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiaryText)
            if editing {
                TextField("Address", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.footnote)
                    .focused($focused)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                    .onSubmit {
                        editing = false
                        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !text.isEmpty { controller.open(text) }
                    }
                    .onChange(of: focused) { _, isFocused in if !isFocused { editing = false } }
            } else {
                Text(controller.address)
                    .font(.footnote)
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        draft = controller.address
                        editing = true
                        focused = true
                    }
                if let note = controller.hostNote {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(Theme.tertiaryText)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Theme.controlFill, in: Capsule())
        .modifier(AddressAccessibility(isEditing: editing, address: controller.address) {
            draft = controller.address
            editing = true
            focused = true
        })
    }

    private func button(_ symbol: String, label: LocalizedStringKey, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.primaryText)
        }
        .buttonStyle(IconButtonStyle(size: 30))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityLabel(label)
        .help(Text(label))
    }
}

/// The address reads as one button until it's being edited; the field is its own control then.
private struct AddressAccessibility: ViewModifier {
    let isEditing: Bool
    let address: String
    let edit: () -> Void

    func body(content: Content) -> some View {
        if isEditing {
            content
        } else {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Address, \(address)"))
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { edit() }
        }
    }
}

/// `agentDrivingBar`: what Hermes is doing in the page, Take Over and Stop. When the person has
/// taken over: "You're in control" and Hand Back.
private struct DrivingBar: View {
    let inspector: InspectorModel
    let conversation: ConversationModel?

    var body: some View {
        HStack(spacing: 10) {
            if inspector.personInControl {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.primaryText)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text("You're in control")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.primaryText)
                    Text("Hermes waits until you hand the page back.")
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("Hand Back") { inspector.handBack() }
                    .font(.footnote.weight(.semibold))
                    .cardButton()
            } else {
                BotFace(appearance: BotAppearance(profile: inspector.profile ?? "default"), size: 24, mood: .working)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(inspector.drivingTitle)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(1)
                    Text(inspector.drivingDetail)
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                        .contentTransition(.numericText())
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.updatesFrequently)
                Button("Take Over") { inspector.takeOver() }
                    .font(.footnote.weight(.medium))
                    .cardButton()
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
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(height: 52)
        .frame(maxWidth: 460)
        .glassEffect(.regular, in: Capsule())
        .onChange(of: inspector.drivingDetail) { _, detail in
            guard !detail.isEmpty else { return }
            AccessibilityNotification.Announcement(detail).post()
        }
    }
}

/// `reachNote`: a localhost page this device can't reach, and the ways to see it. Nothing opens
/// a port or a tunnel without being asked.
private struct ReachNote: View {
    let inspector: InspectorModel
    let controller: PreviewController
    let host: String

    @State private var asked = false

    private var device: String {
        #if os(macOS)
        String(localized: "This Mac")
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? String(localized: "This iPad") : String(localized: "This iPhone")
        #endif
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.tertiaryText)
                .padding(.bottom, 4)
            Text("\(controller.target.displayURL) is on \(host)")
                .font(.headline)
                .foregroundStyle(Theme.primaryText)
                .multilineTextAlignment(.center)
            Text("\(device) can reach \(host) over your tailnet, but the dev server only listens on the machine itself.")
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                asked = true
                inspector.shareOnTailnet(controller)
            } label: {
                Text(asked ? "Asked Hermes" : "Ask Hermes to Share It on the Tailnet")
                    .frame(maxWidth: .infinity)
            }
            .inkFilledButton()
            .controlSize(.large)
            .disabled(asked)
            .padding(.top, 6)
            Button {
                inspector.askForScreenshot(controller)
            } label: {
                Text("Show a Screenshot Instead")
                    .frame(maxWidth: .infinity)
            }
            .cardButton()
            .controlSize(.large)
            Button("Try Again", action: controller.reload)
                .font(.footnote)
                .buttonStyle(.plain)
                .foregroundStyle(Theme.secondaryText)
                .padding(.top, 2)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 24)
        .frame(maxWidth: 360)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
    }
}

/// The tab's web view, owned by its controller so it survives tab switches and the panel moving
/// between the side and a sheet.
struct PreviewWebView: View {
    let controller: PreviewController

    var body: some View {
        WebViewHost(webView: controller.webView)
    }
}

#if os(macOS)
struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
#else
struct WebViewHost: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
#endif
