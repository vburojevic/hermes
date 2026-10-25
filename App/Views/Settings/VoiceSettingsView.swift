import HermesKit
import HermesMarkdown
import SwiftUI

/// Settings → Voice & Audio (`voiceSettings`, `docs/voice.md` §6): how Talk, voice messages,
/// Listen and transcription behave on this device. Hermes's voice lives on the gateway.
struct VoiceSettingsView: View {
    let workspace: BotWorkspace?

    @AppStorage(TalkPreferences.Key.engine) private var engine = TalkPreferences.EngineChoice.realtime
    @AppStorage(TalkPreferences.Key.pause) private var pause = Endpointer.Pause.normal.rawValue
    @AppStorage(TalkPreferences.Key.replies) private var replies = TalkPreferences.Replies.whenISpeak
    @AppStorage(TalkPreferences.Key.raiseToListen) private var raiseToListen = true
    @AppStorage(TalkPreferences.Key.studioMic) private var studioMic = true
    @AppStorage(TalkPreferences.Key.listenSpeed) private var speed = 1.0
    @AppStorage(TalkPreferences.Key.codeAndTables) private var codeAndTables = SpokenDetail.describe.rawValue
    @AppStorage(TalkPreferences.Key.language) private var language = ""
    @AppStorage(TalkPreferences.Key.transcribeOn) private var transcribeOn = TalkPreferences.TranscribeOn.device
    @AppStorage(TalkPreferences.Key.heyHermes) private var heyHermes = false
    @AppStorage(TalkPreferences.Key.sounds) private var sounds = true
    @State private var realtimeAvailable: Bool?
    @State private var hermesVoice: BotVoiceModel?
    @State private var showsHermesVoice = false
    @State private var keyEntry: VoiceKeyEntry?

    private static let speeds: [Double] = [1, 1.25, 1.5, 1.75, 2]

