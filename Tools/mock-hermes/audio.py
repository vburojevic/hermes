"""Audio for the combined mock (`docs/voice.md` §10): the /api/audio/* routes, the speak-stream and
transcribe-stream sockets, /api/files/stream, and the voice fields of prompt.submit.

Shaped like `hermes serve` (hermes_cli/web_routers/audio.py, tools/voice_live.py,
tools/voice_client_config.py, tools/tts_streaming.py):
  - GET /api/audio/voice-live/status: {ok, mode, available, reason, model, voice}; chained unless
    Realtime is switched on ("no OpenAI API key (…)" when it's gpt-live without a key).
  - GET /api/audio/voice-config: Hermes's verdict for the profile's providers
    (tools/voice_client_config.py): relay with its reason ("local provider", "no credentials",
    "provider 'edge' has no client wire", "xai oauth (server-managed) or no credentials"), or
    direct for a provider with a key and a wire, pointing at this mock with a fake key
    ("mock-key-not-real"), never a real one. "direct" hands out OpenAI's whatever is configured.
  - POST /api/audio/voice-live/session {sdp, history}: 400 without an offer, 503 without a key,
    else a fake SDP answer (WebRTC can't connect to it: Talk falls back to Hermes Voice).
  - WS /api/audio/speak-stream: {"text"}/{"done"}/{"stop"} in; {"type":"start","sample_rate":24000,
    "channels":1}, little-endian int16 PCM frames (not sample-aligned, like real providers'
    chunks) and {"type":"end"} out; {"type":"fallback"} when switched to fallback.
    The audio is speech-like (syllables of a voiced tone), about 65 ms per character.
  - POST /api/audio/speak {text} → {ok, data_url: data:audio/wav;base64,…, mime_type, provider};
    400 with Hermes's words when the provider has no credentials ("TTS configuration error (xai):
    No xAI credentials found. …"), and speak-stream answers {"type":"fallback"} then.
  - POST /api/audio/tts-lease, /api/audio/stt-lease {lease, active}.
  - POST /api/audio/transcribe {data_url}: the transcript set with the switch (Talk's fallback for
    a turn the live socket lost, and a voice message the device heard no words in), after
    "transcribe_delay" seconds; "" is no speech heard, as Hermes answers it. "transcribe_refusal"
    answers 400 with those words instead, and a provider without credentials gets Hermes's own
    "No STT provider available. …".
  - WS /api/audio/transcribe-stream, as Hermes's transcription_streaming: {"sample_rate": N} first
    (else it closes without a word), then int16 mono PCM, {"partial", text} with everything heard
    so far, and {"eos": true} → {"final", transcript, provider} and a close. Live only with the
    "stt_streaming" switch, or stt.streaming on with OpenAI, xAI or ElevenLabs and its key (PUT
    /api/env), like Hermes; otherwise {"error", "no live STT for the configured provider"}.
    {"stt_live_fail": "…"} answers eos with that error instead (a provider that dropped).
  - GET /api/audio/elevenlabs/voices: {available, voices: [{voice_id, name, label}]}.
  - GET|HEAD /api/files/stream?path=: files attached with file.attach (voice messages) and the
    seeded Bot audio, with Range; 415 "Unsupported media type" for other extensions.
  - prompt.submit keeps voice_turn, surface, voice_context and interrupted, and answers
    user_row_id. GET /api/mock/audio/turns lists them, and what speak-stream was asked to say.

Listen to the brief: POST /api/mock/audio/brief delivers Research Buddy's "Morning brief" routine
into its Bot Chat now, its output a stack (the stack-1 example) as the widgets plugin writes it
in: an inline ```widget block.

Hey Hermes (`docs/voice.md` §4.6), as Hermes's tui_gateway/methods_voice.py: wake.status,
wake.start {surface, client_capture, persist}, wake.stop, wake.pause, wake.resume and wake.feed
{pcm (base64 16 kHz int16), sample_rate}; refusals are results ({started: false, reason}), bad feeds
error 4001. The engine "hears" the wake word after `detect_after` seconds of fed audio and
broadcasts wake.detected {phrase, profile, start_new_session}, then waits for wake.resume. Switches:
POST /api/mock/wake {available, hint, enabled, capture: "client"|"local", other_owner, surface,
detect_after, profile}; GET /api/mock/wake shows the state and counts.

Scenario: ask a Bot for something "as audio" (or a "voice note") and it answers with a voice
message from text_to_speech: `[[audio_as_voice]]`, then `MEDIA:<path>`, then the words.

Setup (`docs/voice.md` §6.1): GET /api/env lists the voice keys (is_set, a redacted preview);
{"env_refusal": "…"} makes PUT /api/env refuse with that 400, as Hermes does for a pinned key.
{"xai_oauth": true} signs the gateway in to xAI Grok (GET /api/providers/oauth lists `xai-oauth`
logged in): xAI then speaks and transcribes whole recordings with no XAI_API_KEY, as Hermes's
resolve_xai_http_credentials does, but never transcribes as you speak (API key only).

Switches: POST /api/mock/audio {"realtime": bool, "key": bool, "tts": "stream" | "fallback"
| "broken" | "slow", "direct": bool, "elevenlabs": bool, "stt_streaming": bool, "transcript": str,
"transcribe_delay": seconds, "transcribe_refusal": str | null, "xai_oauth": bool};
POST /api/mock/audio/reset.

Voices: GET/PUT /api/config keep each Bot's `tts` and `voice` sections. With "direct" on,
voice-config points the client at this mock's /mock-provider/openai/v1 (or elevenlabs/v1 when
that's the Bot's provider), which answers previews with a WAV and lists them in
GET /api/mock/audio/turns ("previews"): nothing reaches a real provider.
"""

import base64
import io
import json
import math
import random
import struct
import threading
import time
import uuid
import wave

B = None  # backend.py's module globals
G = None  # server.py
C = None  # chats.py

