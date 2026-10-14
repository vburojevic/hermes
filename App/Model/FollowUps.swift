import Foundation
import HermesKit
import SwiftUI

// Sending while Hermes works (docs/follow-ups.md): the five ways a message typed mid-turn can go,
// what became of each one, and the per-chat queue of messages that wait for the turn to end.

/// How Send delivers a message while a turn runs (`FollowUps.modeMenu`).
enum FollowUpMode: String, CaseIterable, Identifiable, Codable, Sendable {
    /// Hermes reads it after the current step and keeps going (`session.steer`).
    case steer
    /// Stops the current step and changes course (`session.redirect`).
    case redirect
    /// Waits in the queue tray and goes as the next turn (`prompt.submit {queued: true}`).
    case sendNext
    /// A quick answer on the side; the turn keeps going (`prompt.btw`).
    case askAside
    /// Another Hermes works on it; the result lands here (`prompt.background`).
    case background

    var id: String { rawValue }

    /// The chip's label.
    var title: String {
        switch self {
        case .steer: String(localized: "Steer")
        case .redirect: String(localized: "Redirect")
        case .sendNext: String(localized: "Send Next")
        case .askAside: String(localized: "Ask Aside")
        case .background: String(localized: "Background")
        }
    }

    /// The menu's name for it (the chip says "Background" for short).
    var menuTitle: String {
        self == .background ? String(localized: "Run in Background") : title
    }

    var detail: String {
        switch self {
        case .steer: String(localized: "Hermes reads it after the current step and keeps going.")
        case .redirect: String(localized: "Stops the current step and changes course.")
        case .sendNext: String(localized: "Waits until this reply is done, then sends it.")
        case .askAside: String(localized: "A quick answer on the side; this reply keeps going.")
        case .background: String(localized: "Another Hermes works on it; the result lands here.")
        }
    }

    var symbol: String {
        switch self {
        case .steer: "arrow.turn.up.right"
        case .redirect: "arrow.uturn.left"
        case .sendNext: "clock"
        case .askAside: "questionmark.bubble"
        case .background: "rectangle.stack"
        }
    }

    /// The modes a default can be (Settings → Chat): the ones Hermes' `busy` setting has.
    static let defaults: [FollowUpMode] = [.steer, .redirect, .sendNext]

    /// `display.busy_input_mode` (`config.get/set {key: "busy"}`) for a default.
    var busyInputMode: String? {
        switch self {
        case .steer: "steer"
        case .redirect: "interrupt"
        case .sendNext: "queue"
        case .askAside, .background: nil
        }
    }

    init?(busyInputMode: String) {
        switch busyInputMode {
        case "steer": self = .steer
        case "interrupt": self = .redirect
        case "queue": self = .sendNext
        default: return nil
        }
    }

    static let preferenceKey = "followUpDefault"

    /// Settings → Chat → "Sending while Hermes works". The app defaults to Steer: it never throws
    /// work away (Hermes' own default is to interrupt).
    static var preferredDefault: FollowUpMode {
        UserDefaults.standard.string(forKey: preferenceKey).flatMap(FollowUpMode.init(rawValue:)) ?? .steer
    }
}

/// A message sent mid-turn that isn't settled yet, from the gateway's answer and the events after
/// it — never from the mode that was picked. A steer Hermes read moves into its turn as a
/// `SteerNote`; a redirect becomes rows of the transcript.
struct FollowUpRecord: Identifiable, Equatable {
    enum State: Equatable {
        /// `session.steer` → `queued`: accepted, not read yet (dashed bubble with a spinner).
        case steerWaiting
        /// The turn ended before Hermes read it; Hermes sends it as the next message.
        case steerCarriedOver
        /// The turn ended first, Hermes refused it, or nothing sent it: `steerMissed`.
        case steerMissed
        /// Run in Background: working (`backgroundStarted`), then its answer (`backgroundCard`).
        case background(answer: String?)
    }

