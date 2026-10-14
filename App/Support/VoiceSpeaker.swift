import AVFoundation
import Foundation
import Observation

/// Reads replies aloud on the device (`docs/composer.md` §4): Hermes's `voice.tts` plays on the
/// gateway's speakers, so Voice mode synthesises here, sentence by sentence as the reply streams.
@MainActor
@Observable
final class VoiceSpeaker {
    /// The sentence being read, for the caption.
    private(set) var currentSentence: String?
    private(set) var isSpeaking = false

    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private let relay = Relay()
    @ObservationIgnored private var queued = 0

    init() {
        synthesizer.delegate = relay
        relay.onStart = { [weak self] text in self?.currentSentence = text }
        relay.onFinish = { [weak self] in self?.utteranceEnded() }
    }

    /// Queues text to be read after what's already queued.
    func speak(_ text: String) {
        let spoken = SpeechText.clean(text)
        guard !spoken.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: spoken)
        utterance.voice = Self.voice
        utterance.prefersAssistiveTechnologySettings = true
        queued += 1
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    /// Stops at once (barge-in, Mute, End).
    func stop() {
        queued = 0
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
        currentSentence = nil
    }

    private func utteranceEnded() {
        queued = max(0, queued - 1)
        if queued == 0 {
            isSpeaking = false
        }
    }

    /// The best installed voice for the person's language.
    private static let voice: AVSpeechSynthesisVoice? = {
        let language = AVSpeechSynthesisVoice.currentLanguageCode()
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == language }
        return voices.max { $0.quality.rawValue < $1.quality.rawValue } ?? AVSpeechSynthesisVoice(language: language)
    }()

    /// The synthesizer calls back on its own queue.
    private final class Relay: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
        @MainActor var onStart: ((String) -> Void)?
        @MainActor var onFinish: (() -> Void)?

        nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
            let text = utterance.speechString
            Task { @MainActor in self.onStart?(text) }
        }

        nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
            Task { @MainActor in self.onFinish?() }
        }

        nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
            Task { @MainActor in self.onFinish?() }
        }
    }
}

/// Turns a Markdown reply into something worth hearing: no code, tables, links or markup.
nonisolated enum SpeechText {
    static func clean(_ markdown: String) -> String {
        var lines: [String] = []
        var inCode = false
        for raw in markdown.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                inCode.toggle()
                continue
            }
            if inCode || line.hasPrefix("|") || line.allSatisfy({ "-=*_ ".contains($0) }) && !line.isEmpty {
                continue
            }
            var text = line
            // Headings, quotes, list markers and task boxes.
            text = text.replacingOccurrences(of: #"^(#{1,6}\s+|>\s*|[-*+]\s+(\[[ xX]\]\s+)?|\d+[.)]\s+)"#, with: "", options: .regularExpression)
            // Links and images: keep the label.
            text = text.replacingOccurrences(of: #"!?\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
            // Bare URLs aren't worth reading out.
            text = text.replacingOccurrences(of: #"https?://\S+"#, with: "", options: .regularExpression)
            // Emphasis and inline code markers.
            text = text.replacingOccurrences(of: #"[*_`~]+"#, with: "", options: .regularExpression)
            if !text.isEmpty { lines.append(text) }
        }
        return lines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The end of the last whole sentence in `text` after `start`, if there is one.
    static func sentenceBoundary(in text: String, from start: String.Index) -> String.Index? {
        var boundary: String.Index?
        var index = start
        var inCode = false
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if character == "`" { inCode.toggle() }
            if !inCode {
                if character == "\n" {
                    boundary = next
                } else if ".!?…:".contains(character), next < text.endIndex, text[next] == " " || text[next] == "\n" {
                    boundary = next
                }
            }
            index = next
        }
        return boundary
    }
}