LOCK = threading.RLock()
STATE = {}
FILES = {}       # path -> bytes: what file.attach staged
TURNS = []       # the voice fields of each prompt.submit
LIVE = []        # each transcribe-stream turn: sample_rate, bytes, and how it ended
WHOLE = []       # each POST /api/audio/transcribe
SPOKEN = []      # what speak-stream was asked to say, in order
LEASES = {}      # lease -> active
PROFILE_CONFIG = {}  # profile -> {"tts": {...}, "voice": {...}}: what PUT /api/config saved
PREVIEWS = []    # voice previews asked of the mock provider
ENV_SET = {}     # profile -> voice keys PUT /api/env set (values stay in connections.py)
RATE = 24000
MEDIA_EXTENSIONS = (".avi", ".flac", ".m4a", ".mkv", ".mov", ".mp3", ".mp4", ".ogg", ".opus", ".wav", ".webm")
GPT_LIVE_VOICES = ["marin", "cedar", "quartz", "ripple", "vesper", "willow", "stone", "gleam",
                   "meridian", "bossa", "tempo", "beacon", "delta", "cinder"]


def reset():
    with LOCK:
        STATE.clear()
        STATE.update({"realtime": False, "key": True, "tts": "stream", "direct": False, "elevenlabs": True, "xai_oauth": False,
                      "stt_streaming": False, "transcript": "", "env_refusal": None, "stt_live_fail": None,
                      "transcribe_delay": 0.0, "transcribe_refusal": None})
        TURNS.clear()
        LIVE.clear()
        WHOLE.clear()
        SPOKEN.clear()
        LEASES.clear()
        PROFILE_CONFIG.clear()
        PREVIEWS.clear()
        FILES.clear()
        ENV_SET.clear()
    # Defined further down: at import it starts on its own.
    if "reset_wake" in globals():
        reset_wake()


reset()


# ---------------------------------------------------------------- speech-like audio


def speechlike(text, rate=RATE):
    """int16 little-endian mono: a voiced tone shaped into syllables, about 65 ms a character."""
    rng = random.Random(len(text))
    seconds = max(0.6, 0.065 * len(text))
    count = int(seconds * rate)
    out = bytearray()
    base = 125 + rng.random() * 40
    syllable = 0.0
    for i in range(count):
        t = i / rate
        # Syllables at about 5 a second, a short gap after each word's worth.
        phase = (t * 5.2) % 1.0
        envelope = math.sin(math.pi * phase) ** 2 if phase < 0.82 else 0.0
        if int(t * 1.6) % 4 == 3 and (t * 1.6) % 1 > 0.7:
            envelope = 0.0
        f = base * (1 + 0.06 * math.sin(2 * math.pi * 0.7 * t))
        syllable += 2 * math.pi * f / rate
        sample = (0.55 * math.sin(syllable) + 0.25 * math.sin(2 * syllable) + 0.12 * math.sin(3 * syllable)
                  + 0.04 * (rng.random() - 0.5))
        out += struct.pack("<h", int(max(-1, min(1, sample * envelope * 0.6)) * 32767))
    return bytes(out)


def wav_bytes(pcm, rate=RATE):
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(pcm)
    return buffer.getvalue()


# ---------------------------------------------------------------- REST


def profile_or_404(query, body=None):
    """None when the profile is fine, else the 404 Hermes answers for an unknown one."""
    named = (body or {}).get("profile") if isinstance(body, dict) else None
    named = named or (query or {}).get("profile", [None])[0]
    if not named or named == "current":
        return None
    if named not in B["PROFILES"]:
        return 404, {"detail": f"Profile '{named}' does not exist."}
    return None


def voice_live_status(query, body):
    refusal = profile_or_404(query)
    if refusal:
        return refusal
    with LOCK:
        live = STATE["realtime"]
        key = STATE["key"]
    if not live:
        return 200, {"ok": True, "mode": "chained", "available": True, "reason": None, "model": "gpt-live-1", "voice": "marin"}
    return 200, {"ok": True, "mode": "gpt-live", "available": key,
                 "reason": None if key else "no OpenAI API key (set OPENAI_API_KEY or voice.gpt_live.api_key)",
                 "model": "gpt-live-1", "voice": "marin"}


LIVE_STT_KEYS = {"openai": ("OPENAI_API_KEY", "VOICE_TOOLS_OPENAI_KEY"), "xai": ("XAI_API_KEY",),
                 "elevenlabs": ("ELEVENLABS_API_KEY",)}


def live_stt(profile):
    """Whether transcribe-stream works for the profile, as Hermes decides it (call with LOCK held)."""
    if STATE["stt_streaming"]:
        return True
    stt = (PROFILE_CONFIG.get(profile, {}).get("stt") or {})
    keys = LIVE_STT_KEYS.get(stt.get("provider", "local"), ())
    return bool(stt.get("streaming")) and any(key in ENV_SET.get(profile, set()) for key in keys)


# The keys each provider takes (tools/tts_tool.py, tools/transcription_tools.py), and the ones
# voice-config can hand out (its client wires).
TTS_KEYS = {"openai": ("OPENAI_API_KEY", "VOICE_TOOLS_OPENAI_KEY"), "elevenlabs": ("ELEVENLABS_API_KEY",),
            "gemini": ("GEMINI_API_KEY", "GOOGLE_API_KEY"), "xai": ("XAI_API_KEY",),
            "minimax": ("MINIMAX_API_KEY", "MINIMAX_CN_API_KEY"), "mistral": ("MISTRAL_API_KEY",),
            "deepinfra": ("DEEPINFRA_API_KEY",)}
STT_KEYS = {"openai": ("OPENAI_API_KEY", "VOICE_TOOLS_OPENAI_KEY"), "groq": ("GROQ_API_KEY",),
            "mistral": ("MISTRAL_API_KEY",), "xai": ("XAI_API_KEY",), "elevenlabs": ("ELEVENLABS_API_KEY",),
            "deepinfra": ("DEEPINFRA_API_KEY",)}
