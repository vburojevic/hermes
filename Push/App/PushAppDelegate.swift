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

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        guard let notice = NotificationDelegate.notice(from: userInfo), notice.kind == .withdraw else { return .noData }
        await PushCenter.shared.withdraw(notice)
        return .newData
    }
}
#else
import AppKit

/// The Mac's notification delegate, set before launch finishes.
final class PushAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
    }
}
#endif
