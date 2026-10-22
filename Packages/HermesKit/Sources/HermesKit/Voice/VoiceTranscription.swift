import Foundation
import Observation

/// The gateway's words for a voice message the device heard none in (`docs/voice.md` §2,
/// `POST /api/audio/transcribe`). The message shows as audio at once; Hermes reads its words, so
/// the prompt goes once they're back. When there are none, it goes with the recording alone, as
/// before, and the bubble says why.
public enum VoiceTranscription: Equatable, Sendable {
    /// Asked of the gateway, or waiting to ask it again (it's away or busy).
    case pending
    case heard(String)
    /// The gateway heard no words in it (silence, or noise).
    case noWords
    /// The gateway couldn't transcribe it: why, in a sentence.
    case failed(String)

    /// What one try at the gateway's words means.
    public enum Outcome: Equatable, Sendable {
        case settled(VoiceTranscription)
        /// The gateway didn't answer (away, restarting, too busy): ask again after a pause.
        case tryAgain
        /// Stop took the message back.
        case cancelled
    }

    /// What one try's result means. Hermes answers a refusal (no speech provider, a recording it
    /// can't read) with a 400 and a provider's failure with a 500, each with its words, and no
    /// speech with an empty transcript (`hermes_cli/web_routers/audio.py`). Only an answer that
    /// never came is asked again.
    public static func outcome(of result: Result<String, any Error>) -> Outcome {
        switch result {
        case .success(let words):
            let words = words.trimmingCharacters(in: .whitespacesAndNewlines)
            return .settled(words.isEmpty ? .noWords : .heard(words))
        case .failure(let error):
            if error is CancellationError { return .cancelled }
            if BackendClient.isSlowAnswer(error) || error as? BackendClient.Failure == .rateLimited {
                return .tryAgain
            }
            if error is HermesError || error is URLError, SendFailure.overHTTP(error) == .sendAgain {
                return .tryAgain
            }
            return .settled(.failed(reason(error)))
        }
    }

    /// The words the message goes with: none unless the gateway heard some.
    public var words: String {
        if case .heard(let words) = self { words } else { "" }
    }

    /// The line under the waveform when a voice message has no transcript: what's happening, or
    /// why there's none. `nil` while there's a transcript to show, or while it's on its way (the
    /// turn's live line says "Transcribing…": one moving thing per place).
    public static func note(text: String, state: VoiceTranscription?) -> String? {
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        switch state {
        case .pending?, .heard?: return nil
        case .noWords?: return String(localized: "No words were heard in it.")
        case .failed(let reason)?:
            return reason.isEmpty ? String(localized: "Couldn't transcribe it.") : String(localized: "Couldn't transcribe it. \(reason)")
        // Sent before this run of the app, or from another device: the gateway has no words for it.
        case nil: return String(localized: "No transcript.")
        }
    }

    /// What VoiceOver reads for the person's voice message: its length, then its transcript, or
    /// what became of it.
    public static func spokenLabel(duration: String?, text: String, state: VoiceTranscription?) -> String {
        let head = duration.map { String(localized: "Your voice message, \($0)") } ?? String(localized: "Your voice message")
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return "\(head): \(text)" }
        if case .pending? = state { return String(localized: "\(head), transcribing") }
        if case .heard(let words)? = state { return "\(head): \(words)" }
        return note(text: text, state: state).map { "\(head). \($0)" } ?? head
    }

    /// The gateway's reason in its first sentence: Hermes's "No STT provider available. Install
    /// faster-whisper …" is a paragraph of setup steps.
    static func reason(_ error: any Error) -> String {
        let described = (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
        let line = described.split(whereSeparator: \.isNewline).first.map(String.init) ?? described
        var sentence = line
        if let end = line.range(of: ". ") { sentence = String(line[..<end.lowerBound]) + "." }
        sentence = sentence.trimmingCharacters(in: .whitespaces)
        if sentence.count > 160 { sentence = String(sentence.prefix(159)) + "…" }
        if let last = sentence.last, !".!?…".contains(last) { sentence += "." }
        return sentence
    }
}

/// Where each voice message's gateway transcription stands, by its file name (`voice-<uuid>.m4a`),
/// so the bubble finds it whether it's the row on its way or the one Hermes stored.
@MainActor @Observable
public final class VoiceTranscripts {
    public static let shared = VoiceTranscripts()

    private var states: [String: VoiceTranscription] = [:]

    public init() {}

    public func state(for path: String) -> VoiceTranscription? {
        states[Self.key(path)]
    }

    public func set(_ state: VoiceTranscription?, for path: String) {
        states[Self.key(path)] = state
    }

    /// One name for the recording on this device and its path on the gateway.
    private static func key(_ path: String) -> String {
        (path as NSString).lastPathComponent.lowercased()
    }
}
