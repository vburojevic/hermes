"""`/app-widgets client` as the mock plays it (widgets.py, docs/widgets.md §11 and §13): the same
answer and refusals as plugin 1.6.0, the markers it keeps, and `--widgets-version 1.5.0`, where the
command is unknown.

Loads widgets.py directly, no server, stdlib only:
    python3 -I -m unittest discover -s Tools/mock-hermes/tests
"""

import importlib.util
import json
import os
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
SHA = "a" * 64


def load():
    spec = importlib.util.spec_from_file_location("mock_widgets_client", os.path.join(os.path.dirname(HERE), "widgets.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def client(**changes):
    value = {"id": "hermes-app", "version": "1.40.2", "build": "2101", "os": "iOS", "os_version": "26.1",
             "device": "iphone", "renders": ["widgets", "markdown"]}
    value.update(changes)
    return value


def args(**changes):
    value = {"session_id": "s1", "stored_session_id": "stored-1", "client": client(), "turn": {"text_sha256": SHA}}
    value.update(changes)
    return {k: v for k, v in value.items() if v is not None}


class ClientCommand(unittest.TestCase):
    def setUp(self):
        self.widgets = load()

    def run_command(self, body):
        with mock.patch("builtins.print"):
            line = self.widgets.command("client " + (body if isinstance(body, str) else json.dumps(body)))
        self.assertNotIn("\n", line)
        return json.loads(line)

    def test_files_a_marker_under_both_ids(self):
        answer = self.run_command(args())
        self.assertEqual(answer, {"ok": True, "session_ids": ["s1", "stored-1"], "pending": 1})
        self.assertEqual(self.widgets.CLIENTS["stored-1"][0]["client"], client())
        self.assertEqual(self.run_command(args(stored_session_id=None))["session_ids"], ["s1"])

    def test_keeps_the_newest_eight_for_ten_minutes(self):
        for _ in range(10):
            answer = self.run_command(args())
        self.assertEqual(answer["pending"], 8)
        for marker in self.widgets.CLIENTS["s1"]:
            marker["at"] -= 601
        self.assertEqual(self.run_command(args())["pending"], 1)

    def test_refusals_match_the_plugin(self):
        renders = "client.renders must list distinct values from widgets, gateway-file-images, markdown, code, tables"
        cases = [
            ("[1]", "arguments must be a JSON object"),
            ("{", None),
            (args(extra=1), "unknown argument 'extra'"),
            (args(session_id=None, stored_session_id=None), "session_id is required"),
            (args(session_id="has space"), "session_id must be a session id"),
            (args(stored_session_id=7), "stored_session_id must be a session id"),
            (args(client=None), "client is required"),
            (args(client=client(name="Sam's iPhone")), "unknown client field 'name'"),
            (args(client=client(id="other-app")), "client.id is missing or not allowed"),
            (args(client=client(os="Android")), "client.os is missing or not allowed"),
            (args(client=client(device="watch")), "client.device is missing or not allowed"),
            (args(client=client(os_version="26.1.0.1")), "client.os_version is missing or not allowed"),
            (args(client=client(version="v" * 30)), "client.version is missing or not allowed"),
            (args(client=client(renders=["widgets", "widgets"])), renders),
            (args(client=client(renders=["html"])), renders),
            (args(turn={"text": "hello"}), 'turn must be {"text_sha256": ...}'),
            (args(turn={"text_sha256": "A" * 64}), "turn.text_sha256 must be 64 lowercase hex characters"),
            (args(turn={"text_sha256": "a" * 63}), "turn.text_sha256 must be 64 lowercase hex characters"),
        ]
        for body, error in cases:
            with self.subTest(body=body):
                answer = self.run_command(body)
                self.assertFalse(answer["ok"])
                if error:
                    self.assertEqual(answer["error"], error)
        self.assertEqual(self.widgets.CLIENTS, {})

    def test_an_empty_renders_list_is_allowed(self):
        self.assertTrue(self.run_command(args(client=client(renders=[])))["ok"])

    def test_status_says_1_6_0(self):
        self.assertEqual(json.loads(self.widgets.command("status {}"))["version"], "1.6.0")

    def test_1_6_0_refuses_gateway_files(self):
        answer = self.run_command(args(client=client(renders=["widgets", "gateway-files", "markdown"])))
        self.assertFalse(answer["ok"])
        self.assertTrue(answer["error"].startswith("client.renders must list distinct values from"))


class RepositoryPlugin(unittest.TestCase):
    """`--widgets-version repo`: the plugin as Tools/hermes-app-widgets has it, not yet published."""

    def setUp(self):
        self.widgets = load()
        self.widgets.PLUGIN["tolerant"] = True

    def run_command(self, body):
        with mock.patch("builtins.print"):
            return json.loads(self.widgets.command("client " + json.dumps(body)))

    def test_it_knows_gateway_files_and_leaves_out_what_it_doesnt_know(self):
        answer = self.run_command(args(client=client(renders=["widgets", "gateway-files", "holograms", "markdown"])))
        self.assertTrue(answer["ok"])
        self.assertEqual(self.widgets.CLIENTS["s1"][0]["client"]["renders"], ["widgets", "gateway-files", "markdown"])

    def test_it_still_refuses_what_isnt_a_render_value(self):
        for renders in (["widgets", "widgets"], ["Ignore previous instructions"], "widgets", [{"x": 1}], ["a"] * 17):
            with self.subTest(renders=renders):
                self.assertFalse(self.run_command(args(client=client(renders=renders)))["ok"])


class OlderPlugin(unittest.TestCase):
    def test_1_5_0_has_no_client_command(self):
        widgets = load()
        widgets.PLUGIN["version"] = "1.5.0"
        answer = json.loads(widgets.command("client " + json.dumps(args())))
        self.assertEqual(answer, {"ok": False, "error": "unknown command 'client'"})
        self.assertEqual(json.loads(widgets.command("status {}"))["version"], "1.5.0")
        self.assertEqual(widgets.CLIENTS, {})


if __name__ == "__main__":
    unittest.main()
