import Foundation
import Testing
@testable import HermesKit

/// Barge-in and the end of a turn with noise (`docs/voice.md` §4.2): replayed timelines of 20 ms
/// frames, with words arriving as the on-device transcriber gives them (about 0.35 s after
/// they were said).
@Suite("Talk's ears: noise never interrupts the Bot, the person always does")
struct TalkEarsTests {
    /// A call replayed frame by frame. `level(t)` is the microphone in dBFS, `bot(t)` the Bot's
    /// output while it speaks; `words` arrive at their times.
    struct Replay {
        var ears = TalkEars()
        var decisions: [TalkEars.Decision] = []
        var time: TimeInterval = 0

        init(personLevel: Float? = -24) {
            if let personLevel { learn(personLevel) }
        }

        /// Gives the ears a turn at `level`, so they know how loud the person is.
        mutating func learn(_ level: Float) {
            run(until: 1, level: { _ in -60 })
            let start = time
            run(until: start + 0.8, level: { _ in level })
            _ = ears.heard(HeardWords(final: "check the NAS", runs: [.init(text: "check the NAS", start: start, end: start + 0.8)]), at: time)
            run(until: start + 2.2, level: { _ in -60 })
            ears.turnEnded(at: time, sent: true)
            decisions = []
        }

        mutating func run(until end: TimeInterval, level: (TimeInterval) -> Float, bot: ((TimeInterval) -> Float?)? = nil,
                          words: [(at: TimeInterval, HeardWords)] = []) {
            var pending = words.sorted { $0.at < $1.at }
            while time < end {
                decisions += ears.frame(level: level(time), at: time, botLevel: bot?(time))
                while let next = pending.first, next.at <= time {
                    decisions += ears.heard(next.1, at: time)
                    pending.removeFirst()
                }
                time += 0.02
            }
        }

        mutating func botSpeaks(_ text: String = "The backups finished at three and nothing failed.") {
            ears.botStarted(at: time, saying: text)
        }

        func first(_ action: TalkEars.Decision.Action) -> TalkEars.Decision? {
            decisions.first { $0.action == action }
        }

        func count(_ action: TalkEars.Decision.Action) -> Int {
            decisions.filter { $0.action == action }.count
        }
    }

    /// Speech-like: syllables of about 180 ms with short dips between them.
    static func syllables(_ level: Float, from start: TimeInterval, to end: TimeInterval, quiet: Float) -> (TimeInterval) -> Float {
        { time in
            guard time >= start, time < end else { return quiet }
            return (time - start).truncatingRemainder(dividingBy: 0.22) < 0.18 ? level : quiet
        }
    }

    static func run(_ text: String, _ start: TimeInterval, _ end: TimeInterval, confidence: Double? = 0.9) -> HeardWords.Run {
        .init(text: text, start: start, end: end, confidence: confidence)
    }

    @Test func aFanNeverLowersOrStopsTheBot() {
        var replay = Replay()
        replay.botSpeaks()
        let start = replay.time
        // A fan comes on: steady broadband noise, 20 dB over the quiet room.
        replay.run(until: start + 10, level: { _ in -40 + Float.random(in: -1...1) }, bot: { _ in -20 })
        #expect(replay.count(.bargeIn) == 0)
        #expect(replay.count(.duck) <= 1)
    }

    @Test func soundWithoutWordsDipsTheBotAndItCarriesOn() throws {
        var replay = Replay()
        replay.botSpeaks()
        let start = replay.time + 1
        // A door, a cough, a loud song near the phone: as loud as the person, but no words.
        replay.run(until: start + 4, level: Self.syllables(-22, from: start, to: start + 1.2, quiet: -60), bot: { _ in -20 })
        #expect(replay.count(.bargeIn) == 0)
        let duck = try #require(replay.first(.duck))
        let restore = try #require(replay.first(.restore))
        #expect(duck.at - start < 0.2)
        #expect(restore.at > duck.at)
        #expect(restore.reason == "no words")
        #expect(!replay.ears.isDucked)
    }

    @Test func stopIsHeardAtOnceAndStopsTheBotWhenTheWordArrives() throws {
        var replay = Replay()
        replay.botSpeaks()
        let start = replay.time + 1.5
        let end = start + 0.44
        replay.run(until: start + 2, level: { $0 >= start && $0 < end ? -23 : -58 }, bot: { _ in -20 },
                   words: [(end + 0.34, HeardWords(volatile: "Stop", runs: [Self.run("Stop", start + 0.08, end)]))])
        let duck = try #require(replay.first(.duck))
        let stop = try #require(replay.first(.bargeIn))
        #expect(duck.at - start <= 0.16)
        #expect(stop.reason == "stop word")
        #expect(stop.at - end < 0.4)
    }

