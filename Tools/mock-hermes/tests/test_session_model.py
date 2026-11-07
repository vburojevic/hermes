"""The mock keeps each chat's model like Hermes (`docs/sessions-and-models.md` §4): `config.set model`
switches the session, its row keeps the pick, `session.info` tells every client on the session, and
another device resuming the chat is told the model it now runs on.

    python3 -I -m unittest discover -s Tools/mock-hermes/tests -p test_session_model.py
"""

import unittest

from test_audio import Socket
from test_sending import TOKEN, MockCase


class SessionModel(MockCase):
    def second_client(self, stored):
        """Another device opening the same chat: its socket and what `session.resume` answered."""
        ws = Socket(self.port, f"/api/ws?token={TOKEN}")
        self.addCleanup(ws.close)
        ws.sock.settimeout(40)
        return ws, self.rpc(ws, "session.resume", {"session_id": stored})["result"]

    def test_a_pick_on_one_device_is_reported_to_the_other(self):
        ws, sid, stored = self.open_chat()
        set_model = {"session_id": sid, "key": "model", "value": "x-ai/grok-4.5 --provider openrouter"}
        self.assertEqual(self.rpc(ws, "config.set", set_model)["result"]["scope"], "session")
        info = self.until_event(ws, "session.info", where=lambda p: "model" in p)
        self.assertEqual((info["model"], info["provider"]), ("x-ai/grok-4.5", "openrouter"))

        other, resumed = self.second_client(stored)
        self.assertEqual(resumed["session_id"], sid)
        self.assertEqual((resumed["info"]["model"], resumed["info"]["provider"]), ("x-ai/grok-4.5", "openrouter"))

        status, row = self.call("GET", f"/api/sessions/{stored}", port=self.gateway)
        self.assertEqual(status, 200)
        self.assertEqual(row["session"]["model"], "x-ai/grok-4.5")
        self.assertNotIn("_provider", row["session"])

        # The other device's switch reaches this one live.
        set_model["value"] = "openai/gpt-5 --provider openrouter"
        self.rpc(other, "config.set", set_model)
        info = self.until_event(ws, "session.info", where=lambda p: p.get("model") == "openai/gpt-5")
        self.assertEqual(info["provider"], "openrouter")

    def test_a_turn_ends_reporting_the_sessions_own_model(self):
        ws, sid, _ = self.open_chat()
        self.rpc(ws, "config.set", {"session_id": sid, "key": "model", "value": "openai/gpt-5 --provider openrouter"})
        self.assertEqual(self.submit(ws, sid, "short hello")["result"]["status"], "streaming")
        info = self.until_event(ws, "session.info", seconds=30, where=lambda p: p.get("running") is False and "model" in p)
        self.assertEqual(info["model"], "openai/gpt-5")

    def test_an_expensive_model_waiting_for_confirmation_changes_nothing(self):
        ws, sid, stored = self.open_chat()
        answer = self.rpc(ws, "config.set", {"session_id": sid, "key": "model", "value": "anthropic/claude-opus-4.6 --provider openrouter"})
        self.assertTrue(answer["result"]["confirm_required"])
        _, resumed = self.second_client(stored)
        self.assertEqual(resumed["info"]["model"], "anthropic/claude-sonnet-4.6")

    def test_the_api_servers_first_run_names_the_rows_model(self):
        status, created = self.call("POST", "/api/sessions", {"title": "Runs"}, port=self.gateway)
        self.assertEqual(status, 201)
        stored = created["session"]["id"]
        status, _ = self.call("POST", "/v1/runs", {"session_id": stored, "input": "short hello", "model": "openai/gpt-5"},
                              port=self.gateway)
        self.assertEqual(status, 202)
        _, row = self.call("GET", f"/api/sessions/{stored}", port=self.gateway)
        self.assertEqual(row["session"]["model"], "openai/gpt-5")


if __name__ == "__main__":
    unittest.main()