    let id: String
    let text: String
    var state: State
    /// The live turn it was sent into.
    var turnID: String?
    /// Sent as Redirect while a tool ran: Hermes doesn't stop a tool for it, and reads it after
    /// the step like a steer.
    var wasRedirect = false
    /// `prompt.background`'s task id.
    var taskID: String?

    init(text: String, state: State, turnID: String?, wasRedirect: Bool = false) {
        id = "followup-\(UUID().uuidString)"
        self.text = text
        self.state = state
        self.turnID = turnID
        self.wasRedirect = wasRedirect
    }

    /// The bubble's caption (`followUpBubble*`).
    var caption: FollowUpBubbleCaption? {
        let mode: FollowUpMode = wasRedirect ? .redirect : .steer
        switch state {
        case .steerWaiting:
            return FollowUpBubbleCaption(symbol: mode.symbol, text: String(localized: "\(mode.title) · Hermes reads it after this step"), spins: true)
        case .steerCarriedOver:
            return FollowUpBubbleCaption(symbol: mode.symbol, text: String(localized: "\(mode.title) · sends as the next message"), spins: true)
        case .background:
            return FollowUpBubbleCaption(symbol: FollowUpMode.background.symbol, text: FollowUpMode.background.menuTitle, spins: false)
        case .steerMissed:
            return nil
        }
    }

    /// Dashed while a steer is still unread.
    var isPending: Bool {
        state == .steerWaiting || state == .steerCarriedOver
    }
}

/// The line over a follow-up bubble: what was done with the message.
struct FollowUpBubbleCaption: Equatable {
    let symbol: String
    let text: String
    var spins = false
}

/// How a stored message was sent, kept for the captions after the transcript reloads.
enum FollowUpCaption: Equatable {
    case fromQueue
    /// `stoppedWhile`: what Hermes was doing when it changed course ("deleting snapshots").
    case redirect(stoppedWhile: String?)
    case steerAfterReply

    var bubble: FollowUpBubbleCaption {
        switch self {
        case .fromQueue: FollowUpBubbleCaption(symbol: FollowUpMode.sendNext.symbol, text: String(localized: "Sent from the queue"))
        case .redirect: FollowUpBubbleCaption(symbol: FollowUpMode.redirect.symbol, text: FollowUpMode.redirect.title)
        case .steerAfterReply: FollowUpBubbleCaption(symbol: FollowUpMode.steer.symbol, text: String(localized: "Steer · sent after the reply"))
        }
    }
}

/// One message waiting in the queue tray (Send Next).
struct QueuedFollowUp: Identifiable, Equatable {
    let id: UUID
    var text: String
    var parts: MessageParts?
    var skills: [String]
    var images: [ImageAttachment]
    var files: [FileAttachment]

    init(id: UUID = UUID(), text: String, parts: MessageParts? = nil, skills: [String] = [], images: [ImageAttachment] = [], files: [FileAttachment] = []) {
        self.id = id
        self.text = text
        self.parts = parts
        self.skills = skills
        self.images = images
        self.files = files
    }

    var hasAttachments: Bool { !images.isEmpty || !files.isEmpty }

    /// One line for the tray.
    var line: String {
        let collapsed = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        if !collapsed.isEmpty { return collapsed }
        if let file = files.first { return file.name }
        return images.isEmpty ? "" : String(localized: "Photo")
    }
}

/// Keeps each chat's queue on the device (Application Support), attachments included, so it
/// survives a restart.
enum FollowUpQueueStore {
    private struct Entry: Codable {
        var id: UUID
        var text: String
        var parts: MessageParts?
        var skills: [String]
        var images: [String]
        var files: [StoredFile]
    }

    private struct StoredFile: Codable {
        var name: String
        var blob: String
    }

