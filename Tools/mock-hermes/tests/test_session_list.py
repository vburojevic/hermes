"""The mock's chat lists keep Hermes' pins (`list_sessions_rich(include_pinned=True)`): every
pinned chat comes back after the page, however far past it, on the gateway's and the dashboard's
`GET /api/sessions` alike.

    python3 -I -m unittest discover -s Tools/mock-hermes/tests -p test_session_list.py
"""

import unittest

from test_sending import MockCase


class SessionList(MockCase):
    def ids(self, path, port=None, key="data"):
        status, body = self.call("GET", path, port=port)
        self.assertEqual(status, 200)
        return [row["id"] for row in body[key]]

    def oldest(self):
        return self.ids("/api/sessions?limit=200", port=self.gateway)[-1]

    def test_a_pin_past_the_page_follows_it(self):
        old = self.oldest()
        self.assertNotIn(old, self.ids("/api/sessions?limit=2", port=self.gateway))
        status, _ = self.call("PATCH", f"/api/sessions/{old}", {"pinned": True}, port=self.gateway)
        self.assertEqual(status, 200)
        listed = self.ids("/api/sessions?limit=2", port=self.gateway)
        self.assertIn(old, listed[2:])
        self.assertIn(old, self.ids("/api/sessions?limit=2&order=recent", key="sessions"))

    def test_an_unpinned_chat_past_the_page_stays_out(self):
        old = self.oldest()
        self.call("PATCH", f"/api/sessions/{old}", {"pinned": True}, port=self.gateway)
        self.call("PATCH", f"/api/sessions/{old}", {"pinned": False}, port=self.gateway)
        self.assertNotIn(old, self.ids("/api/sessions?limit=2", port=self.gateway))

    def test_pinning_a_chat_the_gateway_lacks_is_refused(self):
        status, body = self.call("PATCH", "/api/sessions/nope", {"pinned": True}, port=self.gateway)
        self.assertEqual((status, body["error"]["code"]), (404, "session_not_found"))


if __name__ == "__main__":
    unittest.main()
