"""The mock's audio routes (audio.py, `docs/voice.md` §10), shaped like `hermes serve`'s: the REST
calls, the speak-stream and transcribe-stream sockets, the voice fields of prompt.submit and the
wake word's JSON-RPC methods, refusals included.

Starts its own backend on a free port, stdlib only:
    python3 -I -m unittest discover -s Tools/mock-hermes/tests
"""

import base64
import hashlib
import io
import json
import os
import socket
import struct
import subprocess
import sys
import time
import unittest
import urllib.error
import urllib.request
import wave

HERE = os.path.dirname(os.path.abspath(__file__))
BACKEND = os.path.join(os.path.dirname(HERE), "backend.py")
TOKEN = "audio-test-token"


def free_port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


class Socket:
    """A minimal WebSocket client: text and binary frames, masked as a client's must be."""

    def __init__(self, port, path):
        self.sock = socket.create_connection(("127.0.0.1", port), timeout=10)
        key = base64.b64encode(os.urandom(16)).decode()
        self.sock.sendall((f"GET {path} HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                           f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
        head = b""
        while b"\r\n\r\n" not in head:
            chunk = self.sock.recv(1)
            if not chunk:
                raise ConnectionError("closed during the upgrade")
            head += chunk
        self.status = int(head.split(b" ")[1])
        expected = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest())
        assert self.status != 101 or expected in head, "wrong Sec-WebSocket-Accept"
        self.close_code = None

    def _frame(self, opcode, payload):
        mask = os.urandom(4)
        header = bytearray([0x80 | opcode])
        if len(payload) < 126:
            header.append(0x80 | len(payload))
        elif len(payload) < 65536:
            header += bytes([0x80 | 126]) + struct.pack(">H", len(payload))
        else:
            header += bytes([0x80 | 127]) + struct.pack(">Q", len(payload))
        self.sock.sendall(bytes(header) + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))

    def send(self, obj):
        self._frame(0x1, json.dumps(obj).encode())

    def send_text(self, text):
        self._frame(0x1, text.encode())

    def send_binary(self, data):
        self._frame(0x2, data)

    def _exact(self, count):
        data = b""
        while len(data) < count:
            chunk = self.sock.recv(count - len(data))
            if not chunk:
                raise ConnectionError("closed")
            data += chunk
        return data

    def recv(self):
        """The next message: a dict (JSON text), bytes (binary), or None once closed."""
        try:
            first, second = self._exact(2)
        except (ConnectionError, OSError):
            return None
        opcode, length = first & 0x0F, second & 0x7F
        if length == 126:
            length = struct.unpack(">H", self._exact(2))[0]
        elif length == 127:
            length = struct.unpack(">Q", self._exact(8))[0]
        payload = self._exact(length)
        if opcode == 0x8:
            self.close_code = struct.unpack(">H", payload[:2])[0] if len(payload) >= 2 else None
            return None
        if opcode == 0x2:
            return payload
        if opcode == 0x9:
            return self.recv()
        return json.loads(payload.decode())

    def messages(self, timeout=20):
        """Every message until the socket closes."""
        self.sock.settimeout(timeout)
        out = []
        while (message := self.recv()) is not None:
            out.append(message)
        return out

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


