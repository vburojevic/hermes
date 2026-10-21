import Foundation

/// Words a transcriber has heard since the turn began, with when each run of them was said.
public struct HeardWords: Sendable, Equatable {
    public struct Run: Sendable, Equatable {
        public var text: String
        /// When it was said (system uptime).
        public var start: TimeInterval
        public var end: TimeInterval
        /// 0…1, when the transcriber gives one.
        public var confidence: Double?

        public init(text: String, start: TimeInterval, end: TimeInterval, confidence: Double? = nil) {
            self.text = text
            self.start = start
            self.end = end
            self.confidence = confidence
        }

        /// The on-device transcribers time and score each word once it's settled; the words still
        /// being heard come as one stretch from the last settled word, without a score.
        public var isTimed: Bool { confidence != nil }
    }

    public var final: String
    public var volatile: String
    /// Empty when the transcriber gives no times (the gateway's).
    public var runs: [Run]

    public init(final: String = "", volatile: String = "", runs: [Run] = []) {
        self.final = final
        self.volatile = volatile
        self.runs = runs
    }

    public var text: String { (final + volatile).trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// What Talk hears, and what it does about it (`docs/voice.md` §4.2): the person's voice from the
/// room's noise, their words from the Bot's own, and when a turn is over.
///
/// - Sound is only a hint. A voice near the microphone lowers the Bot at once (`duck`), so it
///   yields as you start; it stops (`bargeIn`) only when the transcriber has heard your words, or a
///   stop word. A fan, a street, music, a TV or a keyboard gets at most that dip, then the Bot
///   carries on (`restore`).
/// - Near is louder than the room's noise floor, than the room's loudest moments (`ceiling`: a TV,
///   music, people across the room) and close to how loud the person's own turns were.
/// - The Bot's own words (its echo) and backchannels ("mm-hm", "yeah") never stop it.
/// - Turns ask less (`turnThreshold`): a person in a loud room is still heard. Noise neither
///   holds a turn open (it ends once the words stop, whatever the sound does) nor makes one (words
///   that were never near are dropped).
///
/// The microphone's 20 ms frames are the clock: everything is decided as they arrive, so nothing
/// is polled and tests can replay any timeline.
public struct TalkEars: Sendable {
    public struct Tuning: Sendable, Equatable {
        /// The person's voice can be this much quieter than their turns were and still be them.
        public var belowPerson: Float = 12
        /// Before their level is known: this far above the room's floor is near.
        public var aboveFloor: Float = 12
        /// Above the room's loudest moments by this much is the person.
        public var aboveCeiling: Float = 4
        /// Never near when quieter than this (dBFS).
        public var quietest: Float = -50
        /// A turn's words count down to this far below the person's level, however loud the room.
        public var turnBelowPerson: Float = 6
        /// Near voice for this long lowers the Bot.
        public var duckAfter: TimeInterval = 0.1
        /// The start of each stretch of the Bot's speech, when the echo canceller is least settled,
        /// lowers nothing.
        public var grace: TimeInterval = 0.3
        /// After the voice stops, how long the words have to arrive before the Bot carries on: the
        /// on-device transcriber reports a word 0.35–0.6 s after it was said.
        public var confirmWindow: TimeInterval = 0.9
        /// A lowered Bot carries on after this long without words, whatever the sound does.
        public var longestDuck: TimeInterval = 2.5
        /// Words stop the Bot only with this much near voice in the last two seconds; a stop word
        /// needs less. Words without times (still being heard) need more, as they're judged by the
        /// voice heard just before them.
        public var voiceForWords: TimeInterval = 0.25
        public var voiceForUntimedWords: TimeInterval = 0.4
        public var voiceForStopWord: TimeInterval = 0.1
        /// Words the transcriber is less sure of than this don't count.
        public var leastConfidence: Double = 0.3
        /// Words that were never near are dropped after this long.
        public var dropDistantAfter: TimeInterval = 1.2
        /// Above the Bot's echo, as the room returns it, by this much is the person.
        public var aboveEcho: Float = 9
        /// A turn whose words stopped this long after the pause ends, even if the room still sounds
        /// like someone talking.
        public var wordsStoppedAfter: TimeInterval = 0.6

        public init() {}
    }

    public struct Decision: Sendable, Equatable, CustomStringConvertible {
        public enum Action: String, Sendable, Equatable {
            /// Lower the Bot while the words are checked.
            case duck
            /// It wasn't the person: the Bot carries on at full volume.
            case restore
            /// The person talked over the Bot: stop it.
            case bargeIn
            /// Words that weren't the person's (a TV, someone across the room): forget them.
            case discardHeard
            /// The person's turn is over: send it.
            case endTurn
        }

        /// `nil`: something heard and ignored, logged with why.
        public var action: Action?
        /// Why, in a few words ("stop word", "echo", "distant", "no words").
        public var reason: String
        public var at: TimeInterval
        /// What it was decided on, for the log (`talk`): levels in dBFS, durations in seconds,
        /// counts of words, never the words.
        public var level: Float?
        public var near: Float
        public var floor: Float
        public var person: Float?
        public var voice: TimeInterval
        public var words = 0
        public var own = 0

        public var description: String {
            var parts = ["\(action?.rawValue ?? "ignored"): \(reason)"]
            if let level { parts.append("level \(Self.db(level))") }
            parts.append("near \(Self.db(near))")
            parts.append("floor \(Self.db(floor))")
            if let person { parts.append("person \(Self.db(person))") }
            parts.append("voice \(Int(voice * 1000)) ms")
            if words > 0 { parts.append("words \(own)/\(words)") }
            return parts.joined(separator: ", ")
        }

        private static func db(_ value: Float) -> String { "\(Int(value.rounded())) dB" }
    }

    private struct Frame {
        var at: TimeInterval
        var level: Float
        /// Loud enough to be the person over the Bot (`nearThreshold`).
        var near: Bool
        /// Loud enough to be the person's turn (`turnThreshold`).
        var turn: Bool
    }

    public var tuning: Tuning
    public var endpointer: Endpointer

    /// How loud the person's turns are (dBFS), once one has been heard.
    public private(set) var personLevel: Float?
    /// The person is talking near the microphone (the rings).
    public private(set) var isHearingPerson = false
    public private(set) var isDucked = false
    public var isBotSpeaking: Bool { botSince != nil }

    private var vad = VoiceActivityDetector()
    private var frames: [Frame] = []
    /// The last ten seconds that weren't the person, for the ceiling.
    private var background: [(at: TimeInterval, level: Float)] = []
    private var backgroundCount = 0
    private var recentLevels: [Float] = []
    private var botSince: TimeInterval?
    private var botWords: Set<String> = []
    /// The room's return of the Bot's voice: input minus output, in dB.
    private var echoGain: Float = -30
    private var nearSince: TimeInterval?
    private var nearLast: TimeInterval?
    private var duckedAt: TimeInterval?
    /// The stretch of sound a dip was taken back for: it doesn't lower the Bot again.
    private var restoredRun: TimeInterval?
    /// Dips that weren't the person, for getting used to a noisy room.
    private var falseDucks: [TimeInterval] = []
    private var heard = HeardWords()
    /// How many words had been heard when the person's voice began: words still being heard
    /// (untimed) before that aren't theirs.
    private var voiceStartWords = 0
    /// Words heard over the Bot that didn't stop it, counted for the log.
    private var lastIgnored: (words: Int, own: Int)?
    private var firedBargeIn = false
    // The turn being heard (the Bot quiet).
    private var turnHasWords = false
    private var turnStart: TimeInterval?
    private var wordsChangedAt: TimeInterval?
    private var distantSince: TimeInterval?
    private var ending = false

    public init(pause: Endpointer.Pause = .normal, tuning: Tuning = Tuning()) {
        self.tuning = tuning
        endpointer = Endpointer(pause: pause)
    }

    // MARK: Levels

    /// The room's noise floor (dBFS).
    public var floor: Float { Self.decibels(vad.floor) }

    /// The room's loudest moments (dBFS): the 90th percentile of the last ten seconds that
    /// weren't the person, each the middle of 100 ms (a key click is brief, a TV's syllable isn't).
    public private(set) var ceiling: Float = -120

    /// The quietest a sound can be and still be the person talking over the Bot.
    public var nearThreshold: Float {
        let floorGate = floor + (personLevel == nil ? tuning.aboveFloor : 8)
        let personGate = personLevel.map { $0 - tuning.belowPerson } ?? -.infinity
        return max(tuning.quietest, floorGate, personGate, ceiling + tuning.aboveCeiling)
    }

    /// The quietest a turn's voice can be: as for barge-in, but a room too loud to tell the
    /// person from never shuts them out of their own turn.
    public var turnThreshold: Float {
        let loudest = (personLevel ?? -30) - tuning.turnBelowPerson
        return min(nearThreshold, max(tuning.quietest, floor + 6, loudest))
    }

    /// What the transcriber's `NearGate` lets through: while the Bot speaks, only sound near
    /// enough to be the person (its lookahead keeps a word's softer start); otherwise everything.
    public var gateThreshold: Float? {
        isBotSpeaking ? nearThreshold : nil
    }

    /// Lowering the Bot asks more of a room that keeps sounding like a voice.
    private var duckThreshold: Float {
        nearThreshold + Float(min(falseDucks.count, 2)) * 6
    }

    static func decibels(_ rms: Float) -> Float { 20 * log10(max(rms, 0.000_001)) }

    // MARK: The Bot

    /// The Bot started (or carried on) speaking. `saying` is what it's reading now and around it.
    /// Words heard since the last turn that weren't one (a TV while Hermes worked) go, so nothing
    /// said before the Bot spoke is taken for talking over it.
    @discardableResult
    public mutating func botStarted(at time: TimeInterval, saying text: String) -> [Decision] {
        botSince = time
        firedBargeIn = false
        botSaying(text)
        voiceStartWords = 0
        guard !heard.text.isEmpty, !turnHasWords else { return [] }
        resetHeard()
        distantSince = nil
        return [decision(.discardHeard, "heard before the Bot spoke", at: time)]
    }

    /// What the Bot is reading changed (the next sentence).
    public mutating func botSaying(_ text: String) {
        botWords = Set(Self.words(text))
    }

    /// The Bot went quiet. Words heard over it that didn't stop it aren't the next turn, unless
    /// the person is still talking.
    public mutating func botStopped(at time: TimeInterval) -> [Decision] {
        guard botSince != nil else { return [] }
        botSince = nil
        var decisions: [Decision] = []
        if isDucked { decisions.append(restore("the Bot stopped", at: time)) }
        if !heard.text.isEmpty, !firedBargeIn, nearLast.map({ time - $0 > 0.2 }) ?? true {
            decisions.append(decision(.discardHeard, "heard over the Bot", at: time))
            resetHeard()
        } else if !heard.text.isEmpty {
            // They talked over it (or are still talking as it ends): what they say is their turn.
            turnHasWords = true
            turnStart = nearSince ?? heard.runs.first?.start ?? time
            wordsChangedAt = time
            if isHearingPerson { endpointer.speechStarted(at: nearSince ?? time) }
            endpointer.heard(heard.text, at: heard.runs.last.map(\.end) ?? time)
        }
        firedBargeIn = false
        return decisions
    }

    // MARK: Input

    /// One frame of the microphone (about 20 ms): its level in dBFS, and the Bot's output level
    /// in dBFS while it speaks.
    public mutating func frame(level: Float, at time: TimeInterval, botLevel: Float? = nil) -> [Decision] {
        _ = vad.process(rms: pow(10, level / 20), at: time)
        let voiced = level >= Self.decibels(vad.threshold)
        // Not the Bot's own voice as the room gives it back.
        var echo = false
        if isBotSpeaking, let botLevel, botLevel > -60 {
            echo = level < botLevel + echoGain + tuning.aboveEcho
            if botLevel > -40, nearSince == nil {
                let warming = time - (botSince ?? time) < 0.5
                echoGain += (level - botLevel - echoGain) * (warming ? 0.1 : 0.03)
                echoGain = min(6, max(-60, echoGain))
            }
        }
        let near = voiced && !echo && level >= nearThreshold
        let turn = voiced && !echo && level >= turnThreshold
        frames.append(Frame(at: time, level: level, near: near, turn: turn))
        if frames.count > 600 { frames.removeFirst(frames.count - 600) }
        listenToTheRoom(level, at: time)

        var decisions: [Decision] = []
        trackVoice(isBotSpeaking ? near : turn, at: time)
        if isBotSpeaking {
            decideDuck(at: time, decisions: &decisions)
        } else {
            decideTurn(at: time, decisions: &decisions)
        }
        falseDucks.removeAll { time - $0 > 30 }
        return decisions
    }

    /// The transcriber's words since the turn began.
    public mutating func heard(_ words: HeardWords, at time: TimeInterval) -> [Decision] {
        let previous = heard
        heard = words
        guard words.text != previous.text else { return [] }
        if words.text.isEmpty { return [] }
        if isBotSpeaking { return decideBargeIn(at: time) }
        // The words of a turn: they count only when they were near.
        if wordsAreNear(words, since: previous, at: time) {
            if !turnHasWords { forgetRoom(since: turnStart ?? nearSince ?? time - 1) }
            turnHasWords = true
            distantSince = nil
            wordsChangedAt = time
            if turnStart == nil { turnStart = words.runs.first(where: \.isTimed)?.start ?? nearSince ?? time }
            endpointer.heard(words.text, at: min(time, spoken(words, at: time)))
        } else if !turnHasWords, distantSince == nil {
            distantSince = time
        }
        return []
    }

    /// The engine sent (or dropped) the turn: start the next one, knowing how loud this one was.
    public mutating func turnEnded(at time: TimeInterval, sent: Bool) {
        if sent, let start = turnStart {
            let levels = frames.filter { $0.turn && $0.at >= start - 0.1 && $0.at <= time }.map(\.level).sorted()
            if !levels.isEmpty {
                let median = levels[levels.count / 2]
                // Up quickly (the person came closer), down slowly (one quiet turn).
                personLevel = personLevel.map { median > $0 ? $0 * 0.3 + median * 0.7 : $0 * 0.85 + median * 0.15 } ?? median
            }
        }
        endpointer.reset()
        resetHeard()
        turnHasWords = false
        turnStart = nil
        wordsChangedAt = nil
        distantSince = nil
        ending = false
    }

    /// Muted: nothing heard counts, and a lowered Bot comes back.
    public mutating func muted(at time: TimeInterval) -> [Decision] {
        nearSince = nil
        nearLast = nil
        isHearingPerson = false
        endpointer.speechEnded(at: time)
        return isDucked ? [restore("muted", at: time)] : []
    }

    // MARK: The room

    /// The ceiling learns from what isn't the person: not their turn, not a stretch that lowered
    /// the Bot or stopped it.
    private mutating func listenToTheRoom(_ level: Float, at time: TimeInterval) {
        recentLevels.append(level)
        if recentLevels.count > 5 { recentLevels.removeFirst() }
        guard !turnHasWords, !isDucked, !firedBargeIn else { return }
        // The middle of the last 100 ms: a click is one frame, a syllable is several.
        let smoothed = recentLevels.sorted()[recentLevels.count / 2]
        background.append((time, smoothed))
        if background.count > 500 { background.removeFirst(background.count - 500) }
        backgroundCount += 1
        // Five times a second is often enough for a room.
        if backgroundCount % 10 == 0 || background.count < 10 { measureCeiling() }
    }

    private mutating func measureCeiling() {
        let sorted = background.map(\.level).sorted()
        ceiling = sorted.isEmpty ? -120 : sorted[min(sorted.count - 1, sorted.count * 9 / 10)]
    }

    /// It was the person after all (their words came, or they lowered the Bot): what they said
    /// before that isn't the room either.
    private mutating func forgetRoom(since time: TimeInterval) {
        background.removeAll { $0.at >= time - 0.1 }
        measureCeiling()
    }

    // MARK: Decisions

    private mutating func trackVoice(_ near: Bool, at time: TimeInterval) {
        if near {
            if nearSince == nil {
                nearSince = time
                // Once the Bot is lowered for a voice, that voice's words are counted from then.
                if !isDucked { voiceStartWords = Self.words(heard.text).count }
            }
            nearLast = time
            // A voice is steady: three of the last five frames. Key clicks never are.
            let steady = frames.suffix(5).filter { isBotSpeaking ? $0.near : $0.turn }.count >= 3
            if !isHearingPerson, steady, time - (nearSince ?? time) >= 0.06 {
                isHearingPerson = true
                if !isBotSpeaking {
                    endpointer.speechStarted(at: nearSince ?? time)
                    if turnStart == nil { turnStart = nearSince }
                }
            }
        } else if let last = nearLast, time - last >= 0.18 {
            // The same hangover as voice activity: a breath between words isn't the end.
            if isHearingPerson, !isBotSpeaking { endpointer.speechEnded(at: last) }
            isHearingPerson = false
            nearSince = nil
        }
    }

    private mutating func decideDuck(at time: TimeInterval, decisions: inout [Decision]) {
        guard let botSince, !firedBargeIn else { return }
        if let duckedAt {
            let quietFor = nearLast.map { time - $0 } ?? .infinity
            if !isHearingPerson, quietFor >= tuning.confirmWindow {
                falseDucks.append(time)
                decisions.append(restore("no words", at: time))
            } else if time - duckedAt >= tuning.longestDuck {
                falseDucks.append(time)
                decisions.append(restore("sound but no words", at: time))
            }
            return
        }
        guard isHearingPerson, let since = nearSince, since != restoredRun,
              time - max(since, botSince + tuning.grace) >= tuning.duckAfter else { return }
        // A voice is steady; key clicks and knocks come and go between frames.
        let recent = frames.suffix(6)
        guard recent.filter(\.near).count >= 5 else { return }
        let run = frames.filter { $0.at >= since && $0.near }.map(\.level)
        let level = run.isEmpty ? nil : run.reduce(0, +) / Float(run.count)
        guard let level, level >= duckThreshold else { return }
        duckedAt = time
        isDucked = true
        forgetRoom(since: since)
        decisions.append(decision(.duck, "near voice", at: time, level: level))
    }

    private mutating func decideBargeIn(at time: TimeInterval) -> [Decision] {
        guard !firedBargeIn else { return [] }
        let tokens = ownTokens(at: time)
        let own = tokens.filter(\.own).map(\.word)
        let all = tokens.count
        let voice = nearVoice(within: 2, at: time)
        let level = tokens.compactMap(\.level).max()
        let stopping = tokens.filter(\.stops).map(\.word)
        if Self.isStopPhrase(stopping.joined(separator: " ")), voice >= tuning.voiceForStopWord {
            return [bargeIn("stop word", at: time, level: level, words: all, own: own.count)]
        }
        let content = own.filter { !Self.backchannels.contains($0) && !Self.isFiller($0) }
        let untimed = tokens.contains { $0.own && !$0.timed }
        if content.count >= 2, voice >= (untimed ? tuning.voiceForUntimedWords : tuning.voiceForWords) {
            return [bargeIn("words", at: time, level: level, words: all, own: own.count)]
        }
        guard lastIgnored?.words != all || lastIgnored?.own != own.count else { return [] }
        lastIgnored = (all, own.count)
        let echoes = tokens.filter(\.echo).count
        let why = own.isEmpty ? (echoes * 2 > all ? "echo" : "distant") : content.isEmpty ? "backchannel" : "too few words"
        var ignored = decision(nil, why, at: time, level: level)
        ignored.words = all
        ignored.own = own.count
        return [ignored]
    }

    private mutating func decideTurn(at time: TimeInterval, decisions: inout [Decision]) {
        if let distantSince, !turnHasWords, time - distantSince >= tuning.dropDistantAfter {
            decisions.append(decision(.discardHeard, "distant words", at: time))
            resetHeard()
            self.distantSince = nil
            return
        }
        guard !ending, turnHasWords else { return }
        if endpointer.isComplete(at: time) {
            ending = true
            decisions.append(decision(.endTurn, "pause", at: time))
        } else if let wordsChangedAt, isHearingPerson, time - wordsChangedAt >= endpointer.pause.seconds + tuning.wordsStoppedAfter {
            // The room still sounds like someone talking, but the words stopped: music, a TV.
            ending = true
            decisions.append(decision(.endTurn, "words stopped", at: time))
        }
    }

    // MARK: Words

    private struct Token {
        var word: String
        var level: Float?
        var echo: Bool
        /// The person's, for counting words.
        var own: Bool
        /// The person's, for a stop phrase.
        var stops: Bool
        var timed: Bool
    }

    /// The words heard over the Bot, each with how loud it was and whether it's the person's.
    private func ownTokens(at time: TimeInterval) -> [Token] {
        let gate = nearThreshold
        let recent = recentNearLevel(at: time)
        var tokens: [Token] = []
        // The gateway's words come with no runs at all: one untimed stretch.
        let runs = heard.runs.isEmpty ? [HeardWords.Run(text: heard.text, start: time, end: time)] : heard.runs
        for run in runs {
            let level = run.isTimed ? self.level(from: run.start, to: run.end) ?? recent : recent
            let sure = (run.confidence ?? 1) >= tuning.leastConfidence
            for word in Self.words(run.text) {
                let loud = level ?? -.infinity
                let echo = botWords.contains(word)
                // Words still being heard from before the person's voice began are someone else's.
                let before = !run.isTimed && tokens.count < voiceStartWords
                let heardNear = !before && sure && loud >= gate
                // A word the Bot is saying is its echo for counting words, but not in a stop phrase
                // ("hold on" while the Bot says "on Sunday"): the gate keeps its echo out, and a
                // stop phrase still needs the person's voice.
                tokens.append(Token(word: word, level: level, echo: echo, own: heardNear && !echo, stops: heardNear, timed: run.isTimed))
            }
        }
        return tokens
    }

    private func wordsAreNear(_ words: HeardWords, since previous: HeardWords, at time: TimeInterval) -> Bool {
        let gate = turnThreshold
        if words.runs.contains(where: { !$0.isTimed }) || words.runs.isEmpty {
            // Words still being heard (or the gateway's): near if the person's voice was heard
            // just before them.
            if frames.reversed().prefix(while: { time - $0.at <= 1.5 }).filter(\.turn).count >= 5 { return true }
        }
        let new = words.runs.filter { run in run.isTimed && !previous.runs.contains(run) }
        return new.contains { run in
            (run.confidence ?? 1) >= tuning.leastConfidence && (level(from: run.start, to: run.end) ?? -.infinity) >= gate
        }
    }

    /// When the newest words were said: a settled word's own time, else the end of the voice just
    /// before they arrived.
    private func spoken(_ words: HeardWords, at time: TimeInterval) -> TimeInterval {
        if let last = words.runs.last, last.isTimed { return last.end }
        if let nearLast, time - nearLast <= 1.5 { return nearLast }
        return time
    }

    /// The louder half of the frames between two times, or `nil` without frames there.
    private func level(from start: TimeInterval, to end: TimeInterval) -> Float? {
        let levels = frames.filter { $0.at >= start - 0.02 && $0.at <= end + 0.02 }.map(\.level).sorted(by: >)
        guard !levels.isEmpty else { return nil }
        let louder = levels.prefix(max(1, levels.count / 2))
        return louder.reduce(0, +) / Float(louder.count)
    }

    /// How loud the person was just now: their near voice, else the room's sound.
    private func recentNearLevel(at time: TimeInterval) -> Float? {
        let near = frames.filter { $0.near && time - $0.at <= 1.5 }.map(\.level)
        return near.isEmpty ? level(from: time - 1.5, to: time) : near.reduce(0, +) / Float(near.count)
    }

    /// Seconds of near voice in the last `seconds`.
    private func nearVoice(within seconds: TimeInterval, at time: TimeInterval) -> TimeInterval {
        Double(frames.reversed().prefix { time - $0.at <= seconds }.filter(\.near).count) * 0.02
    }

    private mutating func resetHeard() {
        heard = HeardWords()
        lastIgnored = nil
    }

    // MARK: Building decisions

    private mutating func restore(_ reason: String, at time: TimeInterval) -> Decision {
        restoredRun = nearSince
        duckedAt = nil
        isDucked = false
        return decision(.restore, reason, at: time)
    }

    private mutating func bargeIn(_ reason: String, at time: TimeInterval, level: Float?, words: Int, own: Int) -> Decision {
        firedBargeIn = true
        duckedAt = nil
        isDucked = false
        lastIgnored = nil
        var made = decision(.bargeIn, reason, at: time, level: level)
        made.words = words
        made.own = own
        return made
    }

    private func decision(_ action: Decision.Action?, _ reason: String, at time: TimeInterval, level: Float? = nil) -> Decision {
        Decision(action: action, reason: reason, at: time, level: level, near: nearThreshold, floor: floor, person: personLevel,
                 voice: nearVoice(within: 2, at: time))
    }

    // MARK: Phrases

    /// The words of `text`, lowercased, with runs of single letters joined ("M M H M" is "mmhm").
    static func words(_ text: String) -> [String] {
        var words: [String] = []
        var letters = ""
        for word in SpokenAnswers.normalized(text).split(separator: " ").map(String.init) {
            if word.count == 1, word != "i", word != "a", word.first?.isLetter == true {
                letters += word
                continue
            }
            if !letters.isEmpty { words.append(letters) }
            letters = ""
            words.append(word)
        }
        if !letters.isEmpty { words.append(letters) }
        return words
    }

    private static let stops: [[String]] = [
        ["stop"], ["wait"], ["hold", "on"], ["hang", "on"], ["pause"], ["enough"], ["shush"], ["quiet"], ["one", "sec"], ["one", "second"],
    ]

    /// "Stop.", "wait wait", "hold on a sec": a short phrase made of a stop word.
    public static func isStopPhrase(_ words: String) -> Bool {
        let said = Self.words(words)
        guard !said.isEmpty, said.count <= 4 else { return false }
        return stops.contains { stop in
            guard said.count >= stop.count else { return false }
            return (0...(said.count - stop.count)).contains { Array(said[$0..<$0 + stop.count]) == stop }
        }
    }

    static let stopWords: Set<String> = ["stop", "wait", "hold", "hang", "pause", "enough", "shush", "quiet"]

    /// "Mm", "mhm", "hmm", a stray "by": no vowel, so a hum or a fragment, not a word.
    static func isFiller(_ word: String) -> Bool {
        !word.contains { "aeiou".contains($0) || $0.isNumber }
    }

    /// Said to show you're listening, not to take a turn.
    static let backchannels: Set<String> = [
        "mm", "mmm", "mhm", "mmhm", "mmhmm", "hm", "hmm", "uh", "um", "uhhuh", "uhuh", "huh", "yeah", "yep", "yes", "ya", "ok",
        "okay", "right", "sure", "cool", "nice", "great", "wow", "oh", "ah", "aha", "i", "see", "got", "it", "alright", "true",
        "exactly", "totally", "really", "yup", "fine", "good", "mmh", "mh", "hmhm", "mhmm", "hmm", "mmmm",
    ]
}
