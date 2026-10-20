import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
typealias PlatformImage = NSImage
#else
import UIKit
typealias PlatformImage = UIImage
#endif

extension Image {
    init(platformImage: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: platformImage)
        #else
        self.init(uiImage: platformImage)
        #endif
    }
}

enum Pasteboard {
    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    /// A key: kept off other devices (Universal Clipboard) and gone after two minutes on iOS;
    /// marked concealed on the Mac, so clipboard managers leave it out of their history.
    static func copySecret(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        NSPasteboard.general.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        #else
        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: text]], options: [
            .localOnly: true, .expirationDate: Date.now.addingTimeInterval(120),
        ])
        #endif
    }

    /// Text on the pasteboard (macOS; on iOS use `PasteButton`, which doesn't prompt).
    static func string() -> String? {
        #if os(macOS)
        NSPasteboard.general.string(forType: .string)
        #else
        UIPasteboard.general.string
        #endif
    }

    /// Image data currently on the pasteboard, if any.
    static func imageData() -> Data? {
        #if os(macOS)
        let pasteboard = NSPasteboard.general
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pasteboard.data(forType: type) { return data }
        }
        if let url = (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])?.first,
           let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) {
            return try? Data(contentsOf: url)
        }
        return nil
        #else
        return UIPasteboard.general.image?.pngData()
        #endif
    }

    static var hasImage: Bool {
        #if os(macOS)
        NSPasteboard.general.canReadItem(withDataConformingToTypes: [UTType.image.identifier])
        #else
        UIPasteboard.general.hasImages
        #endif
    }
}

enum Device {
    static var isPhone: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }

    static var isMac: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }
}

/// Keeps work going for as long as iOS allows after the app moves to the background (about 30 s:
/// a streaming turn, the connection, answering a notification), and always gives the time back
/// before it runs out: a background task still held when it expires gets the app ended.
///
/// The time is held, and given back, off the main thread (`ProcessInfo.performExpiringActivity`):
/// in the background a busy phone (or a simulator on a loaded Mac) can leave the main thread
/// without CPU for longer than the time lasts, and a hold that needed it to let go got the app
/// ended (0x2182BAD2) with neither its own deadline nor iOS's expiry handler having run.
@MainActor
final class BackgroundActivity {
    #if os(iOS)
    private var hold: Hold?
    private var name = ""
    private var observers: [any NSObjectProtocol] = []
    #endif
    /// Once the time has been given back for running out (not after `end()`).
    private var onExpiry: (@MainActor () -> Void)?

    var isActive: Bool {
        #if os(iOS)
        hold != nil
        #else
        false
        #endif
    }

    /// - Parameter onExpiry: the time has gone back (early, or as it ran out): wrap up, quickly,
    ///   as the app may be suspended any moment.
    func begin(_ name: String, onExpiry: (@MainActor () -> Void)? = nil) {
        #if os(iOS)
        guard hold == nil else { return }
        let hold = Hold()
        self.hold = hold
        self.name = name
        self.onExpiry = onExpiry
        // Begun in the foreground, the time is the app's until it leaves; it goes back 15 s after.
        if UIApplication.shared.applicationState == .background { hold.left() }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in hold.left() },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in hold.cameBack() },
        ]
        ProcessInfo.processInfo.performExpiringActivity(withReason: name) { [weak self] expired in
            if expired {
                // iOS wants the time now: the call holding it (below, on another thread) returns.
                hold.giveBack(.ranOut)
                return
            }
            let reason = hold.waitUntilGivenBack()
            guard reason != .ended else { return }
            Task { @MainActor in self?.gaveBack(hold, reason: reason) }
        }
        #endif
    }

    func end() {
        #if os(iOS)
        onExpiry = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        hold?.giveBack(.ended)
        hold = nil
        #endif
    }

    #if os(iOS)
    /// The time went back by itself: the work wraps up once the main thread gets to it.
    private func gaveBack(_ given: Hold, reason: Hold.Reason) {
        guard hold === given else { return }
        ConnectionLog.logger.notice("background time for \(self.name, privacy: .public): \(reason == .deadline ? "given back early" : "ran out", privacy: .public)")
        let wrapUp = onExpiry
        end()
        wrapUp?()
    }

    /// Time held on the activity's own thread, given back from whichever thread gets there first.
    nonisolated private final class Hold: @unchecked Sendable {
        enum Reason { case ended, deadline, ranOut }

        /// Well before iOS's own limit (about 30 s), which a starved app can miss by seconds.
        private static let deadline: TimeInterval = 15
        private let lock = NSLock()
        private let wake = DispatchSemaphore(value: 0)
        private var leftAt: Date?
        private var reason: Reason?

        func left() {
            lock.withLock { if leftAt == nil { leftAt = .now } }
            wake.signal()
        }

        func cameBack() {
            lock.withLock { leftAt = nil }
            wake.signal()
        }

        func giveBack(_ reason: Reason) {
            lock.withLock { if self.reason == nil { self.reason = reason } }
            wake.signal()
        }

        /// Blocks until `end()`, iOS's expiry or the deadline, and says which.
        func waitUntilGivenBack() -> Reason {
            while true {
                let (reason, leftAt) = lock.withLock { (self.reason, self.leftAt) }
                if let reason { return reason }
                guard let leftAt else {
                    wake.wait() // in the foreground: until it leaves, or this ends
                    continue
                }
                let remaining = Self.deadline - Date.now.timeIntervalSince(leftAt)
                if remaining <= 0 {
                    giveBack(.deadline)
                } else {
                    _ = wake.wait(timeout: .now() + remaining)
                }
            }
        }
    }
    #endif
}

/// The Mac app is behind other apps. Its windows stay on screen and its scene never goes to the
/// background, so polls that only stop in the background ran all day; they slow down while this is
/// true. Always false on iPhone and iPad, where the background stops them.
enum AppPresence {
    static var isInBack: Bool {
        #if os(macOS)
        !NSApp.isActive
        #else
        false
        #endif
    }
}
