import Foundation
import HermesKit
import Observation
import os
#if os(iOS)
import UIKit
#endif

/// What voice has on a gateway and its Bots (`docs/voice.md` §6.1), as setup statuses for
/// Settings → Voice & Audio, Edit Bot → Voice and the Setup hub (`docs/setup.md`). One per gateway.
///
/// It reads `GET /api/config?profile=`, `GET /api/env?profile=` (key names only),
/// `GET /api/audio/voice-live/status`, `GET /api/audio/voice-config` (its verdicts, never its keys)
/// and `GET /api/providers/oauth` (which sign-ins it has), and remembers when Talk or Listen had to fall back to the
/// device's voice. It never changes the gateway by itself: keys and voices change only when the
/// person saves them in the app.
@MainActor
@Observable
final class VoiceSetup {
    /// The gateway's own profile.
    private(set) var setupStatuses: [SetupStatus] = VoiceSetup.checking(profile: nil)
    private(set) var facts: VoiceFacts?
    /// Bots' statuses and facts, by profile, once checked.
    private(set) var botStatuses: [String: [SetupStatus]] = [:]
    private(set) var botFacts: [String: VoiceFacts] = [:]
    /// A fix that didn't take: Hermes's words, for an alert.
    var fixError: String?
    @ObservationIgnored private var checkedAt: Date?
    @ObservationIgnored private weak var workspace: BotWorkspace?
    /// When the gateway's voice last failed, by profile ("" for the gateway's own).
    @ObservationIgnored private var failures: [String: String] = [:]
    /// When the gateway last couldn't transcribe a call, by profile.
    @ObservationIgnored private var transcriptionFailures: [String: String] = [:]

    private static var all: [UUID: VoiceSetup] = [:]
    static let logger = Logger(subsystem: "co.caffeinatedcode.hermes", category: "audio")

    /// The gateway's voice setup.
    static func of(_ workspace: BotWorkspace) -> VoiceSetup {
        if let known = all[workspace.id] { return known }
        let setup = VoiceSetup(workspace: workspace)
        all[workspace.id] = setup
        return setup
    }

    private init(workspace: BotWorkspace) {
        self.workspace = workspace
    }

    /// "iPhone", "iPad" or "Mac", for "this iPhone's voice".
    static var device: String {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #else
        "Mac"
        #endif
    }

    func statuses(for profile: String?) -> [SetupStatus] {
        guard let profile, profile != gatewayProfile else { return setupStatuses }
        return botStatuses[profile] ?? Self.checking(profile: profile)
    }

    /// One status, for a feature's note ("talk", "listen", "messages").
    func status(_ feature: String, profile: String?) -> SetupStatus? {
        let id = VoiceSetupRules.id(feature, profile: profile == gatewayProfile ? nil : profile)
        return statuses(for: profile).first { $0.id == id }
    }

    /// Whether the gateway speaks in its own voice for `profile`, if known.
    func gatewaySpeaks(profile: String?) -> Bool? {
        guard let profile, profile != gatewayProfile else { return facts?.gatewaySpeaks }
        return botFacts[profile]?.gatewaySpeaks
    }

    /// Checks when nothing was checked in the last ten minutes (a chat or call opening).
    func checkIfStale(profile: String?) async {
        let bot = profile == gatewayProfile ? nil : profile
        if let checkedAt, Date.now.timeIntervalSince(checkedAt) < 600, bot == nil || botStatuses[bot!] != nil { return }
        checkedAt = .now
        await check(profile: nil)
        if let bot { await check(profile: bot) }
    }

    /// Asks the gateway again: its own profile, and the Bots already shown.
    func checkSetup() async {
        checkedAt = .now
        await check(profile: nil)
        for profile in botStatuses.keys { await check(profile: profile) }
    }

    func check(profile: String?) async {
        let bot = profile == gatewayProfile ? nil : profile
        let result = await read(profile: bot)
        if let bot {
            botStatuses[bot] = result
        } else {
            setupStatuses = result
        }
    }

    /// Talk or Listen fell back to the device's voice: the setup says why until it works again.
    func noteSpeechFailure(_ message: String, profile: String?) {
        let key = profile ?? ""
        guard failures[key] != message else { return }
        failures[key] = message
        Task { await check(profile: profile) }
    }

    /// Talk had to transcribe on the device: the setup says why until it works again.
    func noteTranscriptionFailure(_ message: String, profile: String?) {
        let key = profile ?? ""
        guard transcriptionFailures[key] != message else { return }
        transcriptionFailures[key] = message
        Task { await check(profile: profile) }
    }

    /// Whether Talk's words can come from the gateway for `profile`, if known.
    func gatewayTranscribes(profile: String?) -> Bool? {
        guard let profile, profile != gatewayProfile else { return facts?.gatewayTranscribes }
        return botFacts[profile]?.gatewayTranscribes
    }

    /// Live transcription on (`stt.streaming: true`, `PUT /api/config`), on the person's tap.
    func turnOnLiveTranscription(profile: String?) async {
        guard let backend = workspace?.roster?.backendClient else {
            fixError = String(localized: "Bot Mode isn't connected, so the app can't change this setting.")
            return
        }
        do {
            try await backend.updateConfig(.object(["stt": .object(["streaming": .bool(true)])]), profile: profile == gatewayProfile ? nil : profile)
            transcriptionFailures[profile ?? ""] = nil
        } catch BackendClient.Failure.http(_, let detail?) where !detail.isEmpty {
            fixError = detail
        } catch {
            Self.logger.error("turning on live transcription failed: \((error as NSError).domain, privacy: .public) \((error as NSError).code)")
            fixError = String(localized: "The gateway didn't take the change. Check that Bot Mode is connected and try again.")
        }
        await check(profile: profile)
    }