TTS_WIRES = {"openai": "openai-speech", "elevenlabs": "elevenlabs-tts", "deepinfra": "openai-speech"}
STT_WIRES = {"openai": "openai-multipart", "groq": "openai-multipart", "mistral": "openai-multipart",
             "xai": "xai-stt", "elevenlabs": "elevenlabs-stt", "deepinfra": "openai-multipart"}


def providers(profile):
    """The profile's (tts, stt) providers, as GET /api/config shows them (call with LOCK held)."""
    saved = PROFILE_CONFIG.get(profile, {})
    return ((saved.get("tts") or {}).get("provider", "edge"), (saved.get("stt") or {}).get("provider", "local"))


def has_key(profile, keys):
    return any(key in ENV_SET.get(profile, set()) for key in keys)


def can_speak(profile):
    """Whether text_to_speech has credentials: xAI takes the xAI Grok sign-in in place of its key
    (resolve_xai_http_credentials). Call with LOCK held."""
    provider, _ = providers(profile)
    keys = TTS_KEYS.get(provider)
    return not keys or has_key(profile, keys) or (provider == "xai" and STATE["xai_oauth"])


def can_transcribe(profile):
    """Whether transcribe_recording has a provider: the same sign-in rule (_has_xai_stt_credentials)."""
    _, provider = providers(profile)
    keys = STT_KEYS.get(provider)
    return not keys or has_key(profile, keys) or (provider == "xai" and STATE["xai_oauth"])


def speech_refusal(profile):
    """text_to_speech's error for a provider without credentials (call with LOCK held)."""
    provider, _ = providers(profile)
    if provider == "xai":
        return "TTS configuration error (xai): No xAI credentials found. Configure xAI OAuth in `hermes model` or set XAI_API_KEY."
    return f"TTS configuration error ({provider}): {TTS_KEYS[provider][0]} not set"


NO_STT = ("No STT provider available. Install faster-whisper for free local transcription, configure "
          "HERMES_LOCAL_STT_COMMAND or install a local whisper CLI, set GROQ_API_KEY for free Groq Whisper, set "
          "MISTRAL_API_KEY for Mistral Voxtral Transcribe, configure xAI OAuth or set XAI_API_KEY for xAI Grok STT, "
          "set ELEVENLABS_API_KEY for ElevenLabs Scribe, or set VOICE_TOOLS_OPENAI_KEY or OPENAI_API_KEY for the "
          "OpenAI Whisper API.")


def resolved_verdicts(profile, base):
    """voice-config as Hermes resolves it with voice.client_direct on, its default (call with LOCK
    held): direct only for a provider with its own key and a wire the client speaks."""
    tts_provider, stt_provider = providers(profile)
    if tts_provider not in TTS_WIRES:
        tts = {"mode": "relay", "reason": f"provider {tts_provider!r} has no client wire"}
    elif not has_key(profile, TTS_KEYS[tts_provider]):
        tts = ({"mode": "relay", "reason": "openai resolution failed: no OpenAI API key or managed gateway"}
               if tts_provider == "openai" else {"mode": "relay", "reason": "no credentials"})
    elif tts_provider == "elevenlabs":
        tts = {"mode": "direct", "wire": "elevenlabs-tts", "provider": "elevenlabs", "base_url": f"{base}/elevenlabs/v1",
               "api_key": "mock-key-not-real", "model": "eleven_multilingual_v2", "voice": "pNInz6obpgDQGcFmaJgB"}
    else:
        tts = {"mode": "direct", "wire": "openai-speech", "provider": tts_provider, "base_url": f"{base}/openai/v1",
               "api_key": "mock-key-not-real", "model": "gpt-4o-mini-tts", "voice": "alloy", "speed": 1.0}
    if stt_provider in ("local", "local_command"):
        stt = {"mode": "relay", "reason": "local provider"}
    elif stt_provider not in STT_WIRES:
        stt = {"mode": "relay", "reason": "command/plugin provider"}
    elif not has_key(profile, STT_KEYS[stt_provider]):
        # xAI: API key only, so a sign-in reads the same as nothing at all.
        reason = {"xai": "xai oauth (server-managed) or no credentials",
                  "openai": "openai resolution failed: no OpenAI API key or managed gateway"}.get(stt_provider, "no credentials")
        stt = {"mode": "relay", "reason": reason}
    else:
        stt = {"mode": "direct", "wire": STT_WIRES[stt_provider], "provider": stt_provider,
               "base_url": f"{base}/{stt_provider}/v1", "api_key": "mock-key-not-real", "model": "mock-transcribe"}
    return stt, tts


def voice_config(query, body):
    refusal = profile_or_404(query)
    if refusal:
        return refusal
    # The "provider" is this mock (/mock-provider/…): previews never reach a real one.
    base = f"http://127.0.0.1:{B['CONFIG']['port']}/mock-provider"
    profile = profile_name(query)
    with LOCK:
        direct = STATE["direct"]
        streaming = live_stt(profile)
        if not direct:
            stt, tts = resolved_verdicts(profile, base)
    if not direct:
        return 200, {"ok": True, "stt": dict(stt, streaming=streaming), "tts": tts}
    tts_provider = (PROFILE_CONFIG.get(profile_name(query), {}).get("tts") or {}).get("provider", "openai")
    tts = ({"mode": "direct", "wire": "elevenlabs-tts", "provider": "elevenlabs", "base_url": f"{base}/elevenlabs/v1",
            "api_key": "mock-key-not-real", "model": "eleven_multilingual_v2", "voice": "pNInz6obpgDQGcFmaJgB"}
           if tts_provider == "elevenlabs" else
           {"mode": "direct", "wire": "openai-speech", "provider": "openai", "base_url": f"{base}/openai/v1",
            "api_key": "mock-key-not-real", "model": "gpt-4o-mini-tts", "voice": "alloy", "speed": 1.0})
    return 200, {"ok": True,
                 "stt": {"mode": "direct", "wire": "openai-multipart", "provider": "openai", "base_url": f"{base}/openai/v1",
                         "api_key": "mock-key-not-real", "model": "gpt-4o-mini-transcribe", "streaming": streaming},
                 "tts": tts}