    private static var root: URL? {
        try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: "FollowUpQueues", directoryHint: .isDirectory)
    }

    private static func folder(for key: String) -> URL? {
        let safe = key.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" ? String($0) : "_" }.joined()
        return root?.appending(path: safe, directoryHint: .isDirectory)
    }

    static func load(key: String) -> [QueuedFollowUp] {
        guard let folder = folder(for: key),
              let data = try? Data(contentsOf: folder.appending(path: "queue.json")),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return entries.map { entry in
            QueuedFollowUp(
                id: entry.id,
                text: entry.text,
                parts: entry.parts,
                skills: entry.skills,
                images: entry.images.compactMap { name in
                    (try? Data(contentsOf: folder.appending(path: name))).flatMap { ImageAttachment(jpegData: $0) }
                },
                files: entry.files.compactMap { file in
                    (try? Data(contentsOf: folder.appending(path: file.blob))).map { FileAttachment(name: file.name, data: $0) }
                }
            )
        }
    }

    static func save(_ queue: [QueuedFollowUp], key: String) {
        guard let folder = folder(for: key) else { return }
        let manager = FileManager.default
        if queue.isEmpty {
            try? manager.removeItem(at: folder)
            return
        }
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
        var keep: Set<String> = ["queue.json"]
        let entries = queue.map { item in
            let images = item.images.map { image -> String in
                let name = "\(image.id.uuidString).jpg"
                keep.insert(name)
                let url = folder.appending(path: name)
                if !manager.fileExists(atPath: url.path) { try? image.jpegData.write(to: url) }
                return name
            }
            let files = item.files.map { file -> StoredFile in
                let blob = "\(file.id.uuidString).blob"
                keep.insert(blob)
                let url = folder.appending(path: blob)
                if !manager.fileExists(atPath: url.path) { try? file.data.write(to: url) }
                return StoredFile(name: file.name, blob: blob)
            }
            return Entry(id: item.id, text: item.text, parts: item.parts, skills: item.skills, images: images, files: files)
        }
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: folder.appending(path: "queue.json"), options: .atomic)
        }
        // Attachments of items that left the queue.
        for name in (try? manager.contentsOfDirectory(atPath: folder.path)) ?? [] where !keep.contains(name) {
            try? manager.removeItem(at: folder.appending(path: name))
        }
    }
}

// MARK: - Settings

/// Settings → Chat → "Sending while Hermes works" (`screens/iphone/settings.elyx`,
/// `macSettingsChat`). It also sets Hermes' own `busy` setting (`display.busy_input_mode`) on
/// every gateway, so other apps behave the same; one already changed there (to Steer or Send Next)
/// is picked up while the app has no choice of its own.
struct FollowUpDefaultPicker: View {
    @Environment(AppModel.self) private var app
    @AppStorage(FollowUpMode.preferenceKey) private var stored = FollowUpMode.steer.rawValue

    private var selection: Binding<FollowUpMode> {
        Binding {
            FollowUpMode(rawValue: stored) ?? .steer
        } set: { mode in
            stored = mode.rawValue
            setOnGateways(mode)
        }
    }

    private var rosters: [BotRoster] {
        app.workspaces.values.compactMap(\.roster).filter(\.isConnected)
    }

    var body: some View {
        Picker(selection: selection) {
            ForEach(FollowUpMode.defaults) { mode in
                Text(mode.title).tag(mode)
            }
        } label: {
            Text("Sending while Hermes works")
            #if os(macOS)
            Text("Return uses this; ⌥Return sends next, ⌘Return redirects.")
            #endif
        }
        .task { await adoptGatewayDefault() }
    }

    private func setOnGateways(_ mode: FollowUpMode) {
        guard let value = mode.busyInputMode else { return }
        for roster in rosters {
            Task { _ = try? await roster.request("config.set", ["key": .string("busy"), "value": .string(value)]) }
        }
    }

    private func adoptGatewayDefault() async {
        guard UserDefaults.standard.object(forKey: FollowUpMode.preferenceKey) == nil, let roster = rosters.first,
              let result = try? await roster.request("config.get", ["key": .string("busy")]),
              let value = GatewayQueue.busyMode(in: result), value != "interrupt", // Hermes' own default
              let mode = FollowUpMode(busyInputMode: value)
        else { return }
        stored = mode.rawValue
    }
}
