import HermesPush
import SwiftUI
import UserNotifications

#if os(iOS)
import UIKit

/// The APNs token, and background pushes (a request answered elsewhere: remove its notice).
final class PushAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Before launch finishes, so a tap that launched the app reaches us.
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushCenter.shared.didRegister(deviceToken: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        PushCenter.shared.didFailToRegister(error)
    }

    /// Finishes on the main thread, as `NotificationDelegate.didReceive` does: UIKit updates the
    /// app's snapshot in the completion handler and stops the app if that runs anywhere else, and
    /// the `async` form called it wherever the work finished.
    func application(
        _ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping @Sendable (UIBackgroundFetchResult) -> Void
    ) {
        guard let notice = NotificationDelegate.notice(from: userInfo, isRemote: true) else {
            completionHandler(.noData)
            return
        }
        Task { @MainActor in
            switch notice.kind {
            case .withdraw:
                await PushCenter.shared.withdraw(notice)
            case .sync:
                await PushCenter.shared.sync(notice)
            case .read:
                await PushCenter.shared.read(notice)
            default:
                completionHandler(.noData)
                return
            }
            completionHandler(.newData)
        }
    }
}
#else
import AppKit

/// The Mac's notification delegate, set before launch finishes.
final class PushAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        #if DEBUG
        // A measured copy stays behind the app in front (docs/development.md, Hangs). A binary a
        // shell runs is never launched in the background as `open -g` is, so AppKit activates it
        // as launching ends and its first window comes key and front, accessory or not. While the
        // policy is prohibited nothing can activate the app, and SwiftUI leaves the window out.
        if Self.launchesBehind {
            NSApp.setActivationPolicy(.prohibited)
            Self.markWhenComingForward()
        }
        #endif
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
        // A chat on screen behind a locked screen isn't being read (`BotRoster.isInFront`).
        ScreenLock.start()
    }

    #if DEBUG
    static let launchesBehind = UserDefaults.standard.bool(forKey: "HERMES_LAUNCH_BEHIND")

    /// Once the chats window's first view is up, launching is over: the copy becomes an accessory
    /// app (no Dock icon, no menu bar) and its window is ordered in at the back, never made key,
    /// so it draws without taking the front. A turn later, so the view is in its window.
    static func keepBehindAfterFirstView() {
        guard launchesBehind else { return }
        DispatchQueue.main.async {
            guard NSApp.activationPolicy() == .prohibited else { return }
            NSApp.setActivationPolicy(.accessory)
            let windows = NSApp.windows.filter {
                $0.identifier?.rawValue.hasPrefix("\(HermesApp.mainWindow)-") == true && !$0.isVisible
            }
            windows.forEach { $0.orderBack(nil) }
            let numbers = windows.map { "\($0.windowNumber)" }.joined(separator: ", ")
            HangLog.shared.mark(
                "launch behind: chats windows ordered in at the back: \(windows.count) (window \(numbers)), "
                    + "active \(NSApp.isActive), key \(windows.contains(where: \.isKeyWindow))"
            )
        }
    }

    /// The run's proof that the copy stayed behind: the hang log marks the app becoming active or
    /// any of its windows becoming key, which a measured copy never should.
    private static var forwardObservers: [any NSObjectProtocol] = []

    private static func markWhenComingForward() {
        let center = NotificationCenter.default
        forwardObservers = [
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                HangLog.shared.mark("launch behind: the app became active")
            },
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { _ in
                HangLog.shared.mark("launch behind: a window became key")
            },
        ]
    }
    #endif
}
#endif