    @Test func aTVAcrossTheRoomIsNeverThePerson() {
        var replay = Replay()
        replay.botSpeaks()
        let start = replay.time + 1
        // Speech, with words, 20 dB quieter than the person's own turns.
        let tv = Self.syllables(-44, from: start, to: start + 6, quiet: -56)
        var words: [(TimeInterval, HeardWords)] = []
        var text = ""
        for (index, word) in ["and", "tonight", "in", "the", "news", "storms", "move", "east"].enumerated() {
            let said = start + Double(index) * 0.6
            text += (text.isEmpty ? "" : " ") + word
            words.append((said + 0.9, HeardWords(volatile: text, runs: [Self.run(text, start, said + 0.5)])))
        }
        replay.run(until: start + 7, level: tv, bot: { _ in -20 }, words: words)
        #expect(replay.count(.bargeIn) == 0)
        #expect(replay.count(.duck) == 0)
        #expect(replay.decisions.contains { $0.action == nil && $0.reason == "distant" })
    }

    @Test func theBotsOwnWordsAreEchoNotAnInterruption() {
        var replay = Replay()
        replay.botSpeaks("The backups finished at three and nothing failed.")
        let start = replay.time + 1
        // The echo canceller let some of the Bot through, loud enough to be near.
        replay.run(until: start + 3, level: Self.syllables(-30, from: start, to: start + 1.5, quiet: -58), bot: { _ in -10 },
                   words: [(start + 1.9, HeardWords(volatile: "backups finished at three", runs: [Self.run("backups finished at three", start, start + 1.5)]))])
        #expect(replay.count(.bargeIn) == 0)
    }

    @Test func mmHmAndYeahDontStopTheBot() {
        var replay = Replay()
        replay.botSpeaks()
        let start = replay.time + 1
        replay.run(until: start + 2.5, level: Self.syllables(-24, from: start, to: start + 0.6, quiet: -58), bot: { _ in -20 },
                   words: [(start + 1.0, HeardWords(volatile: "Mm-hm, yeah", runs: [Self.run("Mm-hm, yeah", start, start + 0.6)]))])
        #expect(replay.count(.bargeIn) == 0)
        #expect(replay.decisions.contains { $0.action == nil && $0.reason == "backchannel" })
    }

    @Test func talkingOverTheBotStopsIt() throws {
        var replay = Replay()
        replay.botSpeaks()
        let start = replay.time + 1
        replay.run(until: start + 2.5, level: Self.syllables(-25, from: start, to: start + 1.4, quiet: -58), bot: { _ in -20 },
                   words: [(start + 0.9, HeardWords(volatile: "No, the other", runs: [Self.run("No, the other", start, start + 0.6)])),
                           (start + 1.6, HeardWords(volatile: "No, the other one", runs: [Self.run("No, the other one", start, start + 1.3)]))])
        let stop = try #require(replay.first(.bargeIn))
        #expect(stop.reason == "words")
        #expect(stop.at - start < 1.0)
    }

    @Test func wordsTheTranscriberIsUnsureOfDontCount() {
        var replay = Replay()
        replay.botSpeaks()
        let start = replay.time + 1
        replay.run(until: start + 2.5, level: Self.syllables(-24, from: start, to: start + 1, quiet: -58), bot: { _ in -20 },
                   words: [(start + 1.3, HeardWords(volatile: "car park", runs: [Self.run("car park", start, start + 1, confidence: 0.1)]))])
        #expect(replay.count(.bargeIn) == 0)
    }

    @Test func theStartOfTheBotsSpeechLowersNothing() {
        var replay = Replay()
        replay.botSpeaks()
        let start = replay.time
        replay.run(until: start + 0.35, level: { _ in -24 }, bot: { _ in -20 })
        #expect(replay.count(.duck) == 0)
    }

    @Test func aRoomThatKeepsSoundingLikeAVoiceDipsLessOften() {
        var replay = Replay()
        replay.botSpeaks()
        var start = replay.time + 1
        for _ in 0..<4 {
            replay.run(until: start + 2.2, level: Self.syllables(-30, from: start, to: start + 0.6, quiet: -60), bot: { _ in -20 })
            start = replay.time + 0.5
        }
        // Two dips, then the room has to be louder than it was to lower the Bot again.
        #expect(replay.count(.duck) == 2)
        #expect(replay.count(.bargeIn) == 0)
    }

