"""The mock's model fallback (`docs/chat.md` §2, "Model switches"): Hermes's own lines, the fallback
as a turn ends and the restore as the next one starts, once and on every turn.

    python3 -I -m unittest discover -s Tools/mock-hermes/tests -p test_model_switch.py
"""

import unittest

from test_sending import MockCase

FALLBACK = ("⚠️ Model fallback: claude-opus-5-5 via anthropic unavailable (provider server error); "
            "using gpt-6-sol via openai-codex.")
RESTORED = ("✅ Primary model restored: claude-opus-5-5 via anthropic; "
            "fallback gpt-6-sol via openai-codex is no longer active.")


class ModelSwitches(MockCase):
    def turn(self, ws, sid, text):
        """Sends one message; the lifecycle lines its turn sent, in order, the end marked "end"."""
        self.events = []
        self.assertEqual(self.submit(ws, sid, text)["result"]["status"], "streaming")
        lines = []
        while True:
            message = ws.recv()
            self.assertIsNotNone(message, "the socket closed mid-turn")
            if not isinstance(message, dict) or message.get("method") != "event":
                continue
            kind, payload = message["params"]["type"], message["params"].get("payload") or {}
            if kind == "status.update" and payload.get("kind") == "lifecycle":
                lines.append(payload["text"])
            elif kind == "message.complete":
                lines.append("end")
            elif kind == "session.info" and payload.get("running") is False and "end" in lines:
                return lines

    def test_one_fallback_then_the_restore_as_the_next_turn_starts(self):
        ws, sid, _ = self.open_chat(title="Bot Chat")
        self.assertEqual(self.turn(ws, sid, "fallback please"), [FALLBACK, "end"])
        self.assertEqual(self.turn(ws, sid, "hello"), [RESTORED, "end"])
        self.assertEqual(self.turn(ws, sid, "hello again"), ["end"])

    def test_a_primary_that_fails_every_turn_restores_and_falls_back_each_time(self):
        ws, sid, _ = self.open_chat(title="Bot Chat")
        self.assertEqual(self.turn(ws, sid, "fallback every turn"), [FALLBACK, "end"])
        self.assertEqual(self.turn(ws, sid, "hello"), [RESTORED, FALLBACK, "end"])
        self.assertEqual(self.turn(ws, sid, "hello again"), [RESTORED, FALLBACK, "end"])
        self.assertEqual(self.turn(ws, sid, "fallback off"), [RESTORED, "end"])
        self.assertEqual(self.turn(ws, sid, "and now"), ["end"])


if __name__ == "__main__":
    unittest.main()
