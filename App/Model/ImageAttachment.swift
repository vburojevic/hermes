import Foundation
import HermesKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// An image ready to send: downscaled, re-encoded as JPEG, with a decoded preview.
struct ImageAttachment: Identifiable, Hashable {
    let id: UUID
    let jpegData: Data
    let preview: PlatformImage

    init?(jpegData: Data, id: UUID = UUID()) {
        guard let preview = PlatformImage(data: jpegData) else { return nil }
        self.id = id
        self.jpegData = jpegData
        self.preview = preview
    }

    static func == (lhs: ImageAttachment, rhs: ImageAttachment) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    var dataURL: String {
        "data:image/jpeg;base64," + jpegData.base64EncodedString()
    }

    /// Longest edge sent to Hermes. Vision models gain little beyond this and the
    /// request body is capped at 10 MB.
    nonisolated static let maxPixelSize = 1600

    /// Downscales and re-encodes any image data off the main thread.
    static func make(from data: Data) async -> ImageAttachment? {
        let jpeg = await Task.detached(priority: .userInitiated) {
            Self.normalizedJPEG(from: data)
        }.value
        return jpeg.flatMap { ImageAttachment(jpegData: $0) }
    }

    nonisolated static func normalizedJPEG(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}

/// Hermes stores sent images only as `[screenshot]` placeholders, so the app keeps
/// its own copy to show them again when the conversation is reopened.
@MainActor
final class SentImageStore {
    private let directory: URL
    private var index: [String: [[String]]] = [:]
    private var loaded = false
    /// Sent this run, possibly not on disk yet.
    private var recent: [String: ImageAttachment] = [:]
    private static let writes = DispatchQueue(label: "SentImageStore.writes", qos: .utility)

    init(botID: UUID) {
        directory = HermesStorage.applicationSupport
            .appending(path: "SentImages/\(botID.uuidString)", directoryHint: .isDirectory)
    }

    private var indexURL: URL { directory.appending(path: "index.json") }

    private static func key(conversation: String, text: String) -> String {
        conversation + "\u{1F}" + text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func remember(_ images: [ImageAttachment], conversation: String, text: String) {
        guard !images.isEmpty else { return }
        loadIfNeeded()
        let files = images.map { (name: $0.id.uuidString + ".jpg", data: $0.jpegData) }
        let names = files.map(\.name)
        for (image, name) in zip(images, names) { recent[name] = image }
        index[Self.key(conversation: conversation, text: text), default: []].append(names)
        // Written off the main thread, in order; until then `recent` answers for them.
        let directory = self.directory, indexURL = self.indexURL, index = self.index
        Self.writes.async { [weak self] in
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                for file in files {
                    try file.data.write(to: directory.appending(path: file.name), options: .atomic)
                }
                try JSONEncoder().encode(index).write(to: indexURL, options: .atomic)
            } catch {
                // Losing a local preview is harmless; the message itself was sent.
            }
            Task { @MainActor [weak self] in
                for name in names { self?.recent[name] = nil }
            }
        }
    }

    /// Images for the `occurrence`-th user message with this text in the conversation.
    func images(conversation: String, text: String, occurrence: Int) -> [ImageAttachment] {
        slots(conversation: conversation, text: text, occurrence: occurrence).compactMap { slot in
            switch slot {
            case .ready(let image): image
            case .file(let id, let url): (try? Data(contentsOf: url)).flatMap { ImageAttachment(jpegData: $0, id: id) }
            }
        }
    }

    /// One of a message's images: in memory already, or a file to read.
    enum Slot {
        case ready(ImageAttachment)
        case file(id: UUID, url: URL)
    }

    /// `images` without reading anything: what's at hand, and which files hold the rest (for
    /// `read`, off the main thread).
    func slots(conversation: String, text: String, occurrence: Int) -> [Slot] {
        loadIfNeeded()
        guard let sets = index[Self.key(conversation: conversation, text: text)], occurrence < sets.count else { return [] }
        return sets[occurrence].map { name in
            if let image = recent[name] { return .ready(image) }
            return .file(id: UUID(uuidString: String(name.dropLast(4))) ?? UUID(), url: directory.appending(path: name))
        }
    }

    /// Reads these files off the main thread.
    nonisolated static func read(_ urls: [URL]) async -> [URL: Data] {
        await Task.detached(priority: .userInitiated) {
            var contents: [URL: Data] = [:]
            for url in urls {
                contents[url] = try? Data(contentsOf: url)
            }
            return contents
        }.value
    }

    /// Re-keys a conversation's images after the session id it was stored under changes.
    func move(from old: String, to new: String) {
        loadIfNeeded()
        let prefix = old + "\u{1F}"
        let moved = index.filter { $0.key.hasPrefix(prefix) }
        guard !moved.isEmpty else { return }
        for (key, value) in moved {
            index[key] = nil
            index[new + "\u{1F}" + key.dropFirst(prefix.count)] = value
        }
        let indexURL = self.indexURL, index = self.index
        Self.writes.async { try? JSONEncoder().encode(index).write(to: indexURL, options: .atomic) }
    }

    func removeAll() {
        let directory = self.directory
        Self.writes.async { try? FileManager.default.removeItem(at: directory) }
        index = [:]
        recent = [:]
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        if let data = try? Data(contentsOf: indexURL), let stored = try? JSONDecoder().decode([String: [[String]]].self, from: data) {
            index = stored
        }
    }
}
