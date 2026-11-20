import Foundation

/// Settings → Notifications → Lock Screen's words for this device (`docs/notifications.md` §5):
/// iPad says iPad and has no Dynamic Island, and the footer names Face ID or Touch ID only where
/// the device unlocks with it.
public struct LockScreenWording: Sendable, Hashable {
    public enum Device: Sendable, Hashable {
        case iPhone, iPad
    }

    /// How the device unlocks: its biometry, or only its passcode.
    public enum Unlock: Sendable, Hashable {
        case faceID, touchID, passcode
    }

    public let device: Device
    public let unlock: Unlock

    public init(device: Device, unlock: Unlock) {
        self.device = device
        self.unlock = unlock
    }

    /// The Live Activity toggle's line.
    public var liveActivity: String {
        switch device {
        case .iPhone: String(localized: "Progress on the Lock Screen and in the Dynamic Island.", bundle: .module)
        case .iPad: String(localized: "Progress on the Lock Screen.", bundle: .module)
        }
    }

    /// The section's footer: when the message text shows on a locked device.
    public var footer: String {
        switch (device, unlock) {
        case (.iPhone, .faceID):
            String(localized: "While iPhone is locked, the text waits for Face ID when Show Previews is set to When Unlocked.", bundle: .module)
        case (.iPhone, .touchID):
            String(localized: "While iPhone is locked, the text waits for Touch ID when Show Previews is set to When Unlocked.", bundle: .module)
        case (.iPhone, .passcode):
            String(localized: "While iPhone is locked, the text waits until it's unlocked when Show Previews is set to When Unlocked.", bundle: .module)
        case (.iPad, .faceID):
            String(localized: "While iPad is locked, the text waits for Face ID when Show Previews is set to When Unlocked.", bundle: .module)
        case (.iPad, .touchID):
            String(localized: "While iPad is locked, the text waits for Touch ID when Show Previews is set to When Unlocked.", bundle: .module)
        case (.iPad, .passcode):
            String(localized: "While iPad is locked, the text waits until it's unlocked when Show Previews is set to When Unlocked.", bundle: .module)
        }
    }
}