def voice_live_session(query, body):
    refusal = profile_or_404(query, body)
    if refusal:
        return refusal
    if not str((body or {}).get("sdp") or "").strip():
        return 400, {"detail": "An SDP offer is required"}
    with LOCK:
        key = STATE["key"]
    if not key:
        return 503, {"detail": "GPT-Live needs an OpenAI API key (OPENAI_API_KEY or voice.gpt_live.api_key)"}
    answer = ("v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\na=group:BUNDLE 0 1\r\n"
              "m=audio 9 UDP/TLS/RTP/SAVPF 111\r\nc=IN IP4 0.0.0.0\r\na=mid:0\r\na=recvonly\r\n"
              "a=ice-ufrag:mock\r\na=ice-pwd:mockmockmockmockmockmock\r\n"
              "a=fingerprint:sha-256 00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00\r\n"
              "a=setup:active\r\na=rtpmap:111 opus/48000/2\r\n"
              "m=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\nc=IN IP4 0.0.0.0\r\na=mid:1\r\na=sctp-port:5000\r\n")
    return 200, {"ok": True, "session": {"id": f"sess_mock_{uuid.uuid4().hex[:8]}"}, "transport": {"type": "webrtc", "sdp": answer}}


def speak(query, body):
    refusal = profile_or_404(query, body)
    if refusal:
        return refusal
    text = str((body or {}).get("text") or "").strip()
    if not text:
        return 400, {"detail": "Text is required"}
    profile = profile_name(query, body)
    with LOCK:
        broken = STATE["tts"] == "broken"
        refusal = None if can_speak(profile) else speech_refusal(profile)
        provider, _ = providers(profile)
    if broken:
        return 500, {"detail": "Speech synthesis failed"}
    if refusal:
        return 400, {"detail": refusal}
    data = wav_bytes(speechlike(text))
    return 200, {"ok": True, "data_url": "data:audio/wav;base64," + base64.b64encode(data).decode(),
                 "mime_type": "audio/wav", "provider": provider}


def lease(kind):
    def route(query, body):
        name = str((body or {}).get("lease") or "").strip()
        if not name:
            return 400, {"detail": "lease is required"}
        active = bool((body or {}).get("active"))
        with LOCK:
            if active:
                LEASES[f"{kind}:{name}"] = True
            else:
                LEASES.pop(f"{kind}:{name}", None)
            count = len([k for k in LEASES if k.startswith(kind + ":")])
        result = {"ok": True, "lease": name, "active": active, "leases": count, "action": "loaded" if active else "noop", "provider": "edge"}
        if kind == "stt":
            result["warmed"] = active
        return 200, result
    return route


def transcribe(query, body):
    url = str((body or {}).get("data_url") or "")
    if not url.startswith("data:"):
        return 400, {"detail": "Invalid audio payload"}
    profile = profile_name(query, body)
    with LOCK:
        transcript = STATE["transcript"]
        delay = STATE["transcribe_delay"]
        refusal = STATE["transcribe_refusal"] or (None if can_transcribe(profile) else NO_STT)
        _, provider = providers(profile)
        WHOLE.append({"mime_type": url[5:url.find(";")] if ";" in url else "", "transcript": transcript})
    if delay:
        time.sleep(delay)
    if refusal:
        return 400, {"detail": refusal}
    return 200, {"ok": True, "transcript": transcript, "provider": provider}


def elevenlabs_voices(query, body):
    with LOCK:
        available = STATE["elevenlabs"]
    if not available:
        return 200, {"available": False, "voices": []}
    voices = [("pNInz6obpgDQGcFmaJgB", "Adam", "premade"), ("21m00Tcm4TlvDq8ikWAM", "Rachel", "premade"),
              ("EXAVITQu4vr4xnSDxMaL", "Bella", "premade"), ("ErXwobaYiN019PkySvjV", "Antoni", "premade")]
    rows = [{"voice_id": v, "name": n, "label": f"{n} ({c})"} for v, n, c in voices]
    return 200, {"available": True, "voices": sorted(rows, key=lambda r: r["label"])}


def mock_switch(query, body):
    with LOCK:
        for key in ("realtime", "key", "direct", "elevenlabs", "stt_streaming", "xai_oauth"):
            if key in (body or {}):
                STATE[key] = bool(body[key])
        if (body or {}).get("tts") in ("stream", "fallback", "broken", "slow"):
            STATE["tts"] = body["tts"]
        if "transcript" in (body or {}):
            STATE["transcript"] = str(body["transcript"])
        if "env_refusal" in (body or {}):
            STATE["env_refusal"] = body["env_refusal"] or None
        if "stt_live_fail" in (body or {}):
            STATE["stt_live_fail"] = body["stt_live_fail"] or None
        if "transcribe_delay" in (body or {}):
            STATE["transcribe_delay"] = max(0.0, float(body["transcribe_delay"] or 0))
        if "transcribe_refusal" in (body or {}):
            STATE["transcribe_refusal"] = body["transcribe_refusal"] or None
        return 200, dict(STATE)


def deliver_brief(query, body):
    """A scheduled report arrives: the routine's output is a stack in an inline block."""
    widgets = B.get("MOCK_WIDGETS")
    if widgets is None:
        return 404, {"detail": "the mock runs without a gateway"}
    _, raw = widgets.examples("stack")[0]
    payload, _ = widgets.prepare(raw)
    payload["id"] = widgets.unused_id()
    payload["rev"] = 1
    payload = widgets.order(payload)
    output = "Here's your morning.\n\n" + widgets.inline_block(payload)
    B["deliver_routine"]("researcher", "Morning brief", output, "Your **morning brief** is in: a light day, two meetings.")
    return 200, {"ok": True, "id": payload["id"]}