    var body: some View {
        Form {
            // What the gateway has, and how to set up what it hasn't (`docs/voice.md` §6.1).
            if let workspace {
                VoiceSetupSections(setup: VoiceSetup.of(workspace), keyEntry: $keyEntry, onChooseVoice: hermesVoice.map { _ in { showsHermesVoice = true } })
            }
            Section {
                Picker("Talk engine", selection: $engine) {
                    ForEach(TalkPreferences.EngineChoice.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                if let hermesVoice {
                    NavigationLink {
                        BotVoiceView(model: hermesVoice)
                            .settingsPage(back: String(localized: "Voice & Audio"))
                    } label: {
                        LabeledContent("Hermes's voice", value: hermesVoice.isLoading ? "" : hermesVoice.realtimeTitle)
                    }
                }
                Picker("Answer after a pause of", selection: $pause) {
                    Text("Short").tag(Endpointer.Pause.short.rawValue)
                    Text("Normal").tag(Endpointer.Pause.normal.rawValue)
                    Text("Long").tag(Endpointer.Pause.long.rawValue)
                }
            } header: {
                Text("Talk")
            } footer: {
                if realtimeAvailable == false {
                    Text("This gateway has no Realtime voice, so Talk uses Hermes Voice: it transcribes on this device and answers in Hermes's voice.")
                } else {
                    Text("Realtime answers fastest and handles interruptions best; your voice goes to OpenAI through Hermes's key. Hermes Voice transcribes on this device.")
                }
            }

            Section {
                Toggle("Hey Hermes", isOn: $heyHermes)
                    .onChange(of: heyHermes) {
                        HeyHermes.shared.update(workspace: workspace, retry: true)
                        guard let workspace else { return }
                        Task { await VoiceSetup.of(workspace).checkSetup() }
                    }
            } footer: {
                #if os(iOS)
                Text("Say “Hey Hermes” to start a call while this \(VoiceSetup.device) is charging and Hermes is open. The microphone streams to the gateway while it listens, and the gateway's wake word engine hears the words; Hermes may install that engine the first time.")
                #else
                Text("Say “Hey Hermes” to start a call while Hermes is open. The microphone streams to the gateway while it listens, and the gateway's wake word engine hears the words; Hermes may install that engine the first time.")
                #endif
            }

            Section("Voice Messages") {
                Picker("Voice replies", selection: $replies) {
                    ForEach(TalkPreferences.Replies.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                #if os(iOS)
                if UIDevice.current.userInterfaceIdiom == .phone {
                    Toggle("Raise to Listen", isOn: $raiseToListen)
                }
                Toggle("AirPods studio-quality mic", isOn: $studioMic)
                #endif
            }

            Section("Listen") {
                Picker("Speed", selection: $speed) {
                    ForEach(Self.speeds, id: \.self) { value in
                        Text(Self.speedTitle(value)).tag(value)
                    }
                }
                Picker("Code and tables", selection: $codeAndTables) {
                    Text("Describe them").tag(SpokenDetail.describe.rawValue)
                    Text("Skip").tag(SpokenDetail.skip.rawValue)
                }
            }

            Section {
                Picker("Transcribe on", selection: $transcribeOn) {
                    Text("This \(VoiceSetup.device)").tag(TalkPreferences.TranscribeOn.device)
                    Text("The Gateway").tag(TalkPreferences.TranscribeOn.gateway)
                }
                .onChange(of: transcribeOn) {
                    // Its status shows only while the gateway is chosen.
                    guard let workspace else { return }
                    Task { await VoiceSetup.of(workspace).checkSetup() }
                }
                Picker("Language", selection: $language) {
                    Text("Device Language").tag("")
                    ForEach(languages, id: \.identifier) { locale in
                        Text(DictationLanguageMenu.name(locale)).tag(locale.identifier)
                    }
                }
            } header: {
                Text("Transcription")
            } footer: {
                if transcribeOn == .gateway {
                    Text("In a call, your voice goes to the gateway as you speak and its provider transcribes it, which may be paid. Voice messages and dictation transcribe on this device.")
                } else {
                    Text("Speech models download once per language and work offline. Nothing you say leaves this device until you send it.")
                }
            }

            Section {
                Toggle("Sounds and haptics", isOn: $sounds)
            } footer: {
                Text("A tone when Talk starts listening, sends and ends.")
            }
        }
        .formStyle(.grouped)
        .voiceSetup(workspace.map(VoiceSetup.of), profile: nil, keyEntry: $keyEntry)
        .navigationTitle("Voice & Audio")
        .navigationDestination(isPresented: $showsHermesVoice) {
            if let hermesVoice {
                BotVoiceView(model: hermesVoice)
                    .settingsPage(back: String(localized: "Voice & Audio"))
            }
        }
        .task {
            installed = await SpeechInput.installedDictationLocales()
            guard let roster = workspace?.roster, roster.isConnected else { return }
            let backend = roster.backendClient
            let profile = workspace?.bot.profileName
            let model = BotVoiceModel(backend: backend, profile: profile, title: "Hermes")
            hermesVoice = model
            await model.load()
            realtimeAvailable = (try? await backend.voiceLiveStatus(profile: profile))?.isRealtime
        }
    }

    @State private var installed: [Locale] = []

    /// The installed languages, and the one picked even if it isn't installed yet.
    private var languages: [Locale] {
        var all = installed
        if !language.isEmpty, !all.contains(where: { $0.identifier == language }) { all.append(Locale(identifier: language)) }
        return all.sorted { DictationLanguageMenu.name($0) < DictationLanguageMenu.name($1) }
    }

    static func speedTitle(_ value: Double) -> String {
        value == value.rounded() ? "\(Int(value))×" : "\(value.formatted(.number.precision(.fractionLength(0...2))))×"
    }
}

/// Settings → Voice & Audio, from Settings.
struct VoiceSettingsRow: View {
    let workspace: BotWorkspace?

    var body: some View {
        NavigationLink {
            VoiceSettingsView(workspace: workspace)
        } label: {
            Label("Voice & Audio", systemImage: "waveform")
        }
    }
}

/// A Bot's voice (`botVoicePicker`): its Realtime voice for Talk, and its provider, voice and
/// speed for replies and voice messages. Saved to the Bot's profile on the gateway.
struct BotVoiceView: View {
    let model: BotVoiceModel
    /// This Bot's (or the gateway's) Talk, Listen and voice messages, when known.
    var setup: VoiceSetup?
    @State private var typedVoice = ""
    @State private var keyEntry: VoiceKeyEntry?

    var body: some View {
        Form {
            if let setup {
                // A Bot's own: the gateway's own statuses show on Voice & Audio.
                VoiceSetupSections(setup: setup, profile: model.profile, keyEntry: $keyEntry)
            }
            if let failure = model.failure {
                Section {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Theme.danger)
                }
            }
            Section("Realtime (Talk)") {
                ForEach(BotVoiceModel.realtimeVoices) { voice in
                    VoiceChoiceRow(
                        voice: voice, kind: String(localized: "realtime"),
                        isSelected: model.realtimeVoice == voice.id,
                        canPreview: model.canPreview, isPreviewing: model.previewing == voice.id,
                        onSelect: { Task { await model.setRealtimeVoice(voice.id) } },
                        onPreview: { model.preview(voice.id, realtime: true) }
                    )
                }
            }
            Section {
                Picker("Provider", selection: Binding(get: { model.providerID }, set: { id in Task { await model.setProvider(id) } })) {
                    ForEach(BotVoiceModel.providers) { provider in
                        Text(provider.title).tag(provider.id)
                    }
                }
                if model.provider.voiceKey != nil {
                    if model.voices.isEmpty {
                        // Providers without a list: the voice's name, as the provider spells it.
                        LabeledContent("Voice") {
                            TextField("Voice", text: $typedVoice, prompt: Text(model.voice ?? String(localized: "Default")))
                                .multilineTextAlignment(.trailing)
                                .onSubmit { Task { await model.setVoice(typedVoice.trimmingCharacters(in: .whitespaces)) } }
                                .autocorrectionDisabled()
                        }
                    } else {
                        NavigationLink {
                            ProviderVoicesView(model: model)
                                .settingsPage(back: String(localized: "\(model.title)'s Voice"))
                        } label: {
                            LabeledContent("Voice", value: model.voiceTitle)
                        }
                    }
                }
                Picker("Speed", selection: Binding(get: { model.speed }, set: { value in Task { await model.setSpeed(value) } })) {
                    ForEach([0.75, 1, 1.25, 1.5], id: \.self) { value in
                        Text(VoiceSettingsView.speedTitle(value)).tag(value)
                    }
                }
            } header: {
                Text("Replies and Voice Messages")
            } footer: {
                Text("Saved to \(model.title)'s profile on the gateway (tts.provider, tts.\(model.providerID).\(model.provider.voiceKey ?? "voice")).")
            }
        }
        .formStyle(.grouped)
        .voiceSetup(setup, profile: model.profile, keyEntry: $keyEntry)
        .navigationTitle("\(model.title)'s Voice")
        .overlay {
            if model.isLoading { Spinner(size: .regular) }
        }
        .onDisappear { model.stopPreview() }
    }
}

/// The provider's voices, with previews where the gateway allows them.
private struct ProviderVoicesView: View {
    let model: BotVoiceModel

    var body: some View {
        List(model.voices) { voice in
            VoiceChoiceRow(
                voice: voice, kind: model.provider.title,
                isSelected: model.voice == voice.id,
                canPreview: model.canPreview, isPreviewing: model.previewing == voice.id,
                onSelect: { Task { await model.setVoice(voice.id) } },
                onPreview: { model.preview(voice.id, realtime: false) }
            )
        }
        .navigationTitle("Voice")
        .onDisappear { model.stopPreview() }
    }
}

/// A voice to pick (`voiceRow`, `voiceRowSelected`): a radio, its name and character, and a
/// preview button.
private struct VoiceChoiceRow: View {
    let voice: BotVoiceModel.Voice
    let kind: String
    let isSelected: Bool
    let canPreview: Bool
    let isPreviewing: Bool
    let onSelect: () -> Void
    let onPreview: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onSelect) {
                HStack(spacing: 12) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22))
                        .foregroundStyle(isSelected ? Theme.ink : Theme.tertiaryText)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(voice.name)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Theme.primaryText)
                        Text([voice.detail, kind].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            if canPreview {
                Button(action: onPreview) {
                    Image(systemName: isPreviewing ? "stop.fill" : "play.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(isPreviewing ? Theme.inkForeground : Theme.primaryText)
                        .frame(width: 34, height: 34)
                        .background(isPreviewing ? Theme.ink : Theme.controlFill, in: Circle())
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel(isPreviewing ? "Stop preview" : "Preview \(voice.name)")
            }
        }
    }
}

/// Edit Bot → Voice.
struct BotVoiceRow: View {
    let roster: BotRoster
    let profile: String
    let title: String
    var workspace: BotWorkspace?
    @State private var model: BotVoiceModel?

