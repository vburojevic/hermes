import Foundation
import HermesKit

// The Talk noise bench (`docs/voice.md` §12): a call in a noisy room, heard by the Mac's own
// on-device transcriber in real time, decided by the old rule and by `TalkEars` side by side.
//
//   Tools/talk-bench/make-clips.sh build/talk-bench/clips
//   swift run -c release --package-path Tools/talk-bench talk-bench --clips build/talk-bench/clips
//
// Each call: the person's turn at 0.5 s ("Check the NAS for me please."), the Bot's reply from 4 s
// with a little of it coming back through the room (what an echo canceller leaves), and, over the
// reply at 6.5 s, the person saying a phrase, or nothing. The noise runs throughout. Voice
// processing isn't in the loop (it runs only on a live microphone), so this is the worst case for
// the noise: the app's input is cleaner.

struct Options {
    var clips = URL(fileURLWithPath: "build/talk-bench/clips")
    var transcriber = TranscriberKind.speech
    var noises = Noise.allCases
    var phrases = Phrase.allCases
    var parallel = 4
    var verbose = false

    init(_ arguments: [String]) {
        var rest = arguments.dropFirst()
        while let flag = rest.popFirst() {
            switch flag {
            case "--clips": clips = URL(fileURLWithPath: rest.popFirst() ?? "")
            case "--transcriber": transcriber = TranscriberKind(rawValue: rest.popFirst() ?? "") ?? .speech
            case "--noise": noises = (rest.popFirst() ?? "").split(separator: ",").compactMap { Noise(rawValue: String($0)) }
            case "--phrase": phrases = (rest.popFirst() ?? "").split(separator: ",").compactMap { Phrase(rawValue: String($0)) }
            case "--parallel": parallel = Int(rest.popFirst() ?? "") ?? 4
            case "--verbose": verbose = true
            case "--echo": Scenario.echo = Float(rest.popFirst() ?? "") ?? -35
            default: print("unknown option \(flag)")
            }
        }
    }
}

struct Scenario: Sendable {
    static let turnAt = 0.5
    static let botAt = 4.0
    static let phraseAt = 6.5
    static let person: Float = -24
    static let botOutput: Float = -20
    /// What the echo canceller leaves of the Bot (`--echo`): an iPhone's leaves little.
    nonisolated(unsafe) static var echo: Float = -35

    var noise: Noise
    var phrase: Phrase
}

struct Result: Sendable {
    var scenario: Scenario
    var old: Outcome
    var new: Outcome
    var turnEnd: Double
    var phraseSpan: (start: Double, end: Double)?
    var botEnd: Double
}

/// Builds the call's audio and runs both rules over it, each in its own call (its own
/// transcriber, and a Bot that stops when that rule stops it), at the same time, in real time.
func run(_ scenario: Scenario, clips: Clips, kind: TranscriberKind) async throws -> Result {
    let turn = clips.turn.scaled(to: Scenario.person)
    let bot = clips.bot.scaled(to: Scenario.botOutput)
    let phrase = scenario.phrase == .none ? nil : clips.phrases[scenario.phrase.rawValue]?.scaled(to: Scenario.person)
    let botEnd = Scenario.botAt + bot.duration
    let length = phrase.map { Scenario.phraseAt + $0.duration + 2.5 } ?? botEnd + 2.5
    var room = scenario.noise.render(seconds: length, clips: clips)
    room.mix(turn, at: Scenario.turnAt)
    if let phrase { room.mix(phrase, at: Scenario.phraseAt) }
    async let old = Call(rule: OldRule(), room: room, bot: bot, kind: kind).run()
    async let new = Call(rule: NewRule(), room: room, bot: bot, kind: kind).run()
    let span = phrase.map { (Scenario.phraseAt + $0.activeSpan.start, Scenario.phraseAt + $0.activeSpan.end) }
    return try await Result(scenario: scenario, old: old, new: new, turnEnd: Scenario.turnAt + turn.activeSpan.end, phraseSpan: span, botEnd: botEnd)
}