# ---------------------------------------------------------------- wake word

WAKE = {}


def reset_wake():
    WAKE.clear()
    WAKE.update({"available": True, "hint": None, "enabled": False, "capture": "client", "other_owner": None,
                 "surface": "auto", "detect_after": None, "profile": None, "owner": None, "paused": False,
                 "fed_bytes": 0, "feeds": 0, "detections": 0, "resumes": 0, "persisted": []})


reset_wake()


def wake_status(params):
    with LOCK:
        owner = WAKE["owner"] or WAKE["other_owner"]
        return {"listening": owner is not None, "owned_by_caller": WAKE["owner"] == "gui", "owner_surface": owner,
                "phrase": "hey hermes", "provider": "openwakeword", "configured_surface": WAKE["surface"],
                "available": WAKE["available"], "hint": WAKE["hint"], "enabled": WAKE["enabled"], "audio_silent": False,
                "capture": WAKE["capture"], "local_input_available": WAKE["capture"] == "local",
                "input_device": {"selector": None, "name": None, "error": None}, "sample_rate": 16000, "frame_length": 1280}


def wake_start(params):
    with LOCK:
        if not WAKE["available"]:
            return {"started": False, "reason": "unavailable", "hint": WAKE["hint"], "capture": WAKE["capture"]}
        if params.get("persist"):
            WAKE["enabled"] = True
            WAKE["persisted"].append(True)
        if not WAKE["enabled"]:
            return {"started": False, "reason": "disabled", "enabled_persisted": False}
        if WAKE["surface"] not in ("auto", "gui", "desktop"):
            return {"started": False, "reason": "disabled_for_surface"}
        if WAKE["other_owner"]:
            return {"started": False, "reason": "owned", "owner_surface": WAKE["other_owner"]}
        WAKE["owner"], WAKE["paused"], WAKE["fed_bytes"] = "gui", False, 0
        return {"started": True, "phrase": "hey hermes", "provider": "openwakeword", "owner_surface": "gui",
                "enabled_persisted": bool(params.get("persist")), "capture": WAKE["capture"],
                "sample_rate": 16000, "frame_length": 1280}


def wake_stop(params):
    with LOCK:
        mine = WAKE["owner"] == "gui"
        WAKE["owner"] = None
        if params.get("persist"):
            WAKE["enabled"] = False
            WAKE["persisted"].append(False)
        return {"stopped": mine, "disabled_persisted": bool(params.get("persist")), "reason": None if mine else "not_owner"}


def wake_pause(params):
    with LOCK:
        WAKE["paused"] = True
        return {"paused": True, "reason": None}


def wake_resume(params):
    with LOCK:
        WAKE["paused"], WAKE["fed_bytes"] = False, 0
        WAKE["resumes"] += 1
        return {"resumed": True, "reason": None}


def wake_feed(params):
    raw = params.get("pcm") or params.get("pcm_b64")
    if not isinstance(raw, str) or not raw:
        raise B["RPCError"](4001, "wake.feed requires base64 pcm")
    try:
        pcm = base64.b64decode(raw, validate=True)
    except ValueError as error:
        raise B["RPCError"](4001, f"invalid base64 pcm: {error}")
    if len(pcm) > 64000:
        raise B["RPCError"](4001, "pcm frame too large")
    if params.get("sample_rate") not in (None, 0, 16000):
        raise B["RPCError"](4001, "wake.feed only accepts 16 kHz PCM")
    detection = None
    with LOCK:
        if WAKE["owner"] != "gui" or WAKE["capture"] == "local":
            return {"fed": False, "reason": "not_owner"}
        if not pcm:
            return {"fed": False, "reason": "empty"}
        WAKE["feeds"] += 1
        if WAKE["paused"]:
            return {"fed": True, "reason": None}
        WAKE["fed_bytes"] += len(pcm)
        after = WAKE["detect_after"]
        if after is not None and WAKE["fed_bytes"] >= after * 32000:
            # Hermes pauses the detector before it says so, until wake.resume.
            WAKE["paused"], WAKE["fed_bytes"] = True, 0
            WAKE["detections"] += 1
            detection = {"phrase": "hey hermes", "profile": WAKE["profile"], "start_new_session": True}
    if detection:
        frame = {"jsonrpc": "2.0", "method": "event", "params": {"type": "wake.detected", "session_id": "", "payload": detection}}
        with B["LOCK"]:
            peers = list(B["CLIENTS"])
        for peer in peers:
            try:
                peer.send(frame)
            except OSError:
                pass
    return {"fed": True, "reason": None}


def wake_switch(query, body):
    with LOCK:
        for key in ("available", "enabled"):
            if key in (body or {}):
                WAKE[key] = bool(body[key])
        for key in ("hint", "other_owner", "profile"):
            if key in (body or {}):
                WAKE[key] = body[key] or None
        if (body or {}).get("capture") in ("client", "local"):
            WAKE["capture"] = body["capture"]
        if "surface" in (body or {}):
            WAKE["surface"] = body["surface"] or "auto"
        if "detect_after" in (body or {}):
            WAKE["detect_after"] = None if body["detect_after"] is None else float(body["detect_after"])
        return 200, dict(WAKE)


def wake_state(query, body):
    with LOCK:
        return 200, dict(WAKE)


def mock_turns(query, body):
    with LOCK:
        return 200, {"turns": list(TURNS), "spoken": list(SPOKEN), "previews": list(PREVIEWS),
                     "files": sorted(FILES), "live": list(LIVE), "whole": list(WHOLE)}


# ---------------------------------------------------------------- files


