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

/// Keeps a streaming turn alive for a short while after the app moves to the background.
@MainActor
final class BackgroundActivity {
    #if os(iOS)
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    #endif

    func begin(_ name: String) {
        #if os(iOS)
        guard identifier == .invalid else { return }
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            self?.end()
        }
        #endif
    }

    func end() {
        #if os(iOS)
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
        #endif
    }
}