/// One call: the room's sound, the Bot's reply coming back through it while it plays, the
/// transcriber and a rule, as `HermesVoiceEngine` runs them.
actor Call<R: Rule> {
    private var rule: R
    private let room: Signal
    private let bot: Signal
    private let botLevels: [Float]
    private let kind: TranscriberKind
    private var transcriber: Transcriber?
    private var time = 0.0
    /// Where the Bot's reply is, while it plays.
    private var botPosition: Int?
    private var botGain: Float = 1

    init(rule: R, room: Signal, bot: Signal, kind: TranscriberKind) {
        self.rule = rule
        self.room = room
        self.bot = bot
        botLevels = bot.frameLevels()
        self.kind = kind
    }

    func run() async throws -> Outcome {
        let transcriber = try await Transcriber(kind: kind, shift: rule.gates ? NearGate.delay : 0)
        self.transcriber = transcriber
        var gate = NearGate(sampleRate: Signal.rate)
        let results = transcriber.results { [weak self] words in await self?.heard(words) }
        let frame = Int(Signal.rate / 50)
        let echo = pow(10, Scenario.echo / 20)
        let start = ProcessInfo.processInfo.systemUptime
        var index = 0
        while index * frame < room.samples.count {
            time = Double(index) * 0.02
            if botPosition == nil, abs(time - Scenario.botAt) < 0.01 {
                botPosition = 0
                handle(rule.botStarted(at: time, saying: Clips.botText))
            }
            var slice = Array(room.samples[(index * frame)..<min(room.samples.count, (index + 1) * frame)])
            var botLevel: Float?
            if let position = botPosition {
                for offset in slice.indices where position + offset < bot.samples.count {
                    slice[offset] += bot.samples[position + offset] * echo * botGain
                }
                let frameIndex = position / frame
                botLevel = frameIndex < botLevels.count ? botLevels[frameIndex] + 20 * log10(botGain) : nil
                botPosition = position + frame
                if position + frame >= bot.samples.count { stopBot() }
            }
            // The level is the microphone's; only the transcriber hears through the gate.
            let level = Signal.level(slice[...])
            if rule.gates {
                gate.threshold = rule.gateThreshold
                slice.withUnsafeMutableBufferPointer { gate.process($0) }
            }
            transcriber.feed(slice[...])
            handle(rule.frame(level: level, at: time, botLevel: botLevel))
            index += 1
            let wait = start + Double(index) * 0.02 - ProcessInfo.processInfo.systemUptime
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
        }
        try? await Task.sleep(for: .milliseconds(300))
        await transcriber.finish()
        results.cancel()
        return rule.outcome
    }

    private func heard(_ words: HeardWords) {
        handle(rule.heard(words, at: time))
    }

    private func stopBot() {
        guard botPosition != nil else { return }
        botPosition = nil
        botGain = 1
        handle(rule.botStopped(at: time))
    }

    private func handle(_ requests: [Request]) {
        for request in requests {
            switch request {
            case .duck: botGain = 0.3
            case .restore: botGain = 1
            case .stopBot: stopBot()
            case .endTurn:
                Task {
                    let words = await transcriber?.endTurn() ?? ""
                    self.ended(words, sent: true)
                }
            case .dropTurn:
                Task { _ = await transcriber?.endTurn() }
            }
        }
    }

    private func ended(_ words: String, sent: Bool) {
        rule.turnEnded(at: time, words: words, sent: sent)
    }
}

// MARK: Scoring

struct Score {
    var falseBargeIns = 0
    var earlyStops = 0
    var calls = 0
    var shouldStop = 0
    var caught = 0
    var stopLatencies: [Double] = []
    var yieldLatencies: [Double] = []
    var dips = 0
    var quietCalls = 0
    var turnLatencies: [Double] = []
    var heldOpen = 0
    var falseTurns = 0
}