def files_stream(handler, query, head=False):
    path = (query.get("path") or [""])[0]
    if not path.startswith("/") or ".." in path.split("/"):
        return handler.send_json(400, {"detail": "Path must be absolute"})
    if not path.lower().endswith(MEDIA_EXTENSIONS):
        return handler.send_json(415, {"detail": "Unsupported media type"})
    with LOCK:
        data = FILES.get(path)
    if data is None:
        return handler.send_json(404, {"detail": "File not found"})
    content_type = {"m4a": "audio/mp4", "mp3": "audio/mpeg", "wav": "audio/wav", "ogg": "audio/ogg"}.get(path.rsplit(".", 1)[-1].lower(), "application/octet-stream")
    start, end, status = 0, len(data) - 1, 200
    ranged = handler.headers.get("Range") or ""
    if ranged.startswith("bytes="):
        first, _, last = ranged[6:].partition("-")
        start = int(first) if first else max(0, len(data) - int(last or 0))
        end = min(len(data) - 1, int(last)) if first and last else len(data) - 1
        status = 206
    chunk = data[start:end + 1]
    handler.send_response(status)
    handler.send_header("Content-Type", content_type)
    handler.send_header("Accept-Ranges", "bytes")
    handler.send_header("Content-Disposition", "inline")
    handler.send_header("X-Content-Type-Options", "nosniff")
    if status == 206:
        handler.send_header("Content-Range", f"bytes {start}-{end}/{len(data)}")
    handler.send_header("Content-Length", str(len(chunk)))
    handler.end_headers()
    if not head:
        handler.wfile.write(chunk)


def add_file(path, data):
    with LOCK:
        FILES[path] = data


# ---------------------------------------------------------------- sockets


def send_binary(peer, data):
    header = bytearray([0x82])
    if len(data) < 126:
        header.append(len(data))
    elif len(data) < 65536:
        header += bytes([126]) + struct.pack(">H", len(data))
    else:
        header += bytes([127]) + struct.pack(">Q", len(data))
    with peer.write_lock:
        if not peer.alive:
            return
        try:
            peer.handler.wfile.write(bytes(header) + data)
            peer.handler.wfile.flush()
        except (OSError, ValueError):
            peer.alive = False


