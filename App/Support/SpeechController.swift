import AVFoundation
import HermesMarkdown
import Observation

/// Reads replies aloud with the system voice.
@MainActor
@Observable
final class SpeechController: NSObject {
    static let shared = SpeechController()

    private(set) var speakingText: String?
    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private var currentUtterance: ObjectIdentifier?

    override private init() {
        super.init()
        synthesizer.delegate = self
    }

    func isSpeaking(_ text: String) -> Bool {
        speakingText == text
    }

    func toggle(_ text: String) {
        if speakingText == text {
            stop()
            return
        }
        stop()
        let spoken = MarkdownDocument(parsing: text).spokenText
        guard !spoken.isEmpty else { return }
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        let utterance = AVSpeechUtterance(string: spoken)
        utterance.prefersAssistiveTechnologySettings = true
        speakingText = text
        currentUtterance = ObjectIdentifier(utterance)
        synthesizer.speak(utterance)
    }

    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        speakingText = nil
        currentUtterance = nil
    }

    fileprivate func finished(_ utterance: ObjectIdentifier) {
        // A cancelled utterance reports back after the next one may have started.
        guard utterance == currentUtterance else { return }
        currentUtterance = nil
        speakingText = nil
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}

extension SpeechController: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.finished(id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.finished(id) }
    }
}
