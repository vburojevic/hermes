#if os(iOS)
import AVFoundation

/// Whether this device has a camera, asked once, off the main thread. UIKit's own question
/// (`UIImagePickerController.isSourceTypeAvailable(.camera)`) loads a system library the first time
/// it's asked: 20 ms on the main thread, in the frame the first chat opened (the composer's
/// attach menu). `warm()` at launch has the answer ready before then.
enum DeviceCamera {
    nonisolated static let isAvailable: Bool = AVCaptureDevice.default(for: .video) != nil

    nonisolated static func warm() {
        Task.detached(priority: .utility) { _ = isAvailable }
    }
}
#endif