def speak_stream(handler, query):
    peer = B["accept_socket"](handler, query)
    if peer is None:
        return
    refusal = profile_or_404(query)
    if refusal:
        return peer.close(4404, refusal[1]["detail"])
    stop = threading.Event()
    texts = []
    done = threading.Event()
    arrived = threading.Condition()

    def reader():
        while peer.alive:
            message = peer.recv()
            if message is None:
                stop.set()
                break
            try:
                frame = json.loads(message)
            except ValueError:
                stop.set()   # anything that isn't JSON counts as barge-in, as in Hermes
                break
            with arrived:
                if frame.get("stop"):
                    stop.set()
                if frame.get("text"):
                    texts.append(str(frame["text"]))
                if frame.get("done"):
                    done.set()
                arrived.notify_all()
            if stop.is_set():
                break
        with arrived:
            arrived.notify_all()

    threading.Thread(target=reader, daemon=True).start()
    with LOCK:
        mode = STATE["tts"]
        # No credentials: Hermes's sentence synthesis fails and produced nothing.
        if not can_speak(profile_name(query)):
            mode = "fallback"
    started = False
    while peer.alive and not stop.is_set():
        with arrived:
            while not texts and not done.is_set() and not stop.is_set() and peer.alive:
                arrived.wait(0.5)
            pending = list(texts)
            texts.clear()
        if mode in ("fallback", "broken") and (pending or done.is_set()):
            peer.send({"type": "fallback"})
            break
        for text in pending:
            with LOCK:
                SPOKEN.append({"text": text, "profile": (query.get("profile") or [None])[0], "at": time.time()})
            pcm = speechlike(text)
            if not started:
                time.sleep(0.25 if mode != "slow" else 2.5)   # time to first audio
                peer.send({"type": "start", "sample_rate": RATE, "channels": 1})
                started = True
            # Provider-sized chunks, not sample-aligned.
            offset = 0
            while offset < len(pcm) and not stop.is_set() and peer.alive:
                size = 4801 if (offset // 4801) % 3 == 0 else 4800
                send_binary(peer, pcm[offset:offset + size])
                offset += size
                time.sleep(0.02)
        if done.is_set() and not texts:
            if not started:
                peer.send({"type": "start", "sample_rate": RATE, "channels": 1})
            peer.send({"type": "end"})
            break
    peer.close(1000, "")


def transcribe_stream(handler, query):
    peer = B["accept_socket"](handler, query)
    if peer is None:
        return
    with LOCK:
        streaming = live_stt(profile_name(query))
        transcript = STATE["transcript"]
        failure = STATE["stt_live_fail"]
    if not streaming:
        peer.send({"type": "error", "message": "no live STT for the configured provider"})
        return peer.close(1000, "")
    # The first frame says the rate; anything else ends the session without a word, as Hermes.
    first = peer.recv()
    try:
        rate = int(json.loads(first).get("sample_rate"))
        if not 8000 <= rate <= 48000:
            raise ValueError
    except (TypeError, ValueError, AttributeError):
        return peer.close(1000, "")
    turn = {"sample_rate": rate, "bytes": 0, "ended": "cancelled"}
    with LOCK:
        LIVE.append(turn)
    words, shown = transcript.split(), ""
    while peer.alive:
        message = peer.recv(binary=True)
        if message is None:
            return
        if isinstance(message, (bytes, bytearray)):
            with LOCK:
                turn["bytes"] += len(message)
            # About one word per 0.4 s heard, all of them so far each time, only when it changes.
            heard = " ".join(words[:min(len(words), int(turn["bytes"] / (rate * 2) / 0.4) + 1)])
            if heard != shown:
                shown = heard
                peer.send({"type": "partial", "text": heard})
            continue
        try:
            frame = json.loads(message)
        except ValueError:
            return peer.close(1000, "")
        if isinstance(frame, dict) and frame.get("eos"):
            with LOCK:
                turn["ended"] = "failed" if failure else "final"
            if failure:
                peer.send({"type": "error", "message": failure})
            else:
                peer.send({"type": "final", "transcript": transcript, "provider": "openai"})
            return peer.close(1000, "")


# ---------------------------------------------------------------- install


def install(backend_globals, gateway_module, chats_module):
    global B, G, C
    B, G, C = backend_globals, gateway_module, chats_module
    routes = B["HTTP_ROUTES"]
    routes[("GET", "/api/audio/voice-live/status")] = voice_live_status
    routes[("GET", "/api/audio/voice-config")] = voice_config
    routes[("POST", "/api/audio/voice-live/session")] = voice_live_session
    routes[("POST", "/api/audio/speak")] = speak
    routes[("POST", "/api/audio/tts-lease")] = lease("tts")
    routes[("POST", "/api/audio/stt-lease")] = lease("stt")
    routes[("POST", "/api/audio/transcribe")] = transcribe
    routes[("GET", "/api/audio/elevenlabs/voices")] = elevenlabs_voices
    routes[("GET", "/api/mock/audio/turns")] = mock_turns
    routes[("POST", "/api/mock/audio/brief")] = deliver_brief
    routes[("POST", "/api/mock/wake")] = wake_switch
    routes[("GET", "/api/mock/wake")] = wake_state
    methods = B["METHODS"]
    for name, handler in (("wake.status", wake_status), ("wake.start", wake_start), ("wake.stop", wake_stop),
                          ("wake.pause", wake_pause), ("wake.resume", wake_resume), ("wake.feed", wake_feed)):
        methods[name] = handler
    routes[("POST", "/api/mock/audio")] = mock_switch
    routes[("POST", "/api/mock/audio/reset")] = lambda query, body: (reset(), (200, {"ok": True}))[1]
    B["WS_ROUTES"]["/api/audio/speak-stream"] = speak_stream
    B["WS_ROUTES"]["/api/audio/transcribe-stream"] = transcribe_stream
    B["FILE_STREAM"] = files_stream
    B["MOCK_PROVIDER"] = mock_provider
    install_scenario()
    install_config()
    install_env()
    install_sign_in()

    methods = B["METHODS"]
    submit = methods["prompt.submit"]

    def voice_submit(params):
        voice = {key: params.get(key) for key in ("voice_turn", "surface", "voice_context", "interrupted") if key in params}
        if voice:
            with LOCK:
                TURNS.append(dict(voice, text=params.get("text") or "", at=time.time()))
        result = submit(params)
        if isinstance(result, dict) and result.get("status") in ("streaming", "queued"):
            result = dict(result, user_row_id=int(time.time() * 1000) % 10_000_000)
        return result

    methods["prompt.submit"] = voice_submit

    attach = methods.get("file.attach")

    def file_attach(params):
        result = attach(params) if attach else {}
        url = str(params.get("data_url") or "")
        if url.startswith("data:") and "," in url and isinstance(result, dict) and result.get("path"):
            try:
                add_file(result["path"], base64.b64decode(url.split(",", 1)[1]))
            except ValueError:
                pass
        return result

    methods["file.attach"] = file_attach


# ---------------------------------------------------------------- voices in profiles

def profile_name(query, body=None):
    return ((query.get("profile") or [None])[0] or (body or {}).get("profile") or "default")


def merge(into, incoming):
    for key, value in incoming.items():
        if isinstance(value, dict) and isinstance(into.get(key), dict):
            merge(into[key], value)
        else:
            into[key] = value


def install_config():
    """GET/PUT /api/config keep each Bot's `tts`, `stt` and `voice` sections (Hermes deep-merges a PUT)."""
    routes = B["HTTP_ROUTES"]
    previous_get = routes.get(("GET", "/api/config"))
    previous_put = routes.get(("PUT", "/api/config"))

    def get_config(query, body):
        status, payload = previous_get(query, body) if previous_get else (200, {})
        payload = dict(payload or {})
        with LOCK:
            saved = json.loads(json.dumps(PROFILE_CONFIG.get(profile_name(query, body), {})))
        tts = {"provider": "edge", "speed": 1.0, "edge": {"voice": "en-US-AriaNeural"}}
        merge(tts, saved.get("tts") or {})
        stt = {"enabled": True, "provider": "local", "streaming": False}
        merge(stt, saved.get("stt") or {})
        payload["stt"] = stt
        voice = {"gpt_live": {"voice": "marin"}}
        merge(voice, saved.get("voice") or {})
        payload["tts"] = tts
        payload["voice"] = voice
        return status, payload

    def put_config(query, body):
        config = (body or {}).get("config") or {}
        with LOCK:
            saved = PROFILE_CONFIG.setdefault(profile_name(query, body), {})
            for section in ("tts", "stt", "voice"):
                if isinstance(config.get(section), dict):
                    saved.setdefault(section, {})
                    merge(saved[section], config[section])
        return previous_put(query, body) if previous_put else (200, {"ok": True})

    routes[("GET", "/api/config")] = get_config
    routes[("PUT", "/api/config")] = put_config


VOICE_KEYS = {
    "ELEVENLABS_API_KEY": ("ElevenLabs API key (TTS, transcription)", "https://elevenlabs.io/app/settings/api-keys"),
    "OPENAI_API_KEY": ("OpenAI API key (TTS, transcription, Realtime)", "https://platform.openai.com/api-keys"),
    "VOICE_TOOLS_OPENAI_KEY": ("OpenAI key for voice tools only", "https://platform.openai.com/api-keys"),
    "GROQ_API_KEY": ("Groq API key (Whisper transcription)", "https://console.groq.com/keys"),
    "XAI_API_KEY": ("xAI API key (TTS, transcription)", "https://console.x.ai"),
    "GEMINI_API_KEY": ("Gemini API key (TTS)", "https://aistudio.google.com/apikey"),
}


def install_env():
    """GET /api/env lists the voice keys with is_set and a redacted preview (Hermes's shape), per
    profile; PUT /api/env records which are set before connections.py stores the value."""
    routes = B["HTTP_ROUTES"]
    previous_get = routes.get(("GET", "/api/env"))
    previous_put = routes.get(("PUT", "/api/env"))

    def get_env(query, body):
        status, payload = previous_get(query, body) if previous_get else (200, {})
        payload = dict(payload or {})
        with LOCK:
            have = set(ENV_SET.get(profile_name(query), set()))
        for key, (description, url) in VOICE_KEYS.items():
            payload[key] = {"is_set": key in have, "redacted_value": "sk-…••••" if key in have else None,
                            "description": description, "url": url, "category": "tool", "is_password": True,
                            "tools": ["tts"], "advanced": False, "channel_managed": False, "provider": "",
                            "provider_label": "", "provider_profiles": [], "provider_primary": False, "custom": False}
        return status, payload

    def put_env(query, body):
        key = ((body or {}).get("key") or "").strip()
        with LOCK:
            refusal = STATE.get("env_refusal")
        if refusal:
            # Hermes's own refusal: a ValueError from the credential lifecycle is a 400 with its words.
            return 400, {"detail": refusal}
        if key in VOICE_KEYS and isinstance((body or {}).get("value"), str):
            with LOCK:
                ENV_SET.setdefault(profile_name(query, body), set()).add(key)
        return previous_put(query, body) if previous_put else (200, {"ok": True, "key": key})

    routes[("GET", "/api/env")] = get_env
    routes[("PUT", "/api/env")] = put_env


def install_sign_in():
    """GET /api/providers/oauth lists the xAI Grok sign-in too (hermes_cli/web_routers/oauth.py,
    `get_xai_oauth_auth_status`), logged in with {"xai_oauth": true}."""
    routes = B["HTTP_ROUTES"]
    previous = routes.get(("GET", "/api/providers/oauth"))

    def oauth_providers(query, body):
        status, payload = previous(query, body) if previous else (200, {"providers": []})
        with LOCK:
            signed_in = STATE["xai_oauth"]
        rows = [row for row in (payload or {}).get("providers", []) if row.get("id") != "xai-oauth"]
        rows.append({"id": "xai-oauth", "name": "xAI Grok OAuth (SuperGrok Subscription)", "flow": "device_code",
                     "cli_command": "hermes auth add xai-oauth", "docs_url": "", "disconnect_hint": None,
                     "disconnect_command": None, "disconnectable": True,
                     "status": {"logged_in": signed_in, "source": "xai_oauth", "source_label": "xAI Grok OAuth",
                                "token_preview": "…mock" if signed_in else None, "expires_at": None,
                                "has_refresh_token": True}})
        return status, dict(payload or {}, providers=rows)

    routes[("GET", "/api/providers/oauth")] = oauth_providers


def mock_provider(handler, path, body):
    """POST /mock-provider/openai/v1/audio/speech and /mock-provider/elevenlabs/v1/text-to-speech/<id>:
    a WAV of the text, for voice previews. 401 without the mock's key, like a provider."""
    auth = handler.headers.get("Authorization") or ""
    key = handler.headers.get("xi-api-key") or (auth[7:] if auth.startswith("Bearer ") else "")
    if key != "mock-key-not-real":
        return handler.send_json(401, {"error": {"message": "Incorrect API key provided"}})
    if not (path.endswith("/audio/speech") or "/text-to-speech/" in path):
        return handler.send_json(404, {"detail": "Not Found"})
    with LOCK:
        PREVIEWS.append({"path": path, "voice": body.get("voice") or path.rsplit("/", 1)[-1], "text": body.get("input") or body.get("text") or ""})
    data = wav_bytes(speechlike(body.get("input") or body.get("text") or "Hello"))
    handler.send_response(200)
    handler.send_header("Content-Type", "audio/wav")
    handler.send_header("Content-Length", str(len(data)))
    handler.end_headers()
    handler.wfile.write(data)


# ---------------------------------------------------------------- scenario


def install_scenario():
    """Ask any Bot for something "as audio" (or "voice note"): it calls text_to_speech and answers
    with a voice message, `[[audio_as_voice]]` and a `MEDIA:` line, like Hermes's TTS tool. The file
    is a recorded clip, served by /api/files/stream."""
    import pathlib
    clip = (pathlib.Path(__file__).resolve().parent / "voice" / "essay.m4a").read_bytes()
    original = B["run_turn"]

    def run_turn(sid, text):
        visible = text.split("\n\n[@mentions resolved", 1)[0].lower()
        if "as audio" not in visible and "voice note" not in visible:
            return original(sid, text)
        stored = B["ensure_row"](sid)
        B["add_message"](stored, "user", text)
        B["emit"](sid, "session.info", {"running": True})
        B["emit"](sid, "message.start", {})
        path = f"/Users/demo/.hermes/audio_cache/tts_{uuid.uuid4().hex[:8]}.m4a"
        add_file(path, clip)
        B["tool"](sid, stored, "text_to_speech", {"text": "This week's roundup."},
                  json.dumps({"success": True, "file_path": path, "media_tag": f"[[audio_as_voice]]\nMEDIA:{path}"}),
                  0.8, "This week's roundup.")
        answer = (f"[[audio_as_voice]]\nMEDIA:{path}\n\nHere's the summary you asked for. Two papers this week are worth "
                  "your time; the second one reproduces the speedup on a single GPU.")
        B["stream"](sid, answer)
        return B["finish"](sid, stored, answer)

    B["run_turn"] = run_turn