func verdict(_ outcome: Outcome, _ result: Result, score: inout Score, yields: Bool) -> String {
    score.calls += 1
    let scenario = result.scenario
    var parts: [String] = []
    // The first turn: when it ended, and whether noise held it open past the Bot's start.
    if let end = outcome.turnEnds.first(where: { $0 > result.turnEnd - 0.2 }), end < Scenario.botAt {
        score.turnLatencies.append(end - result.turnEnd)
    } else {
        score.heldOpen += 1
        parts.append("first turn " + (outcome.turnEnds.first.map { String(format: "ended at %.1f s", $0) } ?? "never ended"))
    }
    let noiseTurns = outcome.turnEnds.filter { $0 < Scenario.botAt }.count - 1
    let afterBot = scenario.phrase == .none ? outcome.turnEnds.filter { $0 > result.botEnd }.count : 0
    score.falseTurns += max(0, noiseTurns) + afterBot
    let early = outcome.bargeIns.filter { $0 < (result.phraseSpan?.start ?? .infinity) }
    if scenario.phrase.interrupts, let span = result.phraseSpan {
        score.shouldStop += 1
        if !early.isEmpty {
            score.earlyStops += 1
            parts.append(String(format: "stopped early at %.1f s", early[0]))
        } else if let stop = outcome.bargeIns.first(where: { $0 >= span.start && $0 <= span.end + 2 }) {
            score.caught += 1
            score.stopLatencies.append(stop - span.end)
            var line = String(format: "stopped %+.0f ms", (stop - span.end) * 1000)
            if yields, let duck = outcome.ducks.first(where: { $0 >= span.start && $0 <= stop }) {
                score.yieldLatencies.append(duck - span.start)
                line += String(format: " (dipped %.0f ms in)", (duck - span.start) * 1000)
            }
            parts.append(line)
        } else {
            parts.append("MISSED")
        }
    } else {
        if !outcome.bargeIns.isEmpty {
            score.falseBargeIns += 1
            parts.append(String(format: "FALSE STOP at %.1f s", outcome.bargeIns[0]))
        } else {
            parts.append("kept talking")
        }
        if yields, scenario.phrase == .none {
            score.quietCalls += 1
            score.dips += outcome.ducks.count
            if !outcome.ducks.isEmpty { parts.append("\(outcome.ducks.count) dip\(outcome.ducks.count == 1 ? "" : "s")") }
        }
    }
    if noiseTurns > 0 || afterBot > 0 { parts.append("\(max(0, noiseTurns) + afterBot) noise turn\(noiseTurns + afterBot == 1 ? "" : "s")") }
    return parts.joined(separator: ", ")
}

func summary(_ name: String, _ score: Score) -> String {
    func ms(_ values: [Double]) -> String {
        guard !values.isEmpty else { return "–" }
        let sorted = values.sorted()
        return String(format: "median %.0f ms, worst %.0f ms", sorted[sorted.count / 2] * 1000, sorted.last! * 1000)
    }
    var lines = ["**\(name)**",
                 "- false stops: \(score.falseBargeIns) of \(score.calls - score.shouldStop) calls that shouldn't stop; stopped before the person spoke: \(score.earlyStops) of \(score.shouldStop)",
                 "- interruptions caught: \(score.caught) of \(score.shouldStop); from the end of the phrase: \(ms(score.stopLatencies))"]
    if !score.yieldLatencies.isEmpty { lines.append("- the Bot yields (dips) from the start of the phrase: \(ms(score.yieldLatencies))") }
    if score.quietCalls > 0 { lines.append("- dips with nobody talking: \(score.dips) in \(score.quietCalls) calls") }
    lines.append("- first turn ends after the last word: \(ms(score.turnLatencies)); held open by noise: \(score.heldOpen); turns made of noise: \(score.falseTurns)")
    return lines.joined(separator: "\n")
}

// MARK: Main

let options = Options(CommandLine.arguments)
let clips: Clips
do {
    clips = try Clips(directory: options.clips)
} catch {
    print("Can't read the clips in \(options.clips.path): run Tools/talk-bench/make-clips.sh first.")
    exit(1)
}
let scenarios = options.noises.flatMap { noise in options.phrases.map { Scenario(noise: noise, phrase: $0) } }
print("Talk noise bench: \(scenarios.count) calls, \(options.transcriber.rawValue) transcriber, \(options.parallel) at a time\n")
var results: [Result] = []
await withTaskGroup(of: Result?.self) { group in
    var pending = scenarios[...]
    func next() {
        guard let scenario = pending.popFirst() else { return }
        group.addTask { [clips, options] in
            do {
                return try await run(scenario, clips: clips, kind: options.transcriber)
            } catch {
                print("\(scenario.noise.title) / \(scenario.phrase.title): \(error.localizedDescription)")
                return nil
            }
        }
    }
    for _ in 0..<options.parallel { next() }
    for await result in group {
        if let result { results.append(result) }
        next()
    }
}
results.sort { ($0.scenario.noise.title, $0.scenario.phrase.rawValue) < ($1.scenario.noise.title, $1.scenario.phrase.rawValue) }
var old = Score()
var new = Score()
print("| Noise | Said over the Bot | Before | Now |")
print("|---|---|---|---|")
for result in results {
    let before = verdict(result.old, result, score: &old, yields: false)
    let now = verdict(result.new, result, score: &new, yields: true)
    print("| \(result.scenario.noise.title) | \(result.scenario.phrase.title) | \(before) | \(now) |")
    if options.verbose {
        for line in result.old.log + result.new.log { print("    \(line)") }
    }
}
print("\n" + summary("Before (voice activity)", old) + "\n\n" + summary("Now (TalkEars)", new))
