import Foundation

/// The rooms the bench calls from. Levels are dBFS at the microphone, against the person at
/// −24 dBFS: what a phone on a table hears with its owner talking to it.
enum Noise: String, CaseIterable {
    case quiet, fan, street, keyboard, music, loudMusic, tv, chatter

    var title: String {
        switch self {
        case .quiet: "quiet room"
        case .fan: "fan"
        case .street: "street"
        case .keyboard: "keyboard"
        case .music: "music"
        case .loudMusic: "loud music"
        case .tv: "TV"
        case .chatter: "distant chatter"
        }
    }

    func render(seconds: Double, clips: Clips) -> Signal {
        var random = SeededRandom(seed: UInt64(Self.allCases.firstIndex(of: self) ?? 0) + 7)
        let count = Int(seconds * Signal.rate)
        // Every room has some hiss.
        let room = Signal(samples: (0..<count).map { _ in random.noise() }).lowPassed(3000).scaled(to: -64)
        switch self {
        case .quiet:
            return room
        case .fan:
            // Broadband rumble with a motor hum.
            let rumble = Signal(samples: (0..<count).map { _ in random.noise() }).lowPassed(400).lowPassed(900)
            let hum = Signal(samples: (0..<count).map { Float(sin(2 * .pi * 120 * Double($0) / Signal.rate)) * 0.3 })
            var fan = rumble.scaled(to: -42)
            fan.mix(hum.scaled(to: -52), at: 0)
            fan.mix(room, at: 0)
            return fan
        case .street:
            var street = Signal(samples: (0..<count).map { _ in random.noise() }).lowPassed(700).scaled(to: -46)
            // Cars passing every few seconds: a swell of noise, and a horn once.
            for pass in stride(from: 1.5, to: seconds, by: 4.3) {
                let length = 3.0
                let car = Signal(samples: (0..<Int(length * Signal.rate)).map { index in
                    let t = Double(index) / Signal.rate / length
                    return random.noise() * Float(sin(.pi * t) * sin(.pi * t))
                }).lowPassed(1200).scaled(to: -33)
                street.mix(car, at: pass)
            }
            let horn = Signal(samples: (0..<Int(0.6 * Signal.rate)).map { index in
                let t = Double(index) / Signal.rate
                return Float(sin(2 * .pi * 410 * t) + 0.7 * sin(2 * .pi * 515 * t) + 0.3 * sin(2 * .pi * 820 * t))
            }).scaled(to: -30)
            street.mix(horn, at: min(seconds - 1, 9.2))
            street.mix(room, at: 0)
            return Signal(samples: Array(street.samples.prefix(count)))
        case .keyboard:
            // Typing on the laptop the call runs on: sharp clicks in bursts.
            var keys = room
            var time = 0.3
            while time < seconds - 0.1 {
                let burst = Int.random(in: 3...12, using: &random)
                for _ in 0..<burst {
                    let click = Signal(samples: (0..<Int(0.012 * Signal.rate)).map { index in
                        random.noise() * Float(exp(-Double(index) / (0.002 * Signal.rate)))
                    }).highPassed(1500).gained(-6 - Float.random(in: 0...6, using: &random))
                    keys.mix(click, at: time)
                    time += Double.random(in: 0.08...0.22, using: &random)
                }
                time += Double.random(in: 0.4...1.5, using: &random)
            }
            return Signal(samples: Array(keys.samples.prefix(count)))
        case .music, .loudMusic:
            var music = Self.band(seconds: seconds)
            music.mix(clips.song.looped(to: seconds).scaled(to: -3).lowPassed(5000), at: 0)
            music = music.scaled(to: self == .music ? -36 : -26)
            music.mix(room, at: 0)
            return Signal(samples: Array(music.samples.prefix(count)))
        case .tv:
            var tv = clips.tv.looped(to: seconds).highPassed(200).lowPassed(4000).reverberant(0.5).scaled(to: -40)
            tv.mix(Self.band(seconds: seconds).scaled(to: -54), at: 0)
            tv.mix(room, at: 0)
            return Signal(samples: Array(tv.samples.prefix(count)))
        case .chatter:
            var chatter = room
            for (index, voice) in clips.chatter.enumerated() {
                chatter.mix(voice.looped(to: seconds).reverberant(0.8).lowPassed(3500).scaled(to: -45), at: Double(index) * 0.7)
            }
            return Signal(samples: Array(chatter.samples.prefix(count)))
        }
    }

    /// Chords and a kick drum.
    private static func band(seconds: Double) -> Signal {
        let chords: [[Double]] = [[220, 277.2, 329.6], [196, 246.9, 293.7], [174.6, 220, 261.6], [196, 246.9, 311.1]]
        return Signal(samples: (0..<Int(seconds * Signal.rate)).map { index in
            let t = Double(index) / Signal.rate
            let chord = chords[Int(t / 2) % chords.count]
            var sample = chord.reduce(0.0) { sum, note in sum + sin(2 * .pi * note * t) + 0.4 * sin(4 * .pi * note * t) } / 4
            let beat = t.truncatingRemainder(dividingBy: 0.5)
            sample += sin(2 * .pi * 55 * beat) * exp(-beat * 18) * 1.5
            return Float(sample)
        })
    }
}

/// The spoken clips `make-clips.sh` made.
struct Clips {
    var turn: Signal
    var bot: Signal
    var tv: Signal
    var song: Signal
    var chatter: [Signal]
    var phrases: [String: Signal]

    static let botText = "The NAS is fine. Volume one is at sixty two percent, the snapshots ran at three this morning, and nothing failed overnight. The next scrub is on Sunday, and I'll tell you if anything changes before then."

    init(directory: URL) throws {
        func load(_ name: String) throws -> Signal { try Signal(contentsOf: directory.appendingPathComponent("\(name).wav")) }
        turn = try load("turn")
        bot = try load("bot")
        tv = try load("tv")
        song = try load("song")
        chatter = try ["chatter1", "chatter2", "chatter3"].map(load)
        phrases = [:]
        for phrase in Phrase.allCases where phrase != .none { phrases[phrase.rawValue] = try load(phrase.rawValue) }
    }
}

/// What the person says over the Bot.
enum Phrase: String, CaseIterable {
    case none, stop, wait, holdon, other, instead, mmhm, yeah

    var title: String {
        switch self {
        case .none: "nothing"
        case .stop: "“Stop.”"
        case .wait: "“Wait, wait.”"
        case .holdon: "“Hold on.”"
        case .other: "“No, the other one.”"
        case .instead: "“Actually, check the backups instead.”"
        case .mmhm: "“Mm-hm.”"
        case .yeah: "“Yeah.”"
        }
    }

    /// Should it stop the Bot?
    var interrupts: Bool { ![.none, .mmhm, .yeah].contains(self) }
}