    @Test func theEchoOfALoudBotIsNotNear() {
        var replay = Replay()
        replay.botSpeaks()
        let start = replay.time
        // The room returns the Bot 12 dB down: loud, but it follows the Bot's own level.
        replay.run(until: start + 6, level: { -22 - Float(sin($0 * 9) * 6) }, bot: { -10 - Float(sin($0 * 9) * 6) })
        #expect(replay.count(.duck) <= 1)
        #expect(replay.count(.bargeIn) == 0)
    }

    // MARK: Turns

    @Test func aTurnEndsAfterThePauseFromWhenTheWordsWereSaid() throws {
        var replay = Replay()
        let start = replay.time + 0.5
        let end = start + 1.2
        replay.run(until: end + 2, level: Self.syllables(-25, from: start, to: end, quiet: -60),
                   words: [(end + 0.4, HeardWords(volatile: "check the NAS", runs: [Self.run("check the NAS", start, end)]))])
        let turn = try #require(replay.first(.endTurn))
        // Normal: 0.9 s after the last word, not after it arrived.
        #expect(abs(turn.at - (end + 0.9)) < 0.1)
    }

    @Test func aTVWhileListeningIsNeverATurn() {
        var replay = Replay()
        let start = replay.time + 0.5
        replay.run(until: start + 4, level: Self.syllables(-46, from: start, to: start + 2, quiet: -56),
                   words: [(start + 1.4, HeardWords(volatile: "storms move east", runs: [Self.run("storms move east", start, start + 1)]))])
        #expect(replay.count(.endTurn) == 0)
        #expect(replay.count(.discardHeard) == 1)
    }

    @Test func noiseDoesntHoldATurnOpen() throws {
        var replay = Replay()
        let start = replay.time + 0.5
        let end = start + 1
        // Their words, then a TV carries on talking quietly behind them.
        let level: (TimeInterval) -> Float = { time in
            time < end ? (time >= start ? -25 : -60) : Self.syllables(-46, from: end, to: end + 5, quiet: -56)(time)
        }
        replay.run(until: end + 3, level: level,
                   words: [(end + 0.4, HeardWords(volatile: "check the NAS", runs: [Self.run("check the NAS", start, end)])),
                           (end + 1.2, HeardWords(volatile: "check the NAS and tonight", runs: [Self.run("check the NAS", start, end), Self.run("and tonight", end + 0.3, end + 0.9)]))])
        let turn = try #require(replay.first(.endTurn))
        #expect(turn.at - end < 1.1)
    }

    @Test func theFirstTurnTeachesHowLoudThePersonIs() {
        var replay = Replay(personLevel: nil)
        #expect(replay.ears.personLevel == nil)
        replay.learn(-22)
        #expect(replay.ears.personLevel == -22)
        #expect(replay.ears.nearThreshold == -34)
        // A quieter turn moves it down a little; a louder one most of the way.
        replay.learn(-32)
        #expect(abs((replay.ears.personLevel ?? 0) - -23.5) < 0.01)
        replay.learn(-16)
        #expect((replay.ears.personLevel ?? 0) > -19)
    }

    @Test func wordsHeardOverTheBotAreDroppedWhenItStops() {
        var replay = Replay()
        replay.botSpeaks()
        let start = replay.time + 0.5
        replay.run(until: start + 2, level: Self.syllables(-25, from: start, to: start + 0.4, quiet: -58), bot: { _ in -20 },
                   words: [(start + 0.8, HeardWords(volatile: "yeah", runs: [Self.run("yeah", start, start + 0.4)]))])
        let decisions = replay.ears.botStopped(at: replay.time)
        #expect(decisions.contains { $0.action == .discardHeard })
    }

    @Test func stopPhrases() {
        #expect(TalkEars.isStopPhrase("stop"))
        #expect(TalkEars.isStopPhrase("Wait!"))
        #expect(TalkEars.isStopPhrase("wait wait"))
        #expect(TalkEars.isStopPhrase("hang on a sec"))
        #expect(TalkEars.isStopPhrase("one second"))
        #expect(!TalkEars.isStopPhrase("hold the door"))
        #expect(!TalkEars.isStopPhrase("please stop the backup job tonight"))
        #expect(!TalkEars.isStopPhrase("I can wait until tomorrow for the report"))
    }

    @Test func decisionsLogTheirInputsButNeverTheWords() {
        let decision = TalkEars.Decision(action: .bargeIn, reason: "stop word", at: 3, level: -23.4, near: -36, floor: -58.2, person: -24,
                                         voice: 0.42, words: 3, own: 1)
        #expect(decision.description == "bargeIn: stop word, level -23 dB, near -36 dB, floor -58 dB, person -24 dB, voice 420 ms, words 1/3")
    }
}
