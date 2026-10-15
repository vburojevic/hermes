import AuthenticationServices
import SwiftUI

/// Signs in to an app or MCP server in the browser (`docs/connections.md` §3–4, the in-chat
/// `connectSignIn` card). The session catches Hermes's return link (`hermes://connections/done`)
/// without the app registering the scheme. MCP OAuth returns to the gateway instead, so those
/// flows poll and close the browser with `cancel()` when Hermes says it's done.
@MainActor
final class BrowserSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = BrowserSignIn()

    private var session: ASWebAuthenticationSession?

    /// Opens `url`; returns the link the browser came back with, or `nil` when the person closed
    /// it (or `cancel()` ended it).
    func open(_ url: URL, callbackScheme: String = "hermes") async -> URL? {
        cancel()
        #if os(iOS)
        // The browser sheet needs a window scene to present from (`presentationAnchor`).
        guard UIApplication.shared.connectedScenes.contains(where: { $0 is UIWindowScene }) else { return nil }
        #endif
        return await withCheckedContinuation { continuation in
            let once = OnceFlag()
            let session = ASWebAuthenticationSession(url: url, callback: .customScheme(callbackScheme)) { callback, _ in
                if once.claim() { continuation.resume(returning: callback) }
            }
            session.presentationContextProvider = self
            // Keep the person's existing logins (GitHub, Google…) in the browser.
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start(), once.claim() {
                continuation.resume(returning: nil)
            }
        }
    }

    func cancel() {
        session?.cancel()
        session = nil
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            #if os(iOS)
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let windows = scenes.flatMap(\.windows)
            if let window = windows.first(where: \.isKeyWindow) ?? windows.first { return window }
            guard let scene = scenes.first else {
                // `start()` asks for this synchronously, right after `open` checked for a scene.
                preconditionFailure("Browser sign-in started without a window scene")
            }
            return UIWindow(windowScene: scene)
            #else
            return NSApp.keyWindow ?? NSApp.windows.first ?? NSWindow()
            #endif
        }
    }
}

/// The completion handler and a failed `start()` must not both resume.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            defer { claimed = true }
            return !claimed
        }
    }
}

extension URL {
    /// `hermes://connections/done?op=…`: the operation a browser sign-in came back for.
    var connectionDoneOperation: String? {
        guard scheme == "hermes", host() == "connections", path() == "/done" else { return nil }
        return URLComponents(url: self, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "op" }?.value
    }
}
