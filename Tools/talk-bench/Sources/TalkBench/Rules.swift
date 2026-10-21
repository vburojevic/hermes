import Foundation
import HermesKit

/// What a rule did in one call, in the call's seconds.
struct Outcome: @unchecked Sendable {
    var bargeIns: [Double] = []
    var ducks: [Double] = []
    var turnEnds: [Double] = []
    var turns: [String] = []
    var log: [String] = []
}

/// What a rule asks the call to do, as the engine does for the app.
enum Request {
    case duck, restore, stopBot, endTurn, dropTurn
}

/// One way of deciding.
protocol Rule: Sendable {
    var outcome: Outcome { get set }
    var isBotSpeaking: Bool { get }
    /// Whether the transcriber hears through a `NearGate`, and its threshold now.
    var gates: Bool { get }
    var gateThreshold: Float? { get }
    mutating func frame(level: Float, at time: Double, botLevel: Float?) -> [Request]
    mutating func heard(_ words: HeardWords, at time: Double) -> [Request]
    mutating func botStarted(at time: Double, saying text: String) -> [Request]
    mutating func botStopped(at time: Double) -> [Request]
    /// The transcriber settled the turn (sent) or forgot it.
    mutating func turnEnded(at time: Double, words: String, sent: Bool)
}

/// Barge-in as it shipped in 1.0 beta (`HermesVoiceEngine` with `BargeInDetector`): 250 ms of
/// voice activity over the Bot, outside its first 400 ms, or a stop word; the turn ends from
/// voice activity and from words as they arrive.
struct OldRule: Rule {
    var outcome = Outcome()
    private var vad = VoiceActivityDetector()
    private var endpointer = Endpointer(pause: .normal)
    private var botSince: Double?
    private var speechSince: Double?
    private var fired = false
    private var heardOverBot = false
    private var ending = false

    var isBotSpeaking: Bool { botSince != nil }
    var gates: Bool { false }
    var gateThreshold: Float? { nil }

    mutating func frame(level: Float, at time: Double, botLevel: Float?) -> [Request] {
        // The old feed measured on the meter's 0…1 scale: nothing below −50 dB.
        let rms: Float = level <= -50 ? 0 : pow(10, level / 20)
        switch vad.process(rms: rms, at: time) {
        case .started(let at)?:
            speechSince = at
            endpointer.speechStarted(at: at)
        case .ended(let at)?:
            speechSince = nil
            endpointer.speechEnded(at: at)
        case nil:
            break
        }
        if let botSince, let speechSince, !fired, time - max(speechSince, botSince + 0.4) >= 0.25 {
            fired = true
            heardOverBot = false
            outcome.bargeIns.append(time)
            outcome.log.append(String(format: "%6.2f old barge-in: voice 250 ms", time))
            return [.stopBot]
        }
        if botSince == nil, !ending, endpointer.isComplete(at: time) {
            ending = true
            return [.endTurn]
        }
        return []
    }

    mutating func heard(_ words: HeardWords, at time: Double) -> [Request] {
        if botSince != nil {
            heardOverBot = !words.text.isEmpty
            if !fired, TalkEars.isStopPhrase(words.text) {
                fired = true
                heardOverBot = false
                outcome.bargeIns.append(time)
                outcome.log.append(String(format: "%6.2f old barge-in: stop word", time))
                return [.stopBot]
            }
        } else {
            endpointer.heard(words.text, at: time)
        }
        return []
    }

    mutating func botStarted(at time: Double, saying text: String) -> [Request] {
        botSince = time
        fired = false
        return []
    }

    mutating func botStopped(at time: Double) -> [Request] {
        guard botSince != nil else { return [] }
        botSince = nil
        if heardOverBot {
            heardOverBot = false
            endpointer.reset()
            return [.dropTurn]
        }
        if fired { endpointer.speechStarted(at: time) }
        return []
    }

    mutating func turnEnded(at time: Double, words: String, sent: Bool) {
        if sent, !words.isEmpty {
            outcome.turnEnds.append(time)
            outcome.turns.append(words)
        }
        endpointer.reset()
        ending = false
    }
}

/// The app's rule now: `TalkEars`.
struct NewRule: Rule {
    var outcome = Outcome()
    private var ears = TalkEars(pause: .normal)

    var isBotSpeaking: Bool { ears.isBotSpeaking }
    var gates: Bool { true }
    var gateThreshold: Float? { ears.gateThreshold }

    mutating func frame(level: Float, at time: Double, botLevel: Float?) -> [Request] {
        apply(ears.frame(level: level, at: time, botLevel: ears.isBotSpeaking ? botLevel : nil), at: time)
    }

    mutating func heard(_ words: HeardWords, at time: Double) -> [Request] {
        let runs = words.runs.map { String(format: "%@[%.2f-%.2f%@]", $0.text, $0.start, $0.end, $0.confidence.map { String(format: " %.2f", $0) } ?? "") }
        outcome.log.append(String(format: "%6.2f heard ", time) + runs.joined())
        return apply(ears.heard(words, at: time), at: time)
    }

    mutating func botStarted(at time: Double, saying text: String) -> [Request] {
        apply(ears.botStarted(at: time, saying: text), at: time)
    }

    mutating func botStopped(at time: Double) -> [Request] {
        apply(ears.botStopped(at: time), at: time)
    }

    mutating func turnEnded(at time: Double, words: String, sent: Bool) {
        if sent, !words.isEmpty {
            outcome.turnEnds.append(time)
            outcome.turns.append(words)
        }
        ears.turnEnded(at: time, sent: sent && !words.isEmpty)
    }

    private mutating func apply(_ decisions: [TalkEars.Decision], at time: Double) -> [Request] {
        var requests: [Request] = []
        for decision in decisions {
            outcome.log.append(String(format: "%6.2f new ", time) + decision.description)
            switch decision.action {
            case .duck:
                outcome.ducks.append(time)
                requests.append(.duck)
            case .restore: requests.append(.restore)
            case .bargeIn:
                outcome.bargeIns.append(time)
                requests.append(.stopBot)
            case .endTurn: requests.append(.endTurn)
            case .discardHeard: requests.append(.dropTurn)
            case nil: break
            }
        }
        return requests
    }
}
