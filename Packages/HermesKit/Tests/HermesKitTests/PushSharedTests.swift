import Foundation
import HermesPush
import Testing

/// Stop Notifications on a gateway's page sticks: every check after it (the page's, the hourly
/// refresh, a new push address, a relaunch) leaves this device off that gateway's push list
/// (`docs/notifications.md` §1).
@Suite("Push stop")
struct PushSharedTests {
    private let suite = "push-stop-\(UUID().uuidString)"
    private let home = UUID()
    private let office = UUID()

    private func shared() -> PushShared {
        let shared = PushShared(suiteName: suite)
        shared.remember(installationID: "inst_home", appID: home, name: "Studio Mac")
        shared.remember(installationID: "inst_office", appID: office, name: "Office Mac")
        return shared
    }

    @Test func stoppingNotificationsKeepsThisDeviceOffTheGateway() {
        let shared = shared()
        #expect(shared.gatewayCheck(appID: home, hasToken: true, canNotify: true) == .register)

        shared.stopPush(appID: home)
        #expect(shared.gatewayCheck(appID: home, hasToken: true, canNotify: true) != .register)
        // After a relaunch too: the next launch reads the same defaults.
        let relaunched = PushShared(suiteName: suite)
        #expect(relaunched.gatewayCheck(appID: home, hasToken: true, canNotify: true) != .register)
        // The other gateway keeps this device.
        #expect(relaunched.gatewayCheck(appID: office, hasToken: true, canNotify: true) == .register)
    }

    @Test func stoppedGatewaysStayStoppedWithoutAPushAddressOrPermission() {
        let shared = shared()
        shared.stopPush(appID: home)
        #expect(shared.gatewayCheck(appID: home, hasToken: true, canNotify: true) == .stopped)
        #expect(shared.gatewayCheck(appID: home, hasToken: false, canNotify: false) == .stopped)
        #expect(shared.isPushStopped(appID: home))
        #expect(!shared.isPushStopped(appID: office))
    }

    @Test func setUpPutsThisDeviceBackOnTheGateway() {
        let shared = shared()
        shared.stopPush(appID: home)
        shared.resumePush(appID: home)
        #expect(!shared.isPushStopped(appID: home))
        #expect(shared.gatewayCheck(appID: home, hasToken: true, canNotify: true) == .register)
        #expect(!PushShared(suiteName: suite).isPushStopped(appID: home))
    }

    @Test func removingAStoppedGatewayForgetsItsStop() {
        let shared = shared()
        shared.stopPush(appID: home)
        shared.forget(appID: home)
        // Added again, it registers like any new gateway.
        #expect(PushShared(suiteName: suite).gatewayCheck(appID: home, hasToken: true, canNotify: true) == .register)
    }

    @Test func aStopMadeWhileACheckWaitsIsSeenWhenTheGatewayAnswers() {
        // `PushCenter.check` asks once before it calls the gateway and again once it answers.
        let shared = shared()
        #expect(shared.gatewayCheck(appID: home, hasToken: true, canNotify: true) == .register)
        shared.stopPush(appID: home)  // Stop Notifications while the register is on its way.
        #expect(PushShared(suiteName: suite).isPushStopped(appID: home))
    }

    @Test func setUpMadeWhileAStoppedCheckWaitsKeepsTheDeviceOn() {
        // A stopped check unregisters only while the stop still holds once the gateway answers.
        let shared = shared()
        shared.stopPush(appID: home)
        #expect(shared.gatewayCheck(appID: home, hasToken: true, canNotify: true) == .stopped)
        shared.resumePush(appID: home)  // Set Up… while its status is on its way.
        #expect(!PushShared(suiteName: suite).isPushStopped(appID: home))
    }

    @Test func leavingWithoutAStopKeepsNoMark() {
        // The Mac's Stop Notifications: its next check finds the gateway as before.
        let shared = shared()
        shared.leavePush(appID: home)
        #expect(!shared.isPushStopped(appID: home))
        #expect(shared.gatewayCheck(appID: home, hasToken: true, canNotify: true) == .register)
    }

    @Test func withoutAPushAddressOrPermissionTheCheckOnlyAsks() {
        let shared = shared()
        #expect(shared.gatewayCheck(appID: home, hasToken: false, canNotify: true) == .status)
        #expect(shared.gatewayCheck(appID: home, hasToken: true, canNotify: false) == .status)
    }
}
