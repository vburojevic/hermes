# Voice and audio

Everything the app hears and says: dictation, voice messages, Listen (replies read aloud) and
Talk (calls with a Bot), and the one audio coordinator under them. The design is in the design
project (`docs/voice.md`, `blocks/audio.elyx`, `screens/iphone/talk.elyx`,
`voice-messages.elyx`, `voice-settings.elyx`, `screens/ipad/talk.elyx`, `screens/mac/talk.elyx`,
`flows/voice.elyx`). Section numbers here match it, so code can cite `docs/voice.md §n`.

Code: `App/Audio/` (the engine paths: `SpeechInput`, `SpokenPlayer`, `DeviceVoice`,
`HermesVoiceEngine`), `Packages/HermesKit/Sources/HermesKit/Audio/` (`AudioCoordinator`,
`AudioGraph`, `AudioPlatform`), `Packages/HermesKit/Sources/HermesKit/Voice/` (turn-taking,
spoken answers, which reply is read), `Packages/HermesKit/Sources/HermesMarkdown/SpokenText.swift`
(what a reply sounds like).

## 1. Principles

- Three gestures: tap the microphone to dictate, hold it to send a voice message, tap the
  waveform to Talk.
- Spoken is also written: every voice message has its transcript, every Talk turn is a normal
  message.
- Interrupt any time, with a word or a tap.
- Each Bot sounds like itself.
- Polite by default: nothing records unless you hold or tap; replies speak by themselves only
  when you spoke first and the audio is private.
- On the device first: transcription runs on the device.

## 2. Voice messages

**Recording** (`recorder`, `recorderLock`, `recorderButton`, `recorderLocked`, `recorderReview`;
`App/Audio/VoiceRecorder.swift`, `App/Views/Composer/VoiceRecorderViews.swift`):

- Tap the microphone to dictate; hold it (0.28 s) to record. It grows to 76 pt and turns red under
  the finger, and the composer becomes the recorder: the red dot and the time, the live waveform,
  "‹ Slide to cancel", and the words above as they're heard (the newest lighter).
- Let go to send. Slide left past half the composer to cancel (a haptic as it goes). Slide up
  onto the lock to record hands-free; VoiceOver's "Record a voice message" action starts there.
- Locked: the transcript builds above; Delete, Pause and Send below. From 9:30 a line says it
  stops at 10:00, where it pauses into Review.
- Review: play back and scrub (a knob on the waveform), fix the transcript (it's what Hermes
  reads), keep recording (appended), Delete or Send.
- A hold under 0.6 s with no words isn't sent: "Hold to record" shows in the field for 2 s.
- A call, Siri or a phone call takes the microphone: the recording pauses into Review.

**Capture:** the coordinator's recording role (with AirPods high-quality recording when Studio
quality is on). One input tap feeds the encoder (`VoiceFileWriter`: AAC mono, 24 kHz, 32 kbps,
`.m4a`, encoded off the audio thread), the waveform (levels every 50 ms) and `SpeechInput`.
Recording starts at once; the transcriber joins when its model is ready (prepared once, and
ahead of time when the model is already on the device). Each stretch between pauses is a file;
pausing joins them.

**Sending** (`ConversationModel.sendVoiceMessage`):

- The message text is the transcript. If the device heard no words, the message still shows at
  once as audio (playable, from the recording on this device), and the gateway transcribes it on
  the way (`POST /api/audio/transcribe`, over the gateway protocol only; `gatewayWords`), beside
  the upload. Hermes reads words, not the recording (`prompt.submit` takes text; an `@file:` of
  audio reaches the model as a binary file), so the prompt goes once the words are back, and
  they fill in under the waveform. Meanwhile the turn's live line says "Transcribing…" (the one
  moving thing; the bubble itself stays still) and VoiceOver reads "Your voice message, 0:07,
  transcribing". A long recording isn't "waiting": the 10 s that turn "Sending…" into "Waiting for
  <Mac>…" don't run while it's transcribed. A gateway that's away, restarting or too busy to answer
  (no answer, 429, 502–504) is asked again after a pause (`SendFailure.pause`) and the line says
  "Waiting for <Mac>…"; the message is kept on the device from the start of the transcription, so
  quitting the app meanwhile loses nothing (after a relaunch it's held at the top of Up Next, with
  its recording, for Send). Stop gives it back, as before the prompt leaves.
- When the gateway heard no words (`""`) or couldn't transcribe it (a 400 such as "No STT provider
  available. …", or a provider's 500), the message goes with the recording alone, as Hermes can
  still reach the file, and the bubble says why under the waveform: "No words were heard in it."
  or "Couldn't transcribe it." with the first sentence of Hermes's reason (`VoiceTranscription`).
  A voice message stored without words, from before a relaunch or another device, says "No
  transcript." On the API server (no upload) a recording without words isn't sent: "No words were
  heard in it, and this chat can only send words."
- Over the gateway protocol the recording goes with it: `file.attach` as `voice-<uuid>.m4a`, an
  `@file:` line after the transcript. Hermes keeps it in the profile's `attachments/` and gives an
  absolute path, which `/api/files/stream` serves to every device. On the API server (no upload)
  it's the transcript alone.
