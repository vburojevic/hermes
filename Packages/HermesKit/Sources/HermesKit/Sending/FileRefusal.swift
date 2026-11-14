import Foundation

/// Why Hermes didn't take a file attached to a message, in plain words (`docs/composer.md` §2).
/// The message goes back to the person with the file, so they can send it again or without it.
///
/// `file.attach` stages the file in the chat's `attachments/` folder and answers any failure as
/// 5028 with the exception's text (hermes-agent `tui_gateway/methods_prompt.py`,
/// `tui_gateway/prompt_attachments.py`): "invalid data_url payload", "attachment too large
/// (N bytes; cap is 256 MB)", or an OS error such as "[Errno 28] No space left on device: 'x'".
/// A missing payload is 4015, and a gateway older than file uploads answers -32601.
public struct FileRefusal: Error, Sendable, Equatable, LocalizedError {
    public enum Reason: Sendable, Equatable {
        /// This Hermes has no file uploads (`file.attach` came in backend contract v2).
        case notSupported
        /// Larger than Hermes takes; `cap` is its limit as Hermes wrote it ("256 MB").
        case tooLarge(cap: String?)
        /// Larger than this Hermes reads in one go, before 0.23.1 (`FileUpload.olderHermesLimit`).
        case tooLargeForThisHermes

        /// The Hermes computer's disk is full.
        case diskFull
        /// Hermes can't write to the chat's folder.
        case noPermission
        /// The file arrived broken or empty: sending it again usually works.
        case damaged
        /// Anything else: Hermes's own words.
        case other
    }

    /// The file's name, as the person picked it.
    public let name: String
    public let reason: Reason
    /// Hermes's own message, whole.
    public let message: String

    public init(name: String, reason: Reason, message: String) {
        self.name = name
        self.reason = reason
        self.message = message
    }

    /// Hermes refusing `file.attach` for the file called `name`.
    public init(name: String, _ error: GatewayRPCError) {
        self.init(name: name, reason: Self.reason(code: error.code, message: error.message), message: error.message)
    }

    /// Hermes refusing the file itself, or nil when the error isn't about the file: a session Hermes
    /// no longer has (4001: the chat resumes and uploads again), a socket that's retiring (5035: it
    /// reconnects and goes again), or a socket that dropped. Those are the send's to handle.
    public init?(name: String, refusing error: any Error) {
        guard let error = error as? GatewayRPCError, !error.isSessionNotFound, error.code != 5035 else { return nil }
        self.init(name: name, error)
    }

    /// A file larger than the Hermes it goes to reads in one frame (`FileUpload.limit`).
    public static func tooLargeForThisHermes(name: String) -> FileRefusal {
        FileRefusal(name: name, reason: .tooLargeForThisHermes, message: "")
    }

    static func reason(code: Int, message: String) -> Reason {
        let lowered = message.lowercased()
        if code == -32601 || lowered.contains("unknown method") { return .notSupported }
        if lowered.contains("too large") { return .tooLarge(cap: cap(in: message)) }
        if lowered.contains("errno 28") || lowered.contains("no space left") { return .diskFull }
        if lowered.contains("errno 13") || lowered.contains("permission denied") { return .noPermission }
        if code == 4015 || lowered.contains("invalid data_url") { return .damaged }
        return .other
    }

    /// "attachment too large (300 bytes; cap is 256 MB)" → "256 MB".
    static func cap(in message: String) -> String? {
        guard let start = message.range(of: "cap is ") else { return nil }
        let rest = message[start.upperBound...].prefix { $0 != ")" && $0 != ";" && !$0.isNewline }
        let cap = rest.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ".")))
        return cap.isEmpty ? nil : cap
    }

    public var errorDescription: String? {
        switch reason {
        case .notSupported:
            "This Hermes can't take files. Update Hermes on its computer to send “\(name)”."
        case .tooLarge(let cap?):
            "“\(name)” is larger than Hermes takes. Files can be up to \(cap)."
        case .tooLarge(nil):
            "“\(name)” is larger than Hermes takes."
        case .tooLargeForThisHermes:
            "“\(name)” is larger than this Hermes takes. Files can be up to \(FileUpload.olderHermesLimitText) until Hermes on its computer is updated."
        case .diskFull:
            "Hermes couldn't save “\(name)”: its computer is out of disk space."
        case .noPermission:
            "Hermes couldn't save “\(name)”: it isn't allowed to write to this chat's folder."
        case .damaged:
            "“\(name)” didn't reach Hermes whole. Send it again."
        case .other:
            "Hermes couldn't take “\(name)”: \(Self.firstLine(of: message) ?? "it gave no reason.")"
        }
    }

    private static func firstLine(of message: String) -> String? {
        let line = message.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces)
        return line?.isEmpty == false ? line : nil
    }
}