    var body: some View {
        if let model {
            NavigationLink {
                BotVoiceView(model: model, setup: workspace.map(VoiceSetup.of))
            } label: {
                LabeledContent("Voice", value: model.isLoading ? "" : model.realtimeTitle)
            }
        } else {
            LabeledContent("Voice", value: "")
                .task {
                    guard roster.isConnected else { return }
                    let model = BotVoiceModel(backend: roster.backendClient, profile: profile, title: title)
                    self.model = model
                    await model.load()
                }
        }
    }
}

#if os(macOS)
/// Settings → Voice & Audio on the Mac.
struct MacVoicePane: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        NavigationStack {
            VoiceSettingsView(workspace: app.currentWorkspace)
        }
    }
}
#endif

/// A voice feature's fallback note (`SetupNote`) whose Set Up… opens Settings → Voice & Audio:
/// the Settings sheet on iPhone and iPad, the Settings window's pane on the Mac.
struct VoiceSetupNote: View {
    let status: SetupStatus
    /// Before Settings opens: a call is minimised first, as a sheet over it would end it.
    var beforeOpening: () -> Void = {}

    @Environment(WindowRouter.self) private var router: WindowRouter?
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #endif

    var body: some View {
        SetupNote(status: status, actionTitle: String(localized: "Set Up…"), action: open)
    }

