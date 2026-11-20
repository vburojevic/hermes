@testable import HermesPush
import Testing

@Suite struct LockScreenWordingTests {
    @Test func iPhoneKeepsTheDesignsWords() {
        let wording = LockScreenWording(device: .iPhone, unlock: .faceID)
        #expect(wording.footer == "While iPhone is locked, the text waits for Face ID when Show Previews is set to When Unlocked.")
        #expect(wording.liveActivity == "Progress on the Lock Screen and in the Dynamic Island.")
    }

    @Test func iPadSaysIPadAndHasNoDynamicIsland() {
        for unlock in [LockScreenWording.Unlock.faceID, .touchID, .passcode] {
            let wording = LockScreenWording(device: .iPad, unlock: unlock)
            #expect(wording.footer.hasPrefix("While iPad is locked,"))
            #expect(!wording.footer.contains("iPhone"))
            #expect(!wording.liveActivity.contains("Dynamic Island"))
        }
        #expect(LockScreenWording(device: .iPad, unlock: .faceID).liveActivity == "Progress on the Lock Screen.")
    }

    @Test func namesTheUnlockOnlyWhereTheDeviceHasIt() {
        #expect(LockScreenWording(device: .iPad, unlock: .touchID).footer.contains("waits for Touch ID"))
        #expect(LockScreenWording(device: .iPhone, unlock: .touchID).footer.contains("waits for Touch ID"))
        for device in [LockScreenWording.Device.iPhone, .iPad] {
            let footer = LockScreenWording(device: device, unlock: .passcode).footer
            #expect(footer.contains("waits until it's unlocked"))
            #expect(!footer.contains("Face ID") && !footer.contains("Touch ID"))
        }
    }
}