class AudioRoutes(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.port = free_port()
        # The audio routes come with the gateway, as on a real Hermes.
        cls.server = subprocess.Popen(
            [sys.executable, "-I", BACKEND, "--port", str(cls.port), "--gateway-port", str(free_port()), "--token", TOKEN,
             "--quiet-world", "--push-relay", "none"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        deadline = time.time() + 20
        while time.time() < deadline:
            try:
                urllib.request.urlopen(f"http://127.0.0.1:{cls.port}/", timeout=1)
                return
            except (urllib.error.URLError, ConnectionError, OSError):
                time.sleep(0.2)
        cls.server.kill()
        raise RuntimeError("the mock didn't start")

    @classmethod
    def tearDownClass(cls):
        cls.server.terminate()
        cls.server.wait(timeout=10)

    def setUp(self):
        self.call("POST", "/api/mock/audio/reset", {})

    # ------------------------------------------------------------ helpers

    def call(self, method, path, body=None, token=TOKEN):
        data = None if body is None else json.dumps(body).encode()
        request = urllib.request.Request(f"http://127.0.0.1:{self.port}{path}", data=data, method=method)
        request.add_header("Content-Type", "application/json")
        if token:
            request.add_header("X-Hermes-Session-Token", token)
        try:
            with urllib.request.urlopen(request, timeout=10) as response:
                return response.status, json.loads(response.read() or b"null")
        except urllib.error.HTTPError as error:
            return error.code, json.loads(error.read() or b"null")

    def switch(self, **settings):
        status, state = self.call("POST", "/api/mock/audio", settings)
        self.assertEqual(status, 200)
        return state

    def socket(self, path, token=TOKEN):
        joiner = "&" if "?" in path else "?"
        opened = Socket(self.port, f"{path}{joiner}token={token}" if token else path)
        self.addCleanup(opened.close)
        return opened

    def rpc(self, method, params=None):
        """One JSON-RPC call on the backend's socket: its result, or its error."""
        ws = self.socket("/api/ws")
        ws.sock.settimeout(10)
        ws.send({"jsonrpc": "2.0", "id": 1, "method": method, "params": params or {}})
        while (message := ws.recv()) is not None:
            if isinstance(message, dict) and message.get("id") == 1:
                return message
        self.fail(f"{method}: the socket closed without an answer")

    # ------------------------------------------------------------ REST

    def test_realtime_status_is_chained_until_switched_on(self):
        status, body = self.call("GET", "/api/audio/voice-live/status")
        self.assertEqual((status, body["mode"], body["available"]), (200, "chained", True))
        self.switch(realtime=True, key=False)
        _, body = self.call("GET", "/api/audio/voice-live/status")
        self.assertEqual((body["mode"], body["available"]), ("gpt-live", False))
        self.assertIn("no OpenAI API key", body["reason"])
        self.switch(key=True)
        _, body = self.call("GET", "/api/audio/voice-live/status")
        self.assertTrue(body["available"])
        self.assertIsNone(body["reason"])

    def test_an_unknown_profile_is_refused_as_hermes_does(self):
        status, body = self.call("GET", "/api/audio/voice-live/status?profile=nobody")
        self.assertEqual((status, body["detail"]), (404, "Profile 'nobody' does not exist."))
        status, _ = self.call("POST", "/api/audio/speak", {"text": "Hi.", "profile": "nobody"})
        self.assertEqual(status, 404)

    def test_realtime_session_needs_an_offer_and_a_key(self):
        status, body = self.call("POST", "/api/audio/voice-live/session", {"sdp": "  "})
        self.assertEqual((status, body["detail"]), (400, "An SDP offer is required"))
        self.switch(key=False)
        status, body = self.call("POST", "/api/audio/voice-live/session", {"sdp": "v=0", "history": []})
        self.assertEqual(status, 503)
        self.assertIn("OpenAI API key", body["detail"])
        self.switch(key=True)
        status, body = self.call("POST", "/api/audio/voice-live/session", {"sdp": "v=0", "history": []})
        self.assertEqual((status, body["transport"]["type"]), (200, "webrtc"))
        self.assertTrue(body["transport"]["sdp"].startswith("v=0"))

    def test_speak_answers_a_wav_and_fails_like_a_broken_provider(self):
        status, body = self.call("POST", "/api/audio/speak", {"text": " "})
        self.assertEqual((status, body["detail"]), (400, "Text is required"))
        status, body = self.call("POST", "/api/audio/speak", {"text": "The backups finished."})
        self.assertEqual((status, body["mime_type"]), (200, "audio/wav"))
        prefix = "data:audio/wav;base64,"
        self.assertTrue(body["data_url"].startswith(prefix))
        with wave.open(io.BytesIO(base64.b64decode(body["data_url"][len(prefix):]))) as clip:
            self.assertEqual((clip.getnchannels(), clip.getsampwidth(), clip.getframerate()), (1, 2, 24000))
            self.assertGreater(clip.getnframes() / 24000, 1.0)
        self.switch(tts="broken")
        status, body = self.call("POST", "/api/audio/speak", {"text": "Hi."})
        self.assertEqual((status, body["detail"]), (500, "Speech synthesis failed"))

    def test_leases_count_and_need_a_name(self):
        status, body = self.call("POST", "/api/audio/tts-lease", {"active": True})
        self.assertEqual((status, body["detail"]), (400, "lease is required"))
        _, body = self.call("POST", "/api/audio/tts-lease", {"lease": "app:talk", "active": True})
        self.assertEqual((body["leases"], body["action"]), (1, "loaded"))
        _, body = self.call("POST", "/api/audio/tts-lease", {"lease": "app:listen", "active": True})
        self.assertEqual(body["leases"], 2)
        _, body = self.call("POST", "/api/audio/tts-lease", {"lease": "app:talk", "active": False})
        self.assertEqual((body["leases"], body["action"]), (1, "noop"))
        _, body = self.call("POST", "/api/audio/stt-lease", {"lease": "app:talk", "active": True})
        self.assertTrue(body["warmed"])

    def test_transcribe_answers_the_switched_transcript_and_lists_it(self):
        status, body = self.call("POST", "/api/audio/transcribe", {"data_url": "audio"})
        self.assertEqual((status, body["detail"]), (400, "Invalid audio payload"))
        self.switch(transcript="Allow once.")
        status, body = self.call("POST", "/api/audio/transcribe", {"data_url": "data:audio/wav;base64,AAAA"})
        self.assertEqual((status, body["transcript"]), (200, "Allow once."))
        _, turns = self.call("GET", "/api/mock/audio/turns")
        self.assertEqual(turns["whole"], [{"mime_type": "audio/wav", "transcript": "Allow once."}])

    def test_voice_config_relays_until_direct_hands_out_a_fake_key(self):
        _, body = self.call("GET", "/api/audio/voice-config")
        self.assertEqual((body["stt"]["mode"], body["tts"]["mode"], body["stt"]["streaming"]), ("relay", "relay", False))
        self.assertNotIn("api_key", json.dumps(body))
        self.switch(direct=True, stt_streaming=True)
        _, body = self.call("GET", "/api/audio/voice-config")
        self.assertEqual((body["tts"]["mode"], body["tts"]["wire"]), ("direct", "openai-speech"))
        self.assertEqual(body["tts"]["api_key"], "mock-key-not-real")
        self.assertTrue(body["tts"]["base_url"].startswith(f"http://127.0.0.1:{self.port}/mock-provider/"))
        self.assertTrue(body["stt"]["streaming"])

    def test_live_transcription_follows_the_config_and_the_key_as_hermes_does(self):
        self.call("PUT", "/api/config?profile=researcher", {"config": {"stt": {"provider": "openai", "streaming": True}}})
        _, body = self.call("GET", "/api/audio/voice-config?profile=researcher")
        self.assertFalse(body["stt"]["streaming"], "streaming without the provider's key")
        status, _ = self.call("PUT", "/api/env?profile=researcher", {"key": "OPENAI_API_KEY", "value": "sk-test-not-real"})
        self.assertEqual(status, 200)
        _, body = self.call("GET", "/api/audio/voice-config?profile=researcher")
        self.assertTrue(body["stt"]["streaming"])

    def test_elevenlabs_voices_are_listed_by_label(self):
        _, body = self.call("GET", "/api/audio/elevenlabs/voices")
        labels = [voice["label"] for voice in body["voices"]]
        self.assertTrue(body["available"])
        self.assertEqual(labels, sorted(labels))
        self.switch(elevenlabs=False)
        _, body = self.call("GET", "/api/audio/elevenlabs/voices")
        self.assertEqual(body, {"available": False, "voices": []})

    def test_files_stream_refuses_relative_paths_and_non_media(self):
        status, body = self.call("GET", "/api/files/stream?path=notes/a.m4a")
        self.assertEqual((status, body["detail"]), (400, "Path must be absolute"))
        status, body = self.call("GET", "/api/files/stream?path=/home/me/notes.txt")
        self.assertEqual((status, body["detail"]), (415, "Unsupported media type"))
        status, body = self.call("GET", "/api/files/stream?path=/home/me/missing.m4a")
        self.assertEqual((status, body["detail"]), (404, "File not found"))

    # ------------------------------------------------------------ speak-stream

    def test_speak_stream_reads_each_sentence_as_pcm(self):
        ws = self.socket("/api/audio/speak-stream?profile=researcher")
        self.assertEqual(ws.status, 101)
        ws.send({"text": "The backups finished at three."})
        ws.send({"done": True})
        messages = ws.messages()
        self.assertEqual(messages[0], {"type": "start", "sample_rate": 24000, "channels": 1})
        self.assertEqual(messages[-1], {"type": "end"})
        pcm = b"".join(m for m in messages if isinstance(m, bytes))
        # About 65 ms a character, int16 at 24 kHz.
        self.assertAlmostEqual(len(pcm) / 2 / 24000, 0.065 * len("The backups finished at three."), delta=0.1)
        _, turns = self.call("GET", "/api/mock/audio/turns")
        self.assertEqual([(s["text"], s["profile"]) for s in turns["spoken"]], [("The backups finished at three.", "researcher")])

    def test_speak_stream_stops_on_stop(self):
        ws = self.socket("/api/audio/speak-stream")
        ws.send({"text": "A long sentence that takes a few seconds to say out loud, at least four of them."})
        ws.sock.settimeout(10)
        self.assertEqual(ws.recv()["type"], "start")
        ws.send({"stop": True})
        started = time.time()
        rest = ws.messages()
        self.assertLess(time.time() - started, 2, "it carried on after stop")
        self.assertNotIn({"type": "end"}, rest)

    def test_speak_stream_says_fallback_when_the_voice_cant(self):
        self.switch(tts="fallback")
        ws = self.socket("/api/audio/speak-stream")
        ws.send({"text": "Hi."})
        self.assertEqual(ws.messages(), [{"type": "fallback"}])

    def test_sockets_without_the_token_are_closed(self):
        ws = self.socket("/api/audio/speak-stream", token=None)
        self.assertEqual(ws.messages(), [])
        self.assertEqual(ws.close_code, 1008)

    # ------------------------------------------------------------ transcribe-stream

    def test_transcribe_stream_refuses_without_live_stt(self):
        ws = self.socket("/api/audio/transcribe-stream")
        self.assertEqual(ws.messages(), [{"type": "error", "message": "no live STT for the configured provider"}])

    def test_transcribe_stream_hears_partials_then_the_final(self):
        self.switch(stt_streaming=True, transcript="What's on my calendar today?")
        ws = self.socket("/api/audio/transcribe-stream")
        ws.send({"sample_rate": 16000})
        # Two seconds of silence in 100 ms chunks.
        for _ in range(20):
            ws.send_binary(bytes(3200))
        ws.send({"eos": True})
        messages = ws.messages()
        partials = [m["text"] for m in messages if m.get("type") == "partial"]
        self.assertGreaterEqual(len(partials), 3)
        self.assertTrue(all(b.startswith(a) for a, b in zip(partials, partials[1:])), "each partial carries everything so far")
        self.assertEqual(messages[-1], {"type": "final", "transcript": "What's on my calendar today?", "provider": "openai"})
        _, turns = self.call("GET", "/api/mock/audio/turns")
        self.assertEqual(turns["live"], [{"sample_rate": 16000, "bytes": 64000, "ended": "final"}])

    def test_transcribe_stream_reports_a_dropped_provider_after_eos(self):
        self.switch(stt_streaming=True, transcript="Allow once.", stt_live_fail="live transcription failed: connection reset")
        ws = self.socket("/api/audio/transcribe-stream")
        ws.send({"sample_rate": 16000})
        ws.send_binary(bytes(3200))
        ws.send({"eos": True})
        messages = ws.messages()
        self.assertEqual(messages[-1], {"type": "error", "message": "live transcription failed: connection reset"})
        _, turns = self.call("GET", "/api/mock/audio/turns")
        self.assertEqual(turns["live"][0]["ended"], "failed")

    def test_transcribe_stream_closes_without_a_word_when_the_rate_is_missing(self):
        self.switch(stt_streaming=True, transcript="Hi.")
        ws = self.socket("/api/audio/transcribe-stream")
        ws.send_binary(bytes(3200))
        self.assertEqual(ws.messages(), [])
        ws = self.socket("/api/audio/transcribe-stream")
        ws.send({"sample_rate": 4000})
        self.assertEqual(ws.messages(), [])

    # ------------------------------------------------------------ JSON-RPC

    def test_prompt_submit_keeps_the_voice_fields(self):
        created = self.rpc("session.create", {})
        self.assertIn("result", created, created)
        session = created["result"]["session_id"]
        answer = self.rpc("prompt.submit", {"session_id": session, "text": "Check the NAS.", "voice_turn": True,
                                            "surface": "voice-live", "voice_context": "User: hi", "interrupted": True})
        self.assertIn("user_row_id", answer["result"], answer)
        _, turns = self.call("GET", "/api/mock/audio/turns")
        turn = turns["turns"][-1]
        self.assertEqual((turn["text"], turn["voice_turn"], turn["surface"], turn["voice_context"], turn["interrupted"]),
                         ("Check the NAS.", True, "voice-live", "User: hi", True))

    def test_the_wake_word_refuses_until_enabled_and_checks_feeds(self):
        started = self.rpc("wake.start", {"surface": "gui", "client_capture": True})["result"]
        self.assertEqual((started["started"], started["reason"]), (False, "disabled"))
        started = self.rpc("wake.start", {"surface": "gui", "client_capture": True, "persist": True})["result"]
        self.assertTrue(started["started"])
        self.assertEqual(self.rpc("wake.status")["result"]["owned_by_caller"], True)
        bad = self.rpc("wake.feed", {"pcm": base64.b64encode(bytes(2560)).decode(), "sample_rate": 48000})
        self.assertEqual(bad["error"]["code"], 4001)
        fed = self.rpc("wake.feed", {"pcm": base64.b64encode(bytes(2560)).decode(), "sample_rate": 16000})
        self.assertIn("result", fed, fed)
        self.assertTrue(self.rpc("wake.stop")["result"]["stopped"])


if __name__ == "__main__":
    unittest.main()