    private func open() {
        beforeOpening()
        #if os(macOS)
        UserDefaults.standard.set("voice", forKey: MacSettingsView.paneKey)
        openSettings()
        #else
        router?.showVoiceSettings()
        #endif
    }
}

/// Talk, Listen and voice messages on this gateway or Bot (`docs/voice.md` §6.1): each one's
/// state, what it falls back to, the fix the app can make (a key, a voice) and how to set it up
/// elsewhere, with Check Again.
struct VoiceSetupSections: View {
    let setup: VoiceSetup
    var profile: String?
    /// The key the person is adding: its sheet hangs off the page (`voiceSetup(_:profile:keyEntry:)`).
    @Binding var keyEntry: VoiceKeyEntry?
    /// Choose a Voice…: the page with the provider and voice pickers; `nil` when they're on this one.
    var onChooseVoice: (() -> Void)?

    var body: some View {
        ForEach(setup.statuses(for: profile)) { status in
            SetupSection(status, check: { await setup.check(profile: profile) }, fix: fix(for: status))
        }
    }

    /// The action for a status's fix: a key the gateway is missing, or the voice pickers.
    private func fix(for status: SetupStatus) -> (() -> Void)? {
        guard status.fix != nil else { return nil }
        let facts = profile.flatMap { setup.botFacts[$0] } ?? setup.facts
        let feature = status.id.split(separator: "@").first.map(String.init) ?? status.id
        switch feature {
        case "voice.talk":
            let key = facts?.missingSpeechKey ?? VoiceProviders.realtimeKeys[0]
            return { keyEntry = VoiceKeyEntry(name: key) }
        case "voice.listen":
            if let key = facts?.missingSpeechKey { return { keyEntry = VoiceKeyEntry(name: key) } }
            return onChooseVoice
        case "voice.messages":
            guard let key = facts?.missingTranscriptionKey else { return nil }
            return { keyEntry = VoiceKeyEntry(name: key) }
        case "voice.transcription":
            if let key = facts?.missingLiveTranscriptionKey { return { keyEntry = VoiceKeyEntry(name: key) } }
            return { Task { await setup.turnOnLiveTranscription(profile: profile) } }
        case "voice.wake":
            return { Task { await setup.turnOnWakeWord() } }
        default:
            return nil
        }
    }
}

/// A provider key the person is adding for the gateway.
struct VoiceKeyEntry: Identifiable {
    let name: String
    var id: String { name }
}

extension View {
    /// The key sheet and the setup check for a page with `VoiceSetupSections`, on its Form: on the
    /// sections they'd be copied onto every row, and a dozen sheets for one key closed Settings.
    func voiceSetup(_ setup: VoiceSetup?, profile: String?, keyEntry: Binding<VoiceKeyEntry?>) -> some View {
        sheet(item: keyEntry) { entry in
            if let setup { VoiceKeySheet(name: entry.name, setup: setup, profile: profile) }
        }
        .alert("Couldn't Change It", isPresented: Binding(get: { setup?.fixError != nil }, set: { if !$0 { setup?.fixError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(setup?.fixError ?? "")
        }
        .task(id: profile) { await setup?.check(profile: profile) }
    }
}

/// A provider key for the gateway (`PUT /api/env`): typed here, sent once, kept nowhere, never
/// logged. Hermes reads it from the profile's `.env`.
struct VoiceKeySheet: View {
    let name: String
    let setup: VoiceSetup
    var profile: String?

    @Environment(\.dismiss) private var dismiss
    @State private var value = ""
    @State private var isSaving = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField(name, text: $value)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                } footer: {
                    Text("Saved in the gateway's settings for \(profile ?? String(localized: "Hermes")) (\(name) in its .env). This app doesn't keep it.")
                }
                if let failure {
                    Section {
                        Label(failure, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Theme.danger)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Add Key")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(value.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
                }
            }
        }
        .frame(minWidth: 380, minHeight: 220)
    }

    private func save() {
        isSaving = true
        let typed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            defer { isSaving = false }
            do {
                try await setup.saveKey(name, value: typed, profile: profile)
                value = ""
                dismiss()
            } catch BackendClient.Failure.http(_, let detail?) where !detail.isEmpty {
                // Hermes says why (a pinned key, a name it won't take).
                failure = detail
            } catch {
                failure = String(localized: "The gateway didn't take the key. Check that Bot Mode is connected and try again.")
            }
        }
    }
}
