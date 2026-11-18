#if os(macOS)
import AppKit
import SwiftUI

/// Tells `onChange` when the view's own window is minimized (true) or comes back (false). A
/// minimized Mac window's scene phase never reaches background, so without this it would still
/// count as on screen (`docs/notifications.md` §1.6). A window covered by another app's stays on
/// screen, as before.
struct WindowMiniaturizeProbe: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> ProbeView { ProbeView(onChange: onChange) }
    func updateNSView(_ view: ProbeView, context: Context) { view.onChange = onChange }

    final class ProbeView: NSView {
        var onChange: (Bool) -> Void
        private var observers: [any NSObjectProtocol] = []

        init(onChange: @escaping (Bool) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Leaving the window (the view went away) stops listening.
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            for (name, minimized) in [(NSWindow.didMiniaturizeNotification, true), (NSWindow.didDeminiaturizeNotification, false)] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.onChange(minimized) }
                })
            }
            // A window restored minimized at launch says so once, after this update.
            if window.isMiniaturized {
                Task { [weak self] in self?.onChange(true) }
            }
        }
    }
}
#endif
