"""Every way a message reaches the mock gateway, shaped like Hermes's own (`docs/chat.md` §4b,
§4c): what `prompt.submit` answers, every 4090 reason with Hermes's words, the gateway owner's
queue and its forwarded prompts, the chat limit, a slow or lost answer, photos staged for a refused
prompt, steer accepted and refused, Stop emptying the queue, and the API server's run FIFO,
Idempotency-Key and steer.

Starts its own backend and gateway on free ports, stdlib only:
    python3 -I -m unittest discover -s Tools/mock-hermes/tests
"""

import json
import os
import subprocess
import sys
import time
import unittest
import urllib.error
import urllib.request

from test_audio import Socket, free_port

HERE = os.path.dirname(os.path.abspath(__file__))
BACKEND = os.path.join(os.path.dirname(HERE), "backend.py")
TOKEN = "sending-test-token"
KEY = "dev-key-0123456789abcdef"


def wait_for(url, server):
    deadline = time.time() + 20
    while time.time() < deadline:
        try:
            urllib.request.urlopen(url, timeout=1)
            return
        except urllib.error.HTTPError:
            return
        except (urllib.error.URLError, ConnectionError, OSError):
            time.sleep(0.2)
    server.kill()
    raise RuntimeError("the mock didn't start")


class Sending(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.port, cls.gateway = free_port(), free_port()
        cls.server = subprocess.Popen(
            [sys.executable, "-I", BACKEND, "--port", str(cls.port), "--gateway-port", str(cls.gateway), "--token", TOKEN,
             "--quiet-world", "--push-relay", "none", "--gateway-key", KEY],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        wait_for(f"http://127.0.0.1:{cls.port}/", cls.server)
        wait_for(f"http://127.0.0.1:{cls.gateway}/health", cls.server)

    @classmethod
    def tearDownClass(cls):
        cls.server.terminate()
        cls.server.wait(timeout=10)

    # ------------------------------------------------------------ helpers

    def call(self, method, path, body=None, port=None, headers=None):
        data = None if body is None else json.dumps(body).encode()
        request = urllib.request.Request(f"http://127.0.0.1:{port or self.port}{path}", data=data, method=method)
        request.add_header("Content-Type", "application/json")
        request.add_header("X-Hermes-Session-Token", TOKEN)
        request.add_header("Authorization", f"Bearer {KEY}")
        for name, value in (headers or {}).items():
            request.add_header(name, value)
        try:
            with urllib.request.urlopen(request, timeout=40) as response:
                return response.status, json.loads(response.read() or b"null")
        except urllib.error.HTTPError as error:
            return error.code, json.loads(error.read() or b"null")

    def open_chat(self):
        """A socket and a new chat on it: (socket, runtime id, stored id)."""
        ws = Socket(self.port, f"/api/ws?token={TOKEN}")
        self.addCleanup(ws.close)
        ws.sock.settimeout(40)
        self.next_id = 0
        created = self.rpc(ws, "session.create", {"profile": "default"})["result"]
        return ws, created["session_id"], created["stored_session_id"]

    def rpc(self, ws, method, params):
        """One call: its answer (result or error); events seen meanwhile are kept in `self.events`."""
        self.next_id += 1
        rid = self.next_id
        ws.send({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
        while (message := ws.recv()) is not None:
            if isinstance(message, dict) and message.get("id") == rid and "method" not in message:
                return message
            if isinstance(message, dict) and message.get("method") == "event":
                self.events.append(message["params"])
        self.fail(f"{method}: the socket closed without an answer")

    def until_event(self, ws, kind, seconds=20, where=lambda p: True):
        """Reads events until one of `kind` (matching `where`) comes; returns its payload."""
        for params in self.events:
            if params.get("type") == kind and where(params.get("payload") or {}):
                self.events.remove(params)
                return params.get("payload") or {}
        deadline = time.time() + seconds
        while time.time() < deadline:
            message = ws.recv()
            if message is None:
                break
            if isinstance(message, dict) and message.get("method") == "event":
                params = message["params"]
                if params.get("type") == kind and where(params.get("payload") or {}):
                    return params.get("payload") or {}
        self.fail(f"no {kind} event")

    def setUp(self):
        self.events = []

    def submit(self, ws, sid, text, **extra):
        return self.rpc(ws, "prompt.submit", {"session_id": sid, "text": text, **extra})

    def own(self, stored, mode, seconds=2, ack=0):
        status, _ = self.call("POST", "/api/mock/owner", {"session_id": stored, "mode": mode, "seconds": seconds, "ack": ack})
        self.assertEqual(status, 200)
        self.addCleanup(self.call, "POST", "/api/mock/owner", {"session_id": stored, "mode": "off"})

    def refusal(self, answer):
        error = answer.get("error") or {}
        return error.get("code"), (error.get("data") or {}).get("reason"), error.get("message", "")

    # ------------------------------------------------------------ prompt.submit's answers

    def test_an_idle_chat_streams_and_a_typed_stop_phrase_starts_nothing(self):
        ws, sid, _ = self.open_chat()
        self.assertEqual(self.submit(ws, sid, "stop talking")["result"], {"voice_stopped": True})
        self.assertEqual(self.submit(ws, sid, "hello")["result"]["status"], "streaming")

    def test_a_busy_chat_queues_a_queued_message_and_resume_shows_it(self):
        ws, sid, stored = self.open_chat()
        self.submit(ws, sid, "slow please")
        self.until_event(ws, "message.start")
        time.sleep(0.6)
        self.assertEqual(self.submit(ws, sid, "after that", queued=True)["result"]["status"], "queued")
        resumed = self.rpc(ws, "session.resume", {"session_id": stored, "omit_messages": True})["result"]
        self.assertEqual(resumed["queued"], {"user": "after that"})

    # ------------------------------------------------------------ the gateway's own queue

    def test_the_gateway_owner_forwards_a_message_and_relays_only_its_start_and_end(self):
        ws, sid, stored = self.open_chat()
        self.own(stored, "forward", seconds=1.5)
        answer = self.submit(ws, sid, "for the owner")["result"]
        self.assertEqual((answer["status"], answer["forwarded"]), ("queued", True))
        self.assertTrue(answer["admission_id"])
        waiting = self.until_event(ws, "session.info", where=lambda p: p.get("pending_submissions"))
        self.assertEqual(waiting["pending_submissions"][0]["user"], "for the owner")
        self.until_event(ws, "session.info", where=lambda p: p.get("pending_submissions") == [])
        self.until_event(ws, "message.start")
        self.assertIn("for the owner", self.until_event(ws, "message.complete")["text"])

    def test_a_photo_cant_join_the_owners_queue_and_hermes_takes_it_off(self):
        ws, sid, stored = self.open_chat()
        self.own(stored, "forward", seconds=5)
        path = self.rpc(ws, "image.attach_bytes", {"session_id": sid, "content_base64": "AAAA"})["result"]["path"]
        code, reason, message = self.refusal(self.submit(ws, sid, "with a photo"))
        self.assertEqual((code, reason), (4090, "SESSION_OWNER_BUSY"))
        self.assertIn("an image cannot join its queue, so it was removed from this message", message)
        self.assertFalse(self.rpc(ws, "image.detach", {"session_id": sid, "path": path})["result"]["detached"])

    def test_an_unconfirmed_message_may_still_run(self):
        ws, sid, stored = self.open_chat()
        self.own(stored, "unconfirmed", seconds=1)
        code, reason, message = self.refusal(self.submit(ws, sid, "maybe queued"))
        self.assertEqual((code, reason), (4090, "SESSION_OWNER_UNCONFIRMED"))
        self.assertIn("check the chat before sending it again", message)
        self.until_event(ws, "message.start")  # it was queued after all: never send it twice

    def test_a_slow_owner_answers_late(self):
        ws, sid, stored = self.open_chat()
        self.own(stored, "forward", seconds=1, ack=1.2)
        started = time.time()
        self.assertTrue(self.submit(ws, sid, "slowly")["result"]["forwarded"])
        self.assertGreaterEqual(time.time() - started, 1.1)

    def test_every_other_refusal_in_hermes_words_and_photos_stay_staged(self):
        cases = {
            "busy": ("SESSION_OWNER_BUSY", "Nothing was sent. Send it again when the current turn ends."),
            "ledger-unknown": ("SESSION_NOT_OWNED", "outcome-unknown work in the gateway's durable queue"),
            "coordination": ("SESSION_COORDINATION_UNAVAILABLE", "could not read the active-session registry"),
            "no-reason": (None, "Hermes could not safely reserve this session. Try again."),
            "unknown-reason": ("SESSION_PAUSED_FOR_MAINTENANCE", "Try again in a few minutes."),
        }
        for mode, (wanted, words) in cases.items():
            with self.subTest(mode=mode):
                ws, sid, stored = self.open_chat()
                self.own(stored, mode, seconds=5)
                code, reason, message = self.refusal(self.submit(ws, sid, "hello"))
                self.assertEqual((code, reason), (4090, wanted))
                self.assertIn(words, message)
        # A refusal before the owner's queue leaves photos staged for the next prompt: the app takes them back.
        ws, sid, stored = self.open_chat()
        self.own(stored, "no-reason", seconds=5)
        path = self.rpc(ws, "image.attach_bytes", {"session_id": sid, "content_base64": "AAAA"})["result"]["path"]
        self.submit(ws, sid, "with a photo")
        self.assertTrue(self.rpc(ws, "image.detach", {"session_id": sid, "path": path})["result"]["detached"])

    def test_the_chat_limit_names_its_counts_and_lets_go(self):
        ws, sid, _ = self.open_chat()
        self.call("POST", "/api/mock/limit", {"seconds": 1, "active": 3, "limit": 3})
        code, reason, message = self.refusal(self.submit(ws, sid, "hello"))
        self.assertEqual((code, reason), (4090, "MAX_CONCURRENT_SESSIONS"))
        self.assertIn("(3/3)", message)
        time.sleep(1.1)
        self.assertEqual(self.submit(ws, sid, "hello")["result"]["status"], "streaming")

    def test_a_lost_answer_still_ran(self):
        ws, sid, stored = self.open_chat()
        self.call("POST", "/api/mock/lose-answer", {"method": "prompt.submit", "taken": True})
        ws.send({"jsonrpc": "2.0", "id": 99, "method": "prompt.submit", "params": {"session_id": sid, "text": "hello"}})
        while ws.recv() is not None:
            pass  # the socket is cut instead of answering
        again = Socket(self.port, f"/api/ws?token={TOKEN}")
        self.addCleanup(again.close)
        again.sock.settimeout(20)
        deadline = time.time() + 15
        while time.time() < deadline:
            resumed = self.rpc(again, "session.resume", {"session_id": stored, "omit_messages": True})["result"]
            if resumed["running"] or resumed["message_count"] > 0:
                return  # its turn runs, or ran: sending it again would run it twice
            time.sleep(0.3)
        self.fail("the message whose answer was lost never ran")

    # ------------------------------------------------------------ steer and Stop

    def test_steer_is_refused_while_the_agent_is_built_then_accepted_then_rejected_when_idle(self):
        ws, sid, _ = self.open_chat()
        self.assertEqual(self.rpc(ws, "session.steer", {"session_id": sid, "text": "early"})["result"]["status"], "rejected")
        self.submit(ws, sid, "slow please")
        code, _, message = self.refusal(self.rpc(ws, "session.steer", {"session_id": sid, "text": "too early"}))
        self.assertEqual((code, message), (4010, "agent does not support steer"))
        time.sleep(0.6)
        self.assertEqual(self.rpc(ws, "session.steer", {"session_id": sid, "text": "now"})["result"]["status"], "queued")

    def test_a_cold_start_refuses_a_steer_while_its_agent_is_built(self):
        ws, sid, _ = self.open_chat()
        self.submit(ws, sid, "slow please, cold start")
        time.sleep(1.5)
        code, _, message = self.refusal(self.rpc(ws, "session.steer", {"session_id": sid, "text": "too early"}))
        self.assertEqual((code, message), (4010, "agent does not support steer"))
        self.rpc(ws, "session.interrupt", {"session_id": sid})

    def test_a_steer_while_hermes_compacts_waits_for_the_next_turn(self):
        ws, sid, stored = self.open_chat()
        self.submit(ws, sid, "clean up old snapshots and compact")
        self.until_event(ws, "status.update", where=lambda p: p.get("kind") == "compacting")
        self.assertEqual(self.rpc(ws, "session.steer", {"session_id": sid, "text": "only this week"})["result"]["status"], "queued")
        resumed = self.rpc(ws, "session.resume", {"session_id": stored, "omit_messages": True})["result"]
        self.assertEqual((resumed["queued"] or {}).get("user"), "only this week")
        self.rpc(ws, "session.interrupt", {"session_id": sid})

    def test_stop_empties_the_queue(self):
        ws, sid, stored = self.open_chat()
        self.submit(ws, sid, "slow please")
        time.sleep(0.6)
        self.assertEqual(self.submit(ws, sid, "next", queued=True)["result"]["status"], "queued")
        self.rpc(ws, "session.interrupt", {"session_id": sid})
        resumed = self.rpc(ws, "session.resume", {"session_id": stored, "omit_messages": True})["result"]
        self.assertIsNone(resumed["queued"])

    def stored_rows(self, stored):
        status, body = self.call("GET", f"/api/sessions/{stored}/messages", port=self.gateway)
        self.assertEqual(status, 200)
        return body["data"]

    def test_words_join_the_head_and_photo_messages_stay_their_own_turns(self):
        ws, sid, stored = self.open_chat()
        self.submit(ws, sid, "slow please")
        time.sleep(0.6)
        self.submit(ws, sid, "first", queued=True)
        self.submit(ws, sid, "second", queued=True)
        resumed = self.rpc(ws, "session.resume", {"session_id": stored, "omit_messages": True})["result"]
        self.assertEqual(resumed["queued"], {"user": "first\n\nsecond"})
        self.rpc(ws, "image.attach_bytes", {"session_id": sid, "content_base64": "AAAA"})
        self.assertEqual(self.submit(ws, sid, "a photo", queued=True)["result"]["status"], "queued")
        self.submit(ws, sid, "after the photo", queued=True)
        queued = [r for r in self.stored_rows(stored) if (r.get("display_metadata") or "").find("_queued_prompt") >= 0]
        self.assertEqual([r["content"] for r in queued], ["first\n\nsecond", "a photo", "after the photo"])

    def test_stop_leaves_the_rows_of_messages_it_cleared_marked_and_a_drain_swaps_them(self):
        ws, sid, stored = self.open_chat()
        self.submit(ws, sid, "slow please")
        time.sleep(0.6)
        self.submit(ws, sid, "cleared by stop", queued=True)
        self.rpc(ws, "session.interrupt", {"session_id": sid})
        marked = [r for r in self.stored_rows(stored) if r["content"] == "cleared by stop"]
        self.assertEqual(len(marked), 1)
        self.assertIn("_queued_prompt", marked[0].get("display_metadata") or "")
        # A queued message that runs: its accept-time row goes, and the turn stores its own.
        ws, sid, stored = self.open_chat()
        self.submit(ws, sid, "slow please")
        time.sleep(0.6)
        self.assertEqual(self.submit(ws, sid, "then this", queued=True)["result"]["status"], "queued")
        deadline = time.time() + 60
        while time.time() < deadline:
            rows = [r for r in self.stored_rows(stored) if r["content"] == "then this"]
            if any(r.get("display_kind") is None and not r.get("display_metadata") for r in rows):
                break
            time.sleep(0.3)
        self.assertEqual([r.get("display_kind") for r in rows], ["hidden", None])

    # ------------------------------------------------------------ the API server

    def test_a_run_behind_another_answers_started_but_waits_queued(self):
        sid = f"api_fifo_{int(time.time() * 1000)}"
        status, first = self.call("POST", "/v1/runs", {"session_id": sid, "input": "slow first"}, port=self.gateway)
        self.assertEqual(status, 202)
        status, second = self.call("POST", "/v1/runs", {"session_id": sid, "input": "second"}, port=self.gateway)
        self.assertEqual((status, second["status"]), (202, "started"))
        _, polled = self.call("GET", f"/v1/runs/{second['run_id']}", port=self.gateway)
        self.assertEqual(polled["status"], "queued")
        status, body = self.call("POST", f"/v1/runs/{second['run_id']}/steer", {"input": "hurry"}, port=self.gateway)
        self.assertEqual((status, body["error"]["code"]), (409, "run_not_accepting_steer"))
        time.sleep(0.5)
        status, body = self.call("POST", f"/v1/runs/{first['run_id']}/steer", {"input": "hurry"}, port=self.gateway)
        self.assertEqual((status, body.get("accepted")), (200, True))
        # Stop on the queued run cancels only it.
        self.call("POST", f"/v1/runs/{second['run_id']}/stop", port=self.gateway)
        time.sleep(0.3)
        _, polled = self.call("GET", f"/v1/runs/{second['run_id']}", port=self.gateway)
        self.assertEqual(polled["status"], "cancelled")
        _, polled = self.call("GET", f"/v1/runs/{first['run_id']}", port=self.gateway)
        self.assertIn(polled["status"], ("running", "completed"))

    def test_the_same_key_replays_the_run_and_another_body_conflicts(self):
        sid = f"api_key_{int(time.time() * 1000)}"
        headers = {"Idempotency-Key": f"key-{sid}"}
        _, first = self.call("POST", "/v1/runs", {"session_id": sid, "input": "once"}, port=self.gateway, headers=headers)
        status, again = self.call("POST", "/v1/runs", {"session_id": sid, "input": "once"}, port=self.gateway, headers=headers)
        self.assertEqual((status, again["run_id"], again["replayed"]), (202, first["run_id"], True))
        status, body = self.call("POST", "/v1/runs", {"session_id": sid, "input": "other"}, port=self.gateway, headers=headers)
        self.assertEqual((status, body["error"]["code"]), (409, "idempotency_key_conflict"))

    def test_the_api_servers_caps_refuse_in_hermes_words(self):
        sid = f"api_caps_{int(time.time() * 1000)}"
        self.addCleanup(self.call, "POST", "/api/mock/run-caps", {"max_runs": 10, "queue_max": 32}, port=self.gateway)
        status, caps = self.call("POST", "/api/mock/run-caps", {"queue_max": 1}, port=self.gateway)
        self.assertEqual((status, caps["queue_max"]), (200, 1))
        self.call("POST", "/v1/runs", {"session_id": sid, "input": "slow first"}, port=self.gateway)
        status, second = self.call("POST", "/v1/runs", {"session_id": sid, "input": "second"}, port=self.gateway)
        self.assertEqual(status, 202)
        time.sleep(0.3)
        # The store's refusal: 409, its message the bare reason.
        status, body = self.call("POST", "/v1/runs", {"session_id": sid, "input": "third"}, port=self.gateway)
        self.assertEqual((status, body["error"]["code"], body["error"]["message"]), (409, "queue_full", "queue_full"))
        # Two runs of this chat are live, so a cap of 2 is reached for any chat.
        self.call("POST", "/api/mock/run-caps", {"max_runs": 2, "queue_max": 32}, port=self.gateway)
        status, body = self.call("POST", "/v1/runs", {"session_id": f"{sid}_b", "input": "another chat"}, port=self.gateway)
        self.assertEqual((status, body["error"]["code"], body["error"]["type"]), (429, "rate_limit_exceeded", "rate_limit_error"))
        self.assertRegex(body["error"]["message"], r"^Too many concurrent runs \(max \d+\)$")
        self.call("POST", f"/v1/runs/{second['run_id']}/stop", port=self.gateway)

    def test_a_gateway_restart_keeps_a_keyed_runs_status_as_interrupted(self):
        """As Hermes (api_server_runs.py `_durable_run_status`): a run started under an Idempotency-Key
        reads `interrupted` after a restart cut it off, one without is gone, and neither stores more."""
        sid = f"api_restart_{int(time.time() * 1000)}"
        _, keyed = self.call("POST", "/v1/runs", {"session_id": sid, "input": "slow one"}, port=self.gateway,
                             headers={"Idempotency-Key": f"key-{sid}"})
        _, plain = self.call("POST", "/v1/runs", {"session_id": f"{sid}_b", "input": "slow two"}, port=self.gateway)
        time.sleep(1.5)
        status, body = self.call("POST", "/api/mock/restart-gateway", {}, port=self.gateway)
        self.assertEqual(status, 200)
        _, rows = self.call("GET", f"/api/sessions/{sid}/messages", port=self.gateway)
        status, run = self.call("GET", f"/v1/runs/{keyed['run_id']}", port=self.gateway)
        self.assertEqual((status, run["status"], run["error"]), (200, "interrupted", "The gateway restarted before this run settled."))
        status, events = self.call("GET", f"/v1/runs/{keyed['run_id']}/events", port=self.gateway)
        self.assertEqual((status, events["error"]["code"]), (404, "run_not_found"))
        status, gone = self.call("GET", f"/v1/runs/{plain['run_id']}", port=self.gateway)
        self.assertEqual((status, gone["error"]["code"]), (404, "run_not_found"))
        time.sleep(4.5)
        _, later = self.call("GET", f"/api/sessions/{sid}/messages", port=self.gateway)
        self.assertEqual(len(later["data"]), len(rows["data"]))
        self.assertNotEqual(later["data"][-1]["role"], "user")
        # An older Hermes kept no status over a restart.
        self.call("POST", "/api/mock/restart-gateway", {"forget": True}, port=self.gateway)
        status, _ = self.call("GET", f"/v1/runs/{keyed['run_id']}", port=self.gateway)
        self.assertEqual(status, 404)


if __name__ == "__main__":
    unittest.main()