    /// Hey Hermes' Turn On: the gateway's wake word on (`wake.start` with `persist`, which sets
    /// `wake_word.enabled`), on the person's tap.
    func turnOnWakeWord() async {
        guard let workspace else { return }
        await HeyHermes.shared.turnOnOnGateway(workspace: workspace)
        await check(profile: nil)
    }

    /// Saves a provider key in the profile's `.env` (`PUT /api/env`): typed by the person, sent
    /// once, kept nowhere and never logged.
    func saveKey(_ name: String, value: String, profile: String?) async throws {
        guard let backend = workspace?.roster?.backendClient else { throw URLError(.notConnectedToInternet) }
        try await backend.setEnv(key: name, value: value, profile: profile == gatewayProfile ? nil : profile)
        failures[profile ?? ""] = nil
        transcriptionFailures[profile ?? ""] = nil
        await check(profile: profile)
    }

    // MARK: Internals

    private var gatewayProfile: String? { workspace?.bot.profileName }

    private static func checking(profile: String?) -> [SetupStatus] {
        var features = [("talk", String(localized: "Talk")), ("listen", String(localized: "Listen")), ("messages", String(localized: "Voice messages"))]
        if TalkPreferences.transcribeOn == .gateway { features.append(("transcription", String(localized: "Transcribe on the gateway"))) }
        if profile == nil, TalkPreferences.heyHermes { features.append(("wake", String(localized: "Hey Hermes"))) }
        return features.map { SetupStatus.checking(id: VoiceSetupRules.id($0.0, profile: profile), title: $0.1) }
    }

    private func read(profile: String?) async -> [SetupStatus] {
        guard let roster = workspace?.roster else {
            return Self.unknown(profile: profile, reason: String(localized: "Turn on Bot Mode for this gateway to see what voice it has."))
        }
        guard roster.isConnected else {
            return Self.unknown(profile: profile, reason: String(localized: "Can't reach the gateway. Talk and Listen use this \(Self.device)'s voice until it's back."))
        }
        let backend = roster.backendClient
        let asked = profile ?? gatewayProfile
        do {
            async let config = backend.config(profile: asked)
            async let keys = backend.envKeysSet(profile: asked)
            async let live = backend.voiceLiveStatus(profile: asked)
            async let clientConfig = backend.voiceConfig(profile: asked)
            async let signIns = backend.signedInProviders(profile: asked)
            let (settings, keysSet) = try await (config, keys)
            let realtime = try? await live
            // Its verdicts and whether it transcribes live: the keys voice-config carries aren't read.
            let verdicts = try? await clientConfig
            let streams = verdicts?.stt.streaming ?? false
            let provider = settings["tts"]?["provider"]?.stringValue?.lowercased() ?? "edge"
            let voiceKey = BotVoiceModel.providers.first { $0.id == provider }?.voiceKey
            var facts = VoiceFacts(
                speechProvider: provider,
                speechVoice: voiceKey.flatMap { settings["tts"]?[provider]?[$0]?.stringValue },
                transcriptionProvider: settings["stt"]?["provider"]?.stringValue?.lowercased() ?? "local",
                realtimeVoice: settings["voice"]?["gpt_live"]?["voice"]?.stringValue ?? "marin",
                keysSet: keysSet,
                realtimeAvailable: realtime?.isRealtime ?? false,
                realtimeReason: realtime?.reason,
                lastSpeechFailure: failures[profile ?? ""],
                wantsLiveTranscription: TalkPreferences.transcribeOn == .gateway,
                liveTranscriptionOn: settings["stt"]?["streaming"]?.boolValue ?? false,
                liveTranscriptionAvailable: streams,
                lastTranscriptionFailure: transcriptionFailures[profile ?? ""]
            )
            // What the gateway can do without a key: credentials it hands out or manages, and
            // sign-ins (xAI Grok), so it never asks for a key it doesn't need.
            facts.speechVerdict = verdicts?.tts.verdict
            facts.transcriptionVerdict = verdicts?.stt.verdict
            facts.signedIn = (try? await signIns) ?? []
            // Hey Hermes: one detector per gateway, asked over the socket when it's on.
            if profile == nil, TalkPreferences.heyHermes {
                facts.wantsWake = true
                facts.wakePause = HeyHermes.shared.pauseReason
                let params: [String: JSONValue] = ["surface": .string("gui"), "client_capture": .bool(true)]
                facts.wake = (try? await roster.request("wake.status", params, timeout: .seconds(20))).map(WakeState.init(status:))
            }
            if let profile { botFacts[profile] = facts } else { self.facts = facts }
            return VoiceSetupRules.statuses(facts, device: Self.device, profile: profile)
        } catch {
            Self.logger.error("voice setup: \((error as NSError).domain, privacy: .public) \((error as NSError).code)")
            return Self.unknown(profile: profile, reason: String(localized: "This gateway didn't say what voice it has. It may need a newer Hermes Agent."), update: true)
        }
    }

    private static func unknown(profile: String?, reason: String, update: Bool = false) -> [SetupStatus] {
        checking(profile: profile).map { status in
            var unknown = SetupStatus.unknown(id: status.id, title: status.title, reason: reason, docs: VoiceSetupRules.talkDocs)
            if update { unknown.steps = [.updateHermes, .restartGateway] }
            return unknown
        }
    }
}

extension BotWorkspace {
    /// Talk, Listen and voice messages on this gateway: Voice & Audio and Settings → Setup.
    var voiceSetup: VoiceSetup { VoiceSetup.of(self) }
}