- While Hermes works it waits in Up Next, like any message with a file (a recording can't steer);
  the tray calls it "Voice message" until it has words, which it gets when it goes.
- The recording is kept on this device under its message name (Caches/VoiceMessages), so the
  sender's bubble never downloads it.

**The bubble** (`voiceMessage`, `VoiceMessageBubble`): a user message carrying a `voice-<uuid>.m4a`
reference (`UserEntry.voicePath`; it's not a file chip). Play/Pause, the waveform (played bars
ink), the length (the position while it plays) and speed 1×/1.5×/2× (pitch kept, shared with
Listen); the transcript under it, 3 lines then More. Tap the waveform to jump; while it's loaded,
drag sideways to scrub (on iPhone and iPad a UIKit pan that begins only sideways, `SidewaysSwipe`,
so a vertical drag on it still scrolls the chat). Long press: Copy Transcript, Save Audio…,
Share. Voice messages from other devices are fetched as they come into view (`GET
/api/files/stream?path=`, kept in the same cache).
VoiceOver reads it as one element with Play/Pause, adjust (±5 s) and Speed.

**A Bot's audio** (`listenStrip`, `ListenStrip`): a reply's `MEDIA:<path>` line with an audio
extension (Hermes's list: ogg, opus, mp3, m2a, wav, m4a, flac) becomes a strip before the reply's
words, played from `/api/files/stream`. `[[audio_as_voice]]` (the `text_to_speech` tool) makes
every audio file in the message a voice message; other audio is titled with its file name.
Paths inside code blocks are examples and stay text; the same file twice plays once
(`AgentAudio.split`). Other `MEDIA:` lines stay "Attachment on server".

**Playback** (`ClipPlayer`): one clip at a time, on the coordinator's playback role, through the
one engine (`AVAudioPlayerNode` → `AVAudioUnitTimePitch`). A call or the headphones coming out
pause it; an engine restart picks up where it was.

**Replies in kind** (Settings → Voice & Audio → Voice replies: When I Speak, Always, Never;
`VoiceReplies`): each reply after a voice message, until the person writes again, opens with a
strip that reads it in the Bot's voice (Listen, §3). Its waveform is shaped from the words
(`SpeechShape`), as the audio is made on demand.

## 3. Listen (read aloud)

**What it reads** (`MarkdownDocument.spokenScript`, the one cleaner for every spoken path):

- prose, headings, list items and quotes, sentence by sentence (`NLTokenizer`);
- code blocks and tables are described ("I put the Swift code in the chat", "I put a table with
  4 rows in the chat"), or skipped (Code and tables: Skip);
- links read their words, never their address; bare URLs are dropped;
- images, HTML and rules are left out;
- widgets read as their own words (`SpokenWidgets`): each its `fallback_text` (a directive the
  store doesn't have yet, its `alt`), and a scheduled report (`stack`) as a brief: "Your Friday
  brief: Morning brief." (the weekday of its `as_of`, in its time zone), then each widget's words in
  order, a newer revision of a child when the store has one, never the stack's own text, which
  repeats them. Private widgets are read too (the person asked, and Now Playing shows only the chat
  and the Bot), but the mini player shows the chat's title instead of their sentences, which the app
  switcher would keep.

Each sentence knows its block and its place in that block's text, for highlighting.

**Starting it** (`ListenPlayer`, `App/Audio/ListenPlayer.swift`): the speaker in a reply's actions
row, Listen / Stop Listening in its menu, or the strip a reply to a voice message opens with
(`ReplyListenStrip`, replies in kind, §2). A routine's delivery (`RoutineDeliveryRow`) has the
speaker beside its time and Listen in its menu: Listen to the brief. One reply at a time; starting
another stops it.

**The voice:** the Bot's own, from the gateway (`WS /api/audio/speak-stream?profile=`, one sentence
a socket, `POST /api/audio/speak` when the provider can't stream), with `POST /api/audio/tts-lease
{lease: "app:listen"}` held while it reads. Offline, without a gateway voice, or when a sentence
fails, the device's best voice for the reply's language reads on (`DeviceVoice`).

**While it plays:**

- The sentence being read is ink in the reply and everything else is lighter
  (`MarkdownView(highlight:)`): the gateway gives no timings, so the app lights the sentence it
  fed. Paragraphs light the sentence; headings, lists and quotes light the whole block.
- The mini player (`miniPlayer`, `ListenMiniPlayer`) floats 12 pt above the composer in every chat
  while a reply is read, and rides up with it as it grows (more lines, attachments): the Bot's
  face, Listening/Paused and the sentence, Back 15 s, Play/Pause, the speed (1×/1.5×/2×, pitch
  kept, shared with voice messages) and Close.
- Back 15 s goes to the sentence that was playing then; Ahead skips sentences worth about 15 s.
- Now Playing (`NowPlayingPublisher`): the chat's title, the Bot, its face as artwork, Play/Pause,
  Back/Ahead 15 s, Stop and the speed. On 27 a NowPlaying `MediaSession` watches the player
  (`ListenMediaModel`); on 26 `MPNowPlayingInfoCenter` and `MPRemoteCommandCenter`. The elapsed time
  is given at each change (start, pause, skip, speed) and the system runs it on.
- The session is `.playback` / `.spokenAudio` without mixing: Now Playing takes a session that
  doesn't mix, so other audio pauses while a reply is read, like a podcast. Headphones coming out,
  a call or Siri pause it.
- Replies in kind play by themselves only for the newest reply, just arrived, when the route is
  private (headphones); Raise to Listen (iPhone, while that strip shows) plays it to the receiver
  at the ear and pauses when the phone comes away.

## 4. Talk

A call with Hermes or a Bot (`talk.elyx`). Code: `App/Model/TalkCenter.swift` (the one call),
`TalkSession.swift` (its states and turns), `App/Audio/HermesVoiceEngine.swift`,
`RealtimeTalk.swift`, `GraphAudioDevice.swift`, `App/Views/Talk/`.

### 4.1 Two engines, one experience

| Engine | When | How |
|---|---|---|
| **Realtime** | Settings → Voice & Audio → Talk engine is Realtime (the default) and the gateway reports it (`GET /api/audio/voice-live/status` → `mode: "gpt-live", available: true`) | WebRTC to OpenAI's GPT-Live (`stasel/WebRTC`). The app makes the SDP offer (with the `oai-events` data channel in it) and `POST /api/audio/voice-live/session {sdp, history}` returns the answer (the gateway holds the key). `history` is the recent chat as GPT-Live items (24 messages, 6000 characters, each cut to 1200). Each `session.delegation.created` becomes `prompt.submit {surface: "voice-live", voice_context}` with what was said last; tool progress goes back as `session.thinking.append` ("Hermes is working: … Not done yet."), the reply as `session.commentary.append` in sentences of up to 1400 characters. Captions come from `session.input_transcript.delta` / `output_transcript.delta`. A newer request stops the turn still running |
| **Hermes Voice** | Otherwise | On-device transcription and endpointing (§4.2). Each turn is `prompt.submit {text, voice_turn: true, surface: "voice-live", voice_context, interrupted?}`. The reply is read as it streams in the Bot's voice: one `WS /api/audio/speak-stream?profile=<bot>` per sentence (`{text, done}` in; `start {sample_rate}`, int16 PCM and `end` back; `fallback` → `POST /api/audio/speak`), played through the call's engine. `POST /api/audio/tts-lease {lease: "app:talk"}` keeps the voice warm for the call |

- The header says which engine runs ("2:14 · Realtime").
- The first Realtime call says the audio goes to OpenAI through the gateway's key.
- If Realtime can't start, or drops mid-call, the call carries on as Hermes Voice ("Switched to
  Hermes Voice") on the same audio.
- Without Bot Mode there's no gateway voice or Realtime: the device's voice reads, and turns go
  as normal messages.
- `voice_context` is the spoken exchange so far, "User: …" / "Voice assistant: …", newest 6000
  characters (`VoiceTurn`).

### 4.2 The audio graph (Hermes Voice)

- One engine for the whole call, with voice processing on the input (echo cancellation, noise
  suppression, gain control). The reply plays on a player node in the same engine, so the echo
  canceller hears it and removes it. There is no text-level echo filter.
- On iPhone and iPad Realtime uses the same engine: a custom WebRTC audio device
  (`GraphAudioDevice`) feeds the microphone's tap to WebRTC as 48 kHz 16-bit PCM and renders its
  playout in a source node. WebRTC's Mac SDK has no custom audio device, so on the Mac Realtime
  uses WebRTC's own Core Audio module and echo canceller, and its levels come from WebRTC's
  statistics.
- Kept alive between turns: the coordinator's Talk role is held from start to end, and one
  `SpeechAnalyzer` (a `SpeechTranscriber` where the device has it, else a `DictationTranscriber`)
  runs throughout. `SpeechInput.endTurn()` settles a turn's words without stopping it. Bot names
  are contextual strings.
- **Transcribe on: The gateway** (`GatewayTranscriber`): the words come from the gateway's own
  provider as you speak (`WS /api/audio/transcribe-stream`). The device still hears voice activity
  and decides when a turn ends: Hermes takes one socket per utterance and never ends one itself.
  When the person's near voice starts (`TalkEars`, so a TV never streams to a paid provider) the
  socket opens with `{"sample_rate": 16000}`, then the turn streams as
  16 kHz int16 mono from half a second before it started; `partial` carries everything heard so
  far, and the turn's end sends `{"eos": true}` and waits up to 10 s for `final`. A turn the
  socket lost (Hermes reports provider failures only after `eos`) goes whole to
  `POST /api/audio/transcribe`, as Hermes Desktop does. "No live STT for the configured provider",
  or two turns in a row the gateway couldn't transcribe, switch the rest of the call to the
  device's transcriber, and the call says why. A call checks voice-config's `stt.streaming` before
  it starts, so a gateway that can't never gets the audio. Only OpenAI, xAI and ElevenLabs stream
  in Hermes, all paid; voice messages and dictation always transcribe on the device.
- **What Talk hears** (`TalkEars`, in HermesKit): every 20 ms level of the echo-cancelled input
  (`SpeechInput` `.frames`, dBFS), the words with their times, and the Bot's own output level.
  Nothing is polled: the frames are the clock.
  - **Near** is the person, not the room: louder than the noise floor (`VoiceActivityDetector`'s
    adaptive floor), than the room's loudest moments (the `ceiling`: the 90th percentile of the
    last ten seconds that weren't the person, each the middle of 100 ms, so a TV, music or people
    across the room count and key clicks don't), and no more than 12 dB under the person's own
    turns (learned from each turn sent: up quickly, down slowly). Sound that follows the Bot's own
    level, as the room returns it, isn't near, and neither is its echo still dying away for half a
    second after it goes quiet: the transcriber hands over the Bot's last words a moment late, and
    without that they became your turn on the loudspeaker. A turn's words count only where they
    rose above the echo.
  - **The gate** (`NearGate`): while the Bot speaks, the transcriber hears only near sound
    (everything else 40 dB down, with 100 ms of lookahead so a word's soft start passes, open for
    250 ms after). A transcriber hearing the Bot's echo or a TV takes it for one long utterance and
    reports a word said over it seconds late; heard alone, "stop" comes back in about 0.35 s.
- **Realtime hears only the person while it speaks** (iPhone and iPad): GPT-Live's barge-in is
  its own, with no noise settings, and takes any voice for the person. So while its audio was
  loud in the last 0.4 s, what `GraphAudioDevice` sends it goes through a `NearGate` (50 ms of
  lookahead, `NearGate.realtimeLookahead`), with the threshold from `TalkEars` fed the microphone's
  levels in `RealtimeTalk`: a TV or people across the room arrive 40 dB down, the person's voice
  whole. The ears learn the person's level from turns GPT-Live transcribed, and a voice heard just
  before it answered is never the room's (`botAnswered`: its transcript can come later). A loud
  room offers Voice Isolation as with Hermes Voice. On the Mac WebRTC owns the microphone, so
  there's only mute. Checked without OpenAI with `-HERMES_REALTIME_LOOPBACK` (development.md).
- **Barge-in**: a near voice for 100 ms (steady: five of the last six frames, outside the first
  300 ms of each stretch of the Bot's speech) lowers the Bot to 20% within 60 ms, so it yields as
  you start. It stops (an 80 ms fade) only on the person's words: a stop phrase ("stop", "wait",
  "hold on", "one sec"…) with 100 ms of near voice, or two words that aren't backchannels ("mm-hm",
  "yeah", "okay"), hums or the Bot's own (its echo), with 250 ms of near voice (400 ms when the
  words are still being heard, untimed). Words quieter than near, less sure than 0.3, or still
  being heard from before the person's voice began don't count. Without words within 0.9 s of the
  voice stopping (2.5 s at most) the Bot comes back up; a room that keeps doing that has to be
  6 dB louder each time (up to 12) for 30 s. When it was reading the reply, stopping it also stops
  the turn if it's still running (`session.interrupt`); the next turn carries `interrupted: true`.
  A tap does the same. Talking over an ask (an approval, a question, a step note) stops only the
  ask. A lone "stop" is never sent to Hermes as a message. Words heard over the Bot that didn't
  stop it are dropped, and so are words heard while Hermes worked that were nobody's turn.
- **A loud room**: when the room's loudest moments come within 6 dB of the person's level (a TV or
  music right by the phone), no level tells them apart, so talking over the Bot may not stop it.
  The call says so ("It's loud here. Tap to interrupt." while it speaks) and offers Use Voice
  Isolation, which opens the system's Mic Mode (`AVCaptureDevice.showSystemUserInterface`; apps
  can't choose the mode). It goes once the room is 9 dB under the person again. Known after the
  first turn, logged ("loud room: ceiling -26 dB, person -24 dB").
- **Endpointing** (`Endpointer`, fed by `TalkEars`): a turn ends after a silence of Short 0.6 s /
  Normal 0.9 s / Long 1.4 s since the person's last near voice or words (when the words were said,
  not when they arrived), 0.4 s longer when the last word sounds unfinished ("and", "so", "um"). A
  turn's voice asks less than barge-in (`turnThreshold`: never more than 6 dB under the person's
  level), so a person in a loud room is still heard. Noise never holds a turn open: once the words
  stop for the pause plus 0.6 s it ends, whatever the room sounds like. Noise never makes one:
  words that were never near are dropped after 1.2 s.
- Every decision is logged with what it was decided on, never the words (category `talk`):
  `duck: near voice, level -23 dB, near -35 dB, floor -52 dB, person -23 dB, voice 120 ms`.
- **Mute**: `AVAudioApplication.setInputMuted`, so the AirPods stem mutes and unmutes too, and a
  mute from there is the call's mute (a lowered Bot comes back up, Realtime is muted too). Mute
  never stops the Bot. Talking while muted shows "You're muted"
  (`setMutedSpeechActivityEventListener`). A transcriber that fails while muted still says so.
- **Word times** (`AnalyzerClock`): the transcriber's timeline is the audio it was fed, so after a
  gap in the microphone (a phone call, the engine restarting for AirPods) each stretch keeps its
  own origin; otherwise the person's words would land in the past and count as the room's.
- **The face** moves with the real output level: RMS per 1/30 s of the audio being played,
  looked up by play time, into `BotFace(voiceLevel:)`. The same level is what `TalkEars` tells the
  Bot's echo by. A player that runs out (the reply still coming, the person's turn) keeps its
  clock going, so the silence goes on the level's timeline too (`AudioPlayerChain`); otherwise,
  after the first pause in a call, the level read as nothing, the Bot's echo on the loudspeaker
  counted as the person, and its own words came back as their turns. While listening, the rings follow the
  input level.
- **Sounds** (`HermesVoiceEngine.cue`): a soft rise on start and after a phone call, a tick when
  a turn is sent, a fall on end. Off with Sounds and haptics off.
- From the end of speech to the first audio, and from the call starting to Listening, are logged
  (category `talk`) and shown with `-HERMES_TALK_LATENCY YES`. The call takes the microphone while
  it asks whether Realtime runs, and doesn't wait for the voice's warm-up lease.

### 4.3 What happens in a call

| State | What shows | Design |
|---|---|---|
| Connecting | The face; "Downloading speech model · 40%" while the model downloads | |
| Listening | Rings in the Bot's colour; the words as heard, the last ones lighter until settled; "Pause when you're done" | `talkListening` |
| Working | The face works; the plan step or status line, lighter; the running step in a chip ("df -h /volume1 · 3 s"); a step longer than 4 s gets a short spoken note once ("Running a command."). Speaking now steers (`session.steer`), the same as a typed steer: a steer the turn can't take goes first in Up Next, its row saying why, and a chat something else holds makes it wait its turn there ([follow-ups.md](follow-ups.md) §2, §4) | `talkWorking` |
| Speaking | The sentence being said in ink, the next one lighter; "Talk or tap to interrupt" ("Talk to interrupt" with Realtime, which only a voice stops; "It's loud here. Tap to interrupt." in a loud room) | `talkSpeaking` |
| Needs your OK | Hermes asks out loud ("I need your OK to …"); the approval card docks; spoken answers as [quick-actions.md](quick-actions.md) §6. A tap on Always Allow, a flagged command or anything that can't be undone asks for Face ID | `talkApproval` |
| Question | A clarify question or setup choice read out with its choices, answered by voice ("the second one") or on the card | |
| Needs you to type | Secrets, sudo, vault and sign-ins: "I need you to type that", the card docks; never spoken | |
| On hold | A phone call or Siri has the audio; the call carries on after with a tone | |
| Offline, failed | Try Again and End | |
| Microphone off | Open Settings and Type Instead | |

- **Cards:** the table or code a reply put in the chat rises above the controls ("Hermes showed
  you a card") and stays in the chat (`talkCard`). The card is as tall as what it shows, up to
  204 pt (less when the screen has no more room); anything longer scrolls inside it. Widgets will
  show here too once the app has them.
- **The reply read** is the one to each turn sent during the call (spoken or typed into the call),
  followed by turn id (`SpokenReplyTracker`): a reply already in the chat is never read again, a
  later turn never takes over, and a turn that finishes and comes back as a stored row is read to
  its end. Every reply in the call is read, one after another, however fast it came: the call's
  player reads them all from one queue and, between two replies, carries on from the first
  sentence not yet heard (`SpokenQueue`).
- **Minimised** (the chevron, or swipe down; `talkMinimised`): the pill at the top of the chat
  (`callPill`) with Mute and End; the field says "Type into the call", and a typed message is a
  turn of the call (its reply is read). Spoken messages are marked Spoken.
- **Type** minimises and puts the cursor in the call's field.
- **Ended** (`talkEnded`): the call's turns fold into one `callSummary` card in the chat (length,
  turns, approvals, steps, Transcript to open the turns in place, Talk Again). The summary is
  Hermes's last reply when it's short enough to be one; otherwise the device writes it with the
  Foundation Models framework from the last 12,000 characters of the transcript, labelled
  "Summary by Apple Intelligence". No audio is kept, only the text (`CallRecord`, on this
  device).
- The transcript sheet (the captions button at the top) shows the call's words so far.
- VoiceOver announces each state once it has held for 0.8 s ("Listening", "Hermes is
  speaking"): a reply with pauses doesn't make it repeat itself.
- The notification permission prompt waits while a call runs.

### 4.4 Beyond the app

- **iPhone and iPad:** background audio (`UIBackgroundModes: audio`) and a Live Activity
  (`liveActivityTalk`, `islandTalk`, `islandTalkExpanded`; `TalkActivityAttributes`) with Mute
  and End as `LiveActivityIntent`s. It shows the face, the state and length, and the last words
  (updated at most every 4 s, the newest shown once the budget allows; the state and Mute at
  once, from the app, the Island or an AirPods stem). AirPods mute through `AVAudioApplication`.
  A call ends with the app that ran it, but its Live Activity doesn't: one left by a crash or by
  the app being stopped mid-call is ended at the next launch (`TalkActivity.endLeftovers`).
- **LiveCommunicationKit isn't used.** Apple presents it for calls between people (handles,
  Recents, PushKit), and App Review guideline 2.5.4 limits the `voip` background mode to its
  intended use; an AI conversation isn't a VoIP call. ChatGPT ships background voice the same way
  (a Live Activity and background audio). So there's no system call screen or CarPlay.
- **Interruptions and routes:** handled by the coordinator (§7). After a real phone call the call
  resumes with a tone. When AirPods connect or disconnect the engine restarts on the new route and
  what was playing is read on. The route button shows the current output (AirPods, Speaker,
  iPhone) and opens the system picker (`AVRoutePickerView`).
- **Entry points:**
  - the composer's waveform and ⌥⌘V (Chat → Talk; End Call while one runs);
  - Siri and Shortcuts: "Talk to Hermes", "Call Hermes", "Talk to <Bot> in Hermes"
    (`StartTalkIntent`, `HermesShortcuts`; the Bots are kept in the App Group for Shortcuts);
  - a control (`TalkControl`) for Control Center, the Lock Screen and the Action button.
  - From outside the app the call waits until Bot Mode is connected and the Bot is known.

### 4.5 iPad and Mac

- **iPad:** in landscape a floating glass panel over the chat (`ipadTalk`, `TalkPanel`), with the
  turns landing in the chat behind it; in portrait the iPhone layout. The route button never offers
  an earpiece.
- **Mac:** its own small window (`macTalk`), floating over every app, opened and closed with the
  call; Space mutes while it's focused, ⌥⌘V starts and ends. ActivityKit doesn't run in Mac apps,
  so the call also shows in the menu bar (`TalkMenuBar`: who, the state, Mute, Show Call, End
  Call). No `AVAudioSession`: voice processing on the engine, with other audio ducked moderately.
  Every state has its buttons, including Try Again and Open Settings.

### 4.6 "Hey Hermes"

Settings → Voice & Audio → Hey Hermes (off by default) starts a call by voice (`HeyHermes`):

- **Where:** the Mac whenever Hermes runs; iPhone and iPad while charging with Hermes in front (the
  app's socket closes in the background, so it couldn't listen there). The setup says which.
- **The gateway listens:** `wake.start {surface: "gui", client_capture: true}` on the backend
  socket. The engine (openWakeWord, sherpa-onnx or Porcupine) runs on the gateway's computer and
  costs nothing per use; the app streams the microphone to it as 16 kHz int16, 80 ms frames four
  at a time (`wake.feed {pcm, sample_rate}`). A gateway whose own microphone listens
  (`capture: "local"`) gets nothing from the app.
- **Heard:** `wake.detected {phrase, profile, start_new_session}` opens Talk with the Bot it names
  (`TalkCenter.pendingStart`), else Hermes in a new chat. Hermes pauses its detector before it says
  so; the app sends `wake.resume` when the call is over (or if it never started).
- **The microphone** is the coordinator's lowest role (`.wake`, §7): play and record, mixed with
  other audio, no Bluetooth call mode, no voice processing. A call, a recording, dictation or a
  reply read aloud pause it, and it listens again after; it lets go of its input on a pause, so
  Listen can play.
- **It never changes the gateway by itself:** `wake.start` goes without `persist`. A gateway with
  the wake word off (`wake_word.enabled`, off by default in Hermes) says so in the setup, whose
  Turn On sends `wake.start {persist: true}`; Hermes may install its engine then.
- **The setup** (`voice.wake`, only while it's on, §6.1): listening; the gateway's microphone
  listens; another device is listening (one detector per gateway); waiting for charging; off on
  the gateway (Turn On); kept for another surface (`wake_word.surface`); no engine or no voice on
  the gateway (Hermes's hint); can't check on a Hermes without `wake.*`.

## 5. Dictation

The composer's (`docs/composer.md` §3): on the device (`DictationTranscriber`, punctuation and
emoji, with the chat's Bot, project and skill names as contextual strings), so it works offline.
Words land at the caret, lighter until final, and typing carries on; the model's download shows
its progress; failures show with Try Again. The language is picked from the dictation row (a
long press on the microphone records a voice message instead). Group chats have it too.

## 6. Voices and settings

**Settings → Voice & Audio** (`voiceSettings`, `VoiceSettingsView`; a pane on the Mac), stored
on the device: Talk engine (Realtime when the gateway offers it, else Hermes Voice: the footer
says which), Hermes's voice (the Bot voice picker for the gateway's own profile), Answer after
a pause of (Short/Normal/Long), Voice replies, Raise to Listen (iPhone), AirPods studio-quality
mic, Listen speed (1–2×), Code and tables (Describe them/Skip), Transcribe on (This iPhone, or
The Gateway for calls, §4.2), the transcription language, Hey Hermes (§4.6), and Sounds and
haptics.

**A Bot's voice** (`botVoicePicker`, `BotVoiceView`, `BotVoiceModel`; Edit Bot → Voice): read with
`GET /api/config?profile=` and saved with `PUT /api/config?profile=` (Hermes deep-merges the
partial config sent):

- Realtime: `voice.gpt_live.voice`, from Hermes's own list (marin, cedar, quartz, … bundled).
- Replies and voice messages: `tts.provider` (Hermes's built-in providers), that provider's
  voice key (`tts.openai.voice`, `tts.elevenlabs.voice_id`, `tts.edge.voice`, …) and
  `tts.speed`. OpenAI's voices are bundled, ElevenLabs' come from
  `GET /api/audio/elevenlabs/voices`, others are typed.
- Previews say one sentence straight from the provider, only when `GET /api/audio/voice-config`
  hands out client-direct settings (`openai-speech` or `elevenlabs-tts`, at the `base_url` it
  names); the key is used for that request only, through a session that never follows a
  redirect to another server. A Realtime voice previews with OpenAI's speech model. Without
  client-direct there are no preview buttons.

### 6.1 What the gateway has (setup)

Voice never hides because the gateway lacks something: it falls back, and says why
(`VoiceSetup`, the shared setup pattern in `docs/setup.md` §4.16). Settings → Voice & Audio and
Edit Bot → Voice show, per gateway and per Bot (Settings → Setup lists the gateway's three under
Voice & Audio, and counts them):

| Status | Ready | Partly set up (falls back) | How to fix |
|---|---|---|---|
| Talk (`voice.talk`) | Realtime and its voice | Hermes Voice in the gateway's voice when there's no Realtime (Hermes's reason, e.g. no OpenAI key); in this device's voice when the gateway can't speak either | Add the OpenAI key (in the app, `PUT /api/env`), or `hermes config set voice.gpt_live.api_key …` |
| Listen (`voice.listen`) | The provider and voice (`tts.provider`, `tts.<provider>.<voice key>`) | This device's voice: the provider has no key or sign-in, or it failed last time | Choose a provider and voice; add the provider's key; `hermes config set tts.provider edge` |
| Voice messages (`voice.messages`) | Transcribed on this device | When the device hears nothing the gateway transcribes (`stt.provider`); its key (or sign-in) may be missing | Add the key, or `hermes config set stt.provider local` |
| Transcribe on the gateway (`voice.transcription`, only while it's chosen) | The provider, "OpenAI, as you speak" (voice-config `stt.streaming`) | This device hears the call: the provider can't stream (only OpenAI, xAI and ElevenLabs can), its key is missing (a sign-in never streams), `stt.streaming` is off, or a call just failed | Add the key; Turn On (`PUT /api/config {stt: {streaming: true}}`); `hermes config set stt.provider openai`, `… stt.streaming true` |

Code: `VoiceSetup` (one per gateway, `VoiceSetup.of(workspace)`), `VoiceSetupRules` and
`VoiceFacts` in HermesKit, `VoiceSetupSections` and `VoiceKeySheet` (its sheet hangs off the
page's Form through `voiceSetup(_:profile:keyEntry:)`: on the sections it would repeat per row); the notes are `VoiceSetupNote`
on the Talk screen (when the gateway can't speak) and over Listen's mini player.

What's read: `GET /api/config?profile=` (providers and voices), `GET /api/env?profile=` (which keys
are set, by name only), `GET /api/audio/voice-live/status` (Realtime and why not),
`GET /api/audio/voice-config` (its verdicts: `direct` means the gateway has the provider's
credentials, whatever their source; its keys aren't read), `GET /api/providers/oauth` (sign-ins:
`xai-oauth` covers xAI's speech and whole-recording transcription, as Hermes's
`resolve_xai_http_credentials` falls back to it, but never live transcription, which is API key
only in `transcription_streaming`), and failures seen while speaking (the gateway's voice didn't
answer). A provider with a key, a direct verdict or a sign-in that covers it is never asked for a
key: an xAI gateway signed in to xAI Grok speaks through `speak-stream`/`POST /api/audio/speak` and
transcribes voice messages through `POST /api/audio/transcribe`. Keys typed in the app go straight to
`PUT /api/env` and are kept nowhere. Can't reach Bot Mode: "Can't check", with how to turn it on.
Steps name the `hermes` command (`hermes -p <bot> …` for a Bot) and link the Hermes docs
(`user-guide/features/tts`, `voice-mode`), with Check Again. A key Hermes refuses (400: a pinned
key, a name it won't take) shows Hermes's own sentence. Checked when a chat or call opens (at most
every ten minutes), on Check Again, and again whenever Talk or Listen falls back.

## 7. One audio coordinator

`AudioCoordinator` (an actor) owns the audio session and the engine (`AudioGraph`). Everything
else asks it for a role and gets an `AudioLease`, whose events say when to pause, carry on or
stop.

- **Roles, in priority order:** Talk > recording a voice message > Dictation > Listen > playing
  a voice message > Hey Hermes listening (§4.6).
- **A higher role pauses or stops a lower one** (`AudioRole.whenPreempted(by:)`):
  - Listen and playback pause for a recording or dictation, and carry on after; they stop when a
    call starts;
  - dictation stops for a recording or a call (its words stay);
  - a recording pauses for a call;
  - Hey Hermes pauses for everything, and listens again after.
- One output replaces another: Listen stops a voice message playing and the other way round.
- A lower role than a microphone role is refused (`busy`): no dictation during a call.
- No other code calls `setCategory` or `setActive`. The session is reconfigured once per role
  change (`AudioSessionProfile`), and released with `notifyOthersOnDeactivation` when nothing
  holds it.

| Role | Category / mode | Options | Voice processing |
|---|---|---|---|
| Talk | play and record / voice chat | Bluetooth HFP, speaker (or the earpiece), duck others | on |
| Recording | play and record / default | Bluetooth HFP (studio-quality AirPods when on), speaker, duck others | off |
| Dictation | play and record / measurement | Bluetooth HFP, speaker, duck others | off |
| Listen | playback / spoken audio | interrupt spoken audio and mix, duck others | off |
| Playback | playback / spoken audio (play and record at the ear) | duck others | off |
| Hey Hermes | play and record / default | mix with others, speaker | off |

**Handled in one place:**

- Interruptions (a phone call, Siri): the holder pauses. On 27 the session's
  `didBecomeInactive` (system source) and `resumptionRecommendation` notifications; on 26 the
  interruption notification. After an interruption the session is taken back before anything
  plays; a call carries on, Listen and playback only when the system recommends it.
- Route changes: the holder is told the new route; headphones coming out pause Listen and
  playback (Apple's rule).
- `AVAudioEngineConfigurationChange` (AirPods connecting): the engine restarts with the tap on
  the new input format and the holder reschedules what was playing.
- `mediaServicesWereReset`: a new engine, the session set up again, and the holder makes its
  players again (`AudioGraph.contains`); whoever listens to the microphone carries on, as the tap
  goes back on the new engine.
- `AVAudioApplication` input mute changes are passed on (AirPods stem).
- Every role change is logged (category `audio`, `AudioLogEntry`):
  `log show --last 1h --predicate 'subsystem == "co.caffeinatedcode.hermes" && category == "audio"'`.

**The engine** (`AudioGraph`): one microphone tap shared by everyone listening (a voice message
feeds its encoder, waveform and transcriber from the same buffers), player nodes through a
time-pitch unit (speed with the pitch kept) into the mixer, and voice processing switched only
when the role changes. On 27 the analyzer's input is converted by `AnalyzerInputConverter`.

## 8. Privacy and permissions

- The microphone is asked for on first use, in context, never at launch. On-device
  transcription (`SpeechAnalyzer`) needs no speech-recognition permission.
- Nothing said leaves the device until it's sent: transcription is on the device.
  - Realtime sends the call's audio to OpenAI (through the gateway's key); the first Realtime call
    says so.
- Replies spoken in the Bot's voice send the reply text to the gateway's speech provider.
- Calls keep text only (`CallRecord` holds counts and a summary).
- The client-direct keys from `voice-config` are kept in memory for the one request that needs
  them: `VoiceConfig` prints, dumps and reflects them as `<redacted>`, and they're never logged or
  stored.

## 10. Gateway mapping

All on the backend (`hermes serve`, `hermes_cli/web_routers/audio.py`); the API server has no
audio routes. REST takes the backend's session token or cookie; sockets take `?token=` or a
one-time `?ticket=`; a Bot is `?profile=`.

| Feature | Call |
|---|---|
| What's available | `GET /api/audio/voice-live/status`, `GET /api/audio/voice-config`, `GET /api/providers/oauth` (sign-ins) |
| Talk turn (Hermes Voice) | `prompt.submit {text, voice_turn: true, surface: "voice-live", voice_context, interrupted}` → `{status, user_row_id}` |
| The Bot's voice | `WS /api/audio/speak-stream?profile=` (one sentence a socket: `{text, done}`, `{stop}`), `POST /api/audio/speak`, `POST /api/audio/tts-lease` |
| Realtime | `POST /api/audio/voice-live/session {sdp, history}` + WebRTC to OpenAI; delegations as `prompt.submit {surface: "voice-live", voice_context}` |
| Steer while working, interrupt | `session.steer`, `session.interrupt` |
| Voices | `PUT /api/config?profile=`, `GET /api/audio/elevenlabs/voices` |
| Hey Hermes | `wake.status`, `wake.start {surface: "gui", client_capture: true, persist?}`, `wake.feed {pcm, sample_rate: 16000}`, `wake.resume`, `wake.stop`; event `wake.detected {phrase, profile, start_new_session}` |
| Talk's words from the gateway | `WS /api/audio/transcribe-stream?profile=` (one utterance a socket: `{sample_rate}`, int16 PCM, `{eos}` → `partial {text}`, `final {transcript}`, `error {message}`); `POST /api/audio/transcribe` for a turn it lost |
| Voice messages | `file.attach {session_id, data_url, name: "voice-<uuid>.m4a"}` → `{path, ref_text}`; `POST /api/audio/transcribe {data_url, mime_type}` when the device heard nothing |
| Playing gateway audio | `GET /api/files/stream?path=<absolute path>` (Range; 415 for non-media) |

## 11. Fixes made to the old Voice mode

- The speaker's queue count race is gone with `VoiceSpeaker`: sentences play from one queue on
  the engine (`SpokenPlayer`).
- The reply read is tied to its turn id; a message queued behind a finishing turn no longer
  re-reads the previous reply.
- Every reply in a call is read, not only the first: after a reply was heard to its end the
  player asked for the next sentence only near the start of its queue, so the next reply waited
  there unread.
- Mute stops only the microphone, and unmuting doesn't restart anything.
- Clarify questions are answered by voice; secrets, sudo and sign-ins ask to be typed.
- Dictation shows its failures (with Try Again) and the model download's progress.
- The Mac panel has Open Settings and Try Again; the iPad has no Earpiece control.
- Tests: `SpokenTextTests` (the cleaner), `SpokenAnswersTests` (approval phrases, clarify
  choices), `TurnTakingTests` (voice activity, endpointing), `TalkEarsTests` (barge-in and turns
  with noise, echo, backchannels and untimed words, a loud room, a voice Realtime answered),
  `NearGateTests` (what the transcriber hears over the Bot, Realtime's shorter lookahead),
  `AnalyzerClockTests` (word times across gaps in the microphone),
  `AudioCoordinatorTests` (role changes, interruptions, routes, resets), `SpokenReplyTests`,
  `SpokenQueueTests` (replies one after another in one queue).

## 12. Acceptance checks

- No two audio paths reconfigure the session at once: the coordinator's log shows one session
  change per role change.
- Noise never stops the Bot, and the person can: the Talk noise bench (below) has no false stops,
  and the Bot dips within about 150 ms of the person starting.
- "Stop" alone interrupts the Bot: it dips as the word starts and stops when the word is heard.
- The time from the end of speech to the first audio is in the log and the debug overlay: under
  1.2 s with Realtime and 2 s with Hermes Voice on a good connection.
- A clarify question can be answered by voice; a secret is never spoken.
- A call keeps going with the phone locked, after switching apps, through a phone call, and with
  AirPods connected or disconnected mid-call.
- Dictation works offline and shows a failure instead of doing nothing.
- A voice message recorded on the iPhone plays on the Mac (and the other way round), with its
  transcript; a Bot's `text_to_speech` reply plays as a strip.

**The Talk noise bench** (`Tools/talk-bench`, Mac only): a call in a noisy room, heard by the
Mac's own on-device transcriber in real time and decided by the old rule (voice activity) and by
`TalkEars` side by side, each in its own call. Speech is the Mac's voices (`make-clips.sh`, nothing
downloaded or committed); the rooms are synthesised at the microphone against the person at
−24 dBFS: a quiet room, a fan (−42), a street with cars and a horn (−46 to −30), a laptop keyboard,
music with a sung voice (−36, and −26 "loud"), a TV across the room (−40) and three people talking
(−45). The Bot's reply comes back through the room 35 dB down. Each room gets nothing, a stop
phrase, a sentence or a backchannel said over the Bot.

```sh
Tools/talk-bench/make-clips.sh build/talk-bench/clips
swift build -c release --package-path Tools/talk-bench --scratch-path build/talk-bench/.build
build/talk-bench/.build/release/talk-bench --clips build/talk-bench/clips   # --noise tv,fan --phrase stop --verbose
```

Measured 2026-10-21 (64 calls, `DictationTranscriber`):

| | Before (voice activity) | `TalkEars` |
|---|---|---|
| False stops (nothing or "mm-hm" said) | 17 of 24 | 0 of 24 |
| Stopped before the person spoke | 10 of 40 | 0 of 40 |
| Interruptions caught | 27 of 40 (10 of them by noise first) | 34 of 40 |
| Stop after the phrase ends | –740 ms median (noise, before the words) | 220 ms median, 830 ms worst |
| The Bot yields from the phrase's start | – | 130 ms median, 400 ms worst |
| Dips with nobody talking | – | 0 in 8 calls |
| First turn held open past the Bot's start by noise | 17 of 64 | 1 of 64 |

The misses are music as loud as the person (−26 against −24: no level tells them apart; tap to
interrupt) and one "hold on" under the TV. `SpeechTranscriber` with the same rule: no false stops,
35 of 40 caught, but 360 ms median and 1.9 s worst. Voice processing isn't in the loop (it runs
only on a live microphone), so the app's input is cleaner than the bench's.

Realtime's gate, measured through the loopback (`-HERMES_REALTIME_LOOPBACK`, simulator,
2026-10-22): a TV across the room arrived at about -41 dB while GPT-Live was quiet and -81 to
-83 dB while it spoke; a near voice said over it, -18 to -22 dB. For about a second at the start of
a burst the TV still came through while the person's level wasn't known yet (no turn heard).

From the call starting to Listening, on the mock in a simulator: 1.6–1.9 s with Hermes Voice
(0.4 s the audio session, about 1.1 s the speech framework's model check, which a simulator may
not time as a device does), 0.7 s when Realtime fails and Hermes Voice takes over.

**Hand checks on a real phone in a real room** (what the bench can't prove): Talk on the speaker
with a TV on, music playing, a fan, people talking nearby and typing on a laptop beside the phone;
the Bot keeps talking through all of it and dips at most briefly, and "stop" (said normally, from
arm's length) cuts it every time. Then the same with AirPods, and with the phone on the table a
metre away. The Bot never stops for its own voice at full volume on the speaker.

Checked on the mock in a simulator (`-HERMES_VOICE_INPUT` clips): a spoken turn goes with its
voice fields, an approval is asked aloud and answered by voice, the reply is read in the Bot's
gateway voice, "stop" cuts a long reply and the next turn says it was interrupted, a clarify
question is answered by "the second one", Realtime that can't connect falls back to Hermes
Voice, and a TV as loud as the person playing over a long reply (`loud-tv`, no words) neither
stops it nor makes a turn, and the call offers Voice Isolation. The mock's audio routes have their
own tests (`Tools/mock-hermes/tests`). Voice messages: hold to record and let go to send, lock then Pause into Review, play back
and send from there, slide left to cancel; a message sent while Hermes works waits in Up Next;
messages from elsewhere are fetched from `/api/files/stream` and drawn as bubbles; "send it as
audio" to a Bot plays its `text_to_speech` reply as a strip; VoiceOver's adjust (the accessibility
increment and decrement, sent as VoiceOver sends them) moves a playing voice message and a Bot's
audio 5 s forward and back.
