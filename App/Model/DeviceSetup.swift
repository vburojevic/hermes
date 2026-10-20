import AVFoundation
import HermesKit
import LocalAuthentication
import Observation
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// This device's permissions as Settings → Setup shows them (`docs/setup.md` §4.15): what each
/// one lets Hermes do, and the way to System Settings when it's off. Asking happens where the
/// feature starts (dictation, the scanner, an approval), never here.
@MainActor
@Observable
final class DeviceSetup {
    static let shared = DeviceSetup()

    enum ID {
        static let microphone = "device.microphone"
        static let camera = "device.camera"
        static let deviceOwner = "device.faceID"
    }

    /// A pane of System Settings: this app's own on iPhone and iPad, the privacy pane on the Mac.
    enum Pane {
        case microphone, camera, app, localNetwork
    }

    private(set) var microphone = AVAudioApplication.shared.recordPermission
    private(set) var camera = AVCaptureDevice.authorizationStatus(for: .video)
    private(set) var biometry = LABiometryType.none
    private(set) var biometryError: LAError.Code?
    /// A passcode (or a Mac's password) is set, so approvals can be confirmed at all.
    private(set) var canConfirmOwner = true

    func refresh() {
        microphone = AVAudioApplication.shared.recordPermission
        camera = AVCaptureDevice.authorizationStatus(for: .video)
        let context = LAContext()
        var error: NSError?
        let biometric = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        biometry = context.biometryType
        biometryError = biometric ? nil : error.map { LAError.Code(rawValue: $0.code) } ?? nil
        canConfirmOwner = LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    /// Every permission the app uses on this device.
    var statuses: [SetupStatus] {
        var all = [microphoneStatus]
        #if os(iOS)
        all.append(cameraStatus)
        #endif
        all.append(deviceOwnerStatus)
        return all
    }

    var microphoneStatus: SetupStatus {
        let title = String(localized: "Microphone")
        switch microphone {
        case .denied:
            return SetupStatus(
                id: ID.microphone, state: .notSetUp, title: title,
                detail: String(localized: "Dictation, voice messages and Talk can't hear you."),
                fallback: String(localized: "You can still type."),
                fix: .openSettings,
                steps: [SetupStep(Self.settingsPath(for: .microphone))]
            )
        case .granted:
            return SetupStatus(id: ID.microphone, state: .ready, title: title, detail: String(localized: "Allowed"))
        default:
            return SetupStatus(id: ID.microphone, state: .ready, title: title,
                               detail: String(localized: "Hermes asks the first time you dictate or talk."))
        }
    }

    var cameraStatus: SetupStatus {
        let title = String(localized: "Camera")
        switch camera {
        case .denied, .restricted:
            return SetupStatus(
                id: ID.camera, state: .notSetUp, title: title,
                detail: String(localized: "You can't scan pairing codes or take photos for a chat."),
                fallback: String(localized: "You can still pick photos from your library."),
                fix: camera == .denied ? .openSettings : nil,
                steps: [SetupStep(Self.settingsPath(for: .camera))]
            )
        case .authorized:
            return SetupStatus(id: ID.camera, state: .ready, title: title, detail: String(localized: "Allowed"))
        default:
            return SetupStatus(id: ID.camera, state: .ready, title: title,
                               detail: String(localized: "Hermes asks the first time you scan a code or take a photo."))
        }
    }

    /// Face ID, Touch ID or the passcode: what confirms a widget's approval is you.
    var deviceOwnerStatus: SetupStatus {
        let title = biometryTitle ?? String(localized: "Passcode")
        guard canConfirmOwner else {
            return SetupStatus(
                id: ID.deviceOwner, state: .notSetUp, title: title,
                detail: String(localized: "Approvals in widgets need Face ID, Touch ID or a passcode on this device, and none is set up."),
                steps: [SetupStep(Self.passcodePath)]
            )
        }
        if biometryError == .biometryNotAvailable, biometry != .none {
            // The person turned Face ID off for Hermes: the passcode stands in.
            return SetupStatus(
                id: ID.deviceOwner, state: .limited, title: title,
                detail: String(localized: "\(title) is off for Hermes."),
                fallback: String(localized: "Approvals in widgets ask for your passcode instead."),
                fix: .openSettings,
                steps: [SetupStep(Self.settingsPath(for: .app))]
            )
        }
        return SetupStatus(id: ID.deviceOwner, state: .ready, title: title,
                           detail: String(localized: "Confirms approvals in widgets are yours."))
    }

    private var biometryTitle: String? {
        switch biometry {
        case .faceID: String(localized: "Face ID")
        case .touchID: String(localized: "Touch ID")
        case .opticID: String(localized: "Optic ID")
        default: nil
        }
    }

    // MARK: System Settings

    static func settingsPath(for pane: Pane) -> String {
        #if os(iOS)
        switch pane {
        case .microphone: String(localized: "In Settings → Apps → Hermes, turn on Microphone.")
        case .camera: String(localized: "In Settings → Apps → Hermes, turn on Camera.")
        case .app: String(localized: "In Settings → Apps → Hermes, turn on Face ID.")
        case .localNetwork: String(localized: "In Settings → Apps → Hermes, turn on Local Network.")
        }
        #else
        switch pane {
        case .microphone: String(localized: "In System Settings → Privacy & Security → Microphone, turn on Hermes.")
        case .camera: String(localized: "In System Settings → Privacy & Security → Camera, turn on Hermes.")
        case .app: String(localized: "In System Settings → Touch ID & Password, check Touch ID is set up.")
        case .localNetwork: String(localized: "In System Settings → Privacy & Security → Local Network, turn on Hermes.")
        }
        #endif
    }

    static var passcodePath: String {
        #if os(iOS)
        String(localized: "In Settings → Face ID & Passcode, turn on a passcode.")
        #else
        String(localized: "In System Settings → Users & Groups, give your account a password.")
        #endif
    }

    static func openSettings(_ pane: Pane) {
        #if os(iOS)
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        #else
        let anchor = switch pane {
        case .microphone: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        case .camera: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera"
        case .app: "x-apple.systempreferences:com.apple.Touch-ID-Settings.extension"
        case .localNetwork: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork"
        }
        if let url = URL(string: anchor) { NSWorkspace.shared.open(url) }
        #endif
    }

    /// The fix for one of `statuses`.
    func fix(for id: String) -> (() -> Void)? {
        switch id {
        case ID.microphone: { Self.openSettings(.microphone) }
        case ID.camera: { Self.openSettings(.camera) }
        case ID.deviceOwner: { Self.openSettings(.app) }
        default: nil
        }
    }
}
