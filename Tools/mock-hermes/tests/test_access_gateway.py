"""The mock access gateway (access_gateway.py, `docs/connecting-and-voice.md` §11): refusals shaped
like Cloudflare Access's, every kind of request passed through with the token's headers dropped
and Hermes's key kept, a sign-in page whose session is scoped to its origin and runs out, and a
log that never holds a secret.

Starts its own upstream and access gateway on free ports, stdlib only:
    python3 -I -m unittest discover -s Tools/mock-hermes/tests
"""

import base64
import email.utils
import http.client
import http.server
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
ACCESS_GATEWAY = os.path.join(os.path.dirname(HERE), "access_gateway.py")
CLIENT_ID = "test-client.access"
CLIENT_SECRET = "test-secret-do-not-log-0123"
KEY = "test-hermes-key-do-not-log"
TOKEN = {"CF-Access-Client-Id": CLIENT_ID, "CF-Access-Client-Secret": CLIENT_SECRET}


def free_port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


class Upstream(http.server.BaseHTTPRequestHandler):
    """Stands in for Hermes: echoes what reached it, streams events, takes uploads, serves files and
    upgrades sockets that echo."""

    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def reply(self, status, body, content_type="application/json", extra=()):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        for name, value in extra:
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(body)

    def seen(self):
        return json.dumps({"path": self.path, "headers": {k.lower(): v for k, v in self.headers.items()}}).encode()

    def do_GET(self):
        if self.path == "/events":
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            for n in range(3):
                self.wfile.write(f"data: {n}\n\n".encode())
                self.wfile.flush()
                time.sleep(0.05)
            self.close_connection = True
        elif self.path == "/forever":
            # A reply that outlasts a short session, so the access gateway has to cut it.
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            try:
                for n in range(200):
                    self.wfile.write(f"data: {n}\n\n".encode())
                    self.wfile.flush()
                    time.sleep(0.1)
            except OSError:
                pass
            self.close_connection = True
        elif self.path == "/file":
            self.reply(200, bytes(range(256)) * 400, "application/octet-stream",
                       [("Content-Disposition", 'attachment; filename="file.bin"')])
        elif self.path == "/socket":
            self.send_response(101, "Switching Protocols")
            self.send_header("Upgrade", "websocket")
            self.send_header("Connection", "Upgrade")
            self.end_headers()
            self.wfile.flush()
            # Echoes raw bytes: the access gateway passes frames through without reading them.
            while data := self.connection.recv(1024):
                self.connection.sendall(data)
            self.close_connection = True
        else:
            self.reply(200, self.seen())

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)
        self.reply(200, json.dumps({"received": len(body), "first": body[:4].hex()}).encode())


class GatewayTestCase(unittest.TestCase):
    session_seconds = 86400

    @classmethod
    def setUpClass(cls):
        cls.upstream = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Upstream)
        threading.Thread(target=cls.upstream.serve_forever, daemon=True).start()
        cls.port = free_port()
        cls.sign_in_port = free_port()
        cls.log_dir = tempfile.TemporaryDirectory()
        cls.log_path = os.path.join(cls.log_dir.name, "access.log")
        cls.process = subprocess.Popen(
            [sys.executable, "-I", ACCESS_GATEWAY, "--route", f"{cls.port}={cls.upstream.server_address[1]}",
             "--sign-in-port", str(cls.sign_in_port), "--client-id", CLIENT_ID, "--client-secret", CLIENT_SECRET,
             "--session-seconds", str(cls.session_seconds), "--log", cls.log_path],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        deadline = time.time() + 10
        while time.time() < deadline:
            try:
                socket.create_connection(("127.0.0.1", cls.port), timeout=1).close()
                socket.create_connection(("127.0.0.1", cls.sign_in_port), timeout=1).close()
                break
            except OSError:
                time.sleep(0.1)

    @classmethod
    def tearDownClass(cls):
        cls.process.terminate()
        cls.process.wait(timeout=10)
        cls.upstream.shutdown()
        cls.log_dir.cleanup()

    def request(self, method, path, headers=None, body=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        connection.request(method, path, body=body, headers=headers or {})
        response = connection.getresponse()
        data = response.read()
        connection.close()
        return response, data

    def sign_in_request(self, method, path, body=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.sign_in_port, timeout=10)
        headers = {"Content-Type": "application/x-www-form-urlencoded"} if body is not None else {}
        connection.request(method, path, body=body, headers=headers)
        response = connection.getresponse()
        data = response.read()
        connection.close()
        return response, data

    def sign_in(self, address="person@example.com", back="/v1/models"):
        """Goes through the sign-in page as a browser would; answers the cookie's Set-Cookie line."""
        response, _ = self.request("GET", back, {"Accept": "text/html", "Host": f"127.0.0.1:{self.port}"})
        self.assertEqual(response.status, 302)
        page_path = response.getheader("Location").split(str(self.sign_in_port), 1)[1]
        redirect = urllib.parse.parse_qs(urllib.parse.urlsplit(page_path).query)["redirect_url"][0]
        self.assertEqual(redirect, f"http://127.0.0.1:{self.port}{back}")
        form = urllib.parse.urlencode({"email": address, "redirect_url": redirect})
        response, _ = self.sign_in_request("POST", "/cdn-cgi/access/login", form)
        self.assertEqual(response.status, 302)
        authorized = response.getheader("Location")
        self.assertTrue(authorized.startswith(f"http://127.0.0.1:{self.port}/cdn-cgi/access/authorized?token="))
        response, _ = self.request("GET", authorized.split(str(self.port), 1)[1], {"Accept": "text/html"})
        self.assertEqual(response.status, 302)
        self.assertEqual(response.getheader("Location"), back)
        return response.getheader("Set-Cookie")

    def log_text(self):
        time.sleep(0.2)
        with open(self.log_path, encoding="utf-8") as log:
            return log.read()


class AccessGatewayTests(GatewayTestCase):
    def test_refuses_a_call_without_the_token_with_an_html_403(self):
        response, body = self.request("GET", "/v1/models", {"Authorization": f"Bearer {KEY}"})
        self.assertEqual(response.status, 403)
        self.assertIn("text/html", response.getheader("Content-Type"))
        self.assertIn(b"Forbidden", body)

    def test_redirects_a_page_to_sign_in_on_another_origin(self):
        response, _ = self.request("GET", "/artifact/index.html", {"Accept": "text/html,*/*"})
        self.assertEqual(response.status, 302)
        location = response.getheader("Location")
        self.assertTrue(location.startswith(f"http://localhost:{self.sign_in_port}/cdn-cgi/access/login"))
        page = http.client.HTTPConnection("127.0.0.1", self.sign_in_port, timeout=10)
        page.request("GET", location.split(str(self.sign_in_port), 1)[1])
        answer = page.getresponse()
        self.assertEqual(answer.status, 200)
        self.assertIn(b"Sign in", answer.read())

    def test_refuses_a_wrong_token(self):
        response, _ = self.request("GET", "/v1/models", {"CF-Access-Client-Id": CLIENT_ID,
                                                          "CF-Access-Client-Secret": "wrong", "Accept": "text/html"})
        self.assertEqual(response.status, 403)

    def test_passes_a_call_with_the_key_and_without_the_token(self):
        response, body = self.request("GET", "/v1/models?token=abc", {**TOKEN, "Authorization": f"Bearer {KEY}"})
        self.assertEqual(response.status, 200)
        seen = json.loads(body)
        self.assertEqual(seen["headers"]["authorization"], f"Bearer {KEY}")
        self.assertNotIn("cf-access-client-id", seen["headers"])
        self.assertNotIn("cf-access-client-secret", seen["headers"])

    def test_streams_events(self):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        connection.request("GET", "/events", headers={**TOKEN, "Accept": "text/event-stream"})
        response = connection.getresponse()
        self.assertEqual(response.status, 200)
        self.assertEqual(response.read(), b"data: 0\n\ndata: 1\n\ndata: 2\n\n")
        connection.close()

    def test_passes_an_upload_and_a_download(self):
        upload = os.urandom(300_000)
        response, body = self.request("POST", "/upload", {**TOKEN, "Content-Type": "application/octet-stream"}, upload)
        self.assertEqual(response.status, 200)
        self.assertEqual(json.loads(body), {"received": len(upload), "first": upload[:4].hex()})
        response, body = self.request("GET", "/file", TOKEN)
        self.assertEqual(response.status, 200)
        self.assertEqual(body, bytes(range(256)) * 400)

    def test_upgrades_a_socket_and_passes_its_bytes(self):
        sock = socket.create_connection(("127.0.0.1", self.port), timeout=10)
        sock.sendall(("GET /socket HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                      f"CF-Access-Client-Id: {CLIENT_ID}\r\nCF-Access-Client-Secret: {CLIENT_SECRET}\r\n\r\n").encode())
        head = b""
        while b"\r\n\r\n" not in head:
            head += sock.recv(1)
        self.assertIn(b" 101 ", head)
        sock.sendall(b"ping")
        echoed = b""
        while len(echoed) < 4:
            echoed += sock.recv(4)
        self.assertEqual(echoed, b"ping")
        sock.close()

    def test_refuses_a_socket_without_the_token(self):
        sock = socket.create_connection(("127.0.0.1", self.port), timeout=10)
        sock.sendall(b"GET /socket HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n")
        self.assertIn(b" 403 ", sock.recv(64))
        sock.close()

    def test_a_token_pass_sets_a_cookie_that_lets_later_requests_in(self):
        response, _ = self.request("GET", "/v1/models", TOKEN)
        self.assertEqual(response.status, 200)
        set_cookie = response.getheader("Set-Cookie")
        self.assertTrue(set_cookie.startswith("CF_Authorization="))
        value = set_cookie.split(";", 1)[0]
        response, _ = self.request("GET", "/picture.png", {"Cookie": f"theme=dark; {value}"})
        self.assertEqual(response.status, 200)
        response, _ = self.request("GET", "/picture.png", {"Cookie": "CF_Authorization=made-up"})
        self.assertEqual(response.status, 403)
        with open(self.log_path, encoding="utf-8") as log:
            text = log.read()
        self.assertIn("cookie=[redacted] (ok)", text)
        self.assertIn("cookie=[redacted] (wrong)", text)
        self.assertNotIn(value.split("=", 1)[1], text)

    def test_leave_redirects_to_the_sign_in_origin_which_logs_the_token(self):
        response, _ = self.request("GET", "/__mock/leave", {**TOKEN, "Accept": "text/html"})
        self.assertEqual(response.status, 302)
        location = response.getheader("Location")
        self.assertEqual(location, f"http://localhost:{self.sign_in_port}/__mock/left")
        # A client that follows without the token, as it should, and one that takes it along.
        for headers in ({}, TOKEN):
            page = http.client.HTTPConnection("127.0.0.1", self.sign_in_port, timeout=10)
            page.request("GET", "/__mock/left", headers=headers)
            self.assertEqual(page.getresponse().status, 200)
            page.close()
        time.sleep(0.2)
        with open(self.log_path, encoding="utf-8") as log:
            lines = [line for line in log if "/__mock/left" in line]
        self.assertIn("sign-in page token=none -> 200", lines[0])
        self.assertIn("sign-in page token=id:[redacted] secret:[redacted] (ok) -> 200", lines[1])
        self.assertNotIn(CLIENT_SECRET, "".join(lines))

    def test_the_log_names_every_request_and_holds_no_secret(self):
        self.request("GET", "/v1/models?api_key=hidden-value", {**TOKEN, "Authorization": f"Bearer {KEY}"})
        self.request("GET", "/v1/models", {"Authorization": f"Bearer {KEY}"})
        time.sleep(0.2)
        with open(self.log_path, encoding="utf-8") as log:
            text = log.read()
        self.assertIn("token=id:[redacted] secret:[redacted] (ok)", text)
        self.assertIn("token=none key -> 403", text)
        self.assertIn("api_key=[redacted]", text)
        for secret in (CLIENT_ID, CLIENT_SECRET, KEY, "hidden-value"):
            self.assertNotIn(secret, text)


    def test_the_sign_in_page_is_a_form_that_carries_the_way_back(self):
        response, body = self.sign_in_request(
            "GET", "/cdn-cgi/access/login?redirect_url=" + urllib.parse.quote(f'http://127.0.0.1:{self.port}/"><b>'))
        self.assertEqual(response.status, 200)
        self.assertIn(b'<form method="post" action="/cdn-cgi/access/login">', body)
        self.assertIn(b'name="email"', body)
        self.assertIn(b"&quot;&gt;&lt;b&gt;", body)
        self.assertNotIn(b'"><b>', body)

    def test_signing_in_sets_a_session_cookie_for_the_origin_with_an_expiry(self):
        set_cookie = self.sign_in("person@example.com", "/v1/models")
        attributes = [part.strip() for part in set_cookie.split(";")]
        name, value = attributes[0].split("=", 1)
        self.assertEqual(name, "CF_Authorization")
        self.assertIn("Path=/", attributes)
        self.assertIn("HttpOnly", attributes)
        self.assertFalse(any(part.lower().startswith("domain=") for part in attributes))
        expires = next(part for part in attributes if part.startswith("Expires="))
        when = email.utils.parsedate_to_datetime(expires.split("=", 1)[1]).timestamp()
        self.assertAlmostEqual(when, time.time() + self.session_seconds, delta=30)
        payload = value.split(".")[1]
        claims = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
        self.assertEqual(claims["email"], "person@example.com")
        self.assertAlmostEqual(claims["exp"], when, delta=1)
        response, body = self.request("GET", "/v1/models", {"Cookie": f"CF_Authorization={value}",
                                                             "Authorization": f"Bearer {KEY}"})
        self.assertEqual(response.status, 200)
        self.assertEqual(json.loads(body)["headers"]["authorization"], f"Bearer {KEY}")
        text = self.log_text()
        self.assertIn("signed in -> 302", text)
        self.assertIn("page sign-in -> 302 with cookie", text)
        self.assertNotIn(value, text)
        self.assertNotIn("person@example.com", text)

    def test_signing_in_refuses_a_way_back_to_another_application(self):
        for redirect in ("http://evil.example.com/", f"http://127.0.0.1:{self.sign_in_port}/", "javascript:alert(1)"):
            form = urllib.parse.urlencode({"email": "person@example.com", "redirect_url": redirect})
            response, _ = self.sign_in_request("POST", "/cdn-cgi/access/login", form)
            self.assertEqual(response.status, 400, redirect)
        form = urllib.parse.urlencode({"email": "not an address", "redirect_url": f"http://127.0.0.1:{self.port}/"})
        response, body = self.sign_in_request("POST", "/cdn-cgi/access/login", form)
        self.assertEqual(response.status, 400)
        self.assertIn(b"Enter an email address.", body)

    def test_the_way_back_stays_on_the_origin_and_needs_a_real_token(self):
        set_cookie = self.sign_in()
        value = set_cookie.split(";", 1)[0].split("=", 1)[1]
        for back in ("//evil.example.com/", "https://evil.example.com/", "/\\evil.example.com"):
            response, _ = self.request(
                "GET", f"/cdn-cgi/access/authorized?token={value}&redirect_url={urllib.parse.quote(back, safe='')}")
            self.assertEqual(response.status, 302)
            self.assertEqual(response.getheader("Location"), "/")
        response, _ = self.request("GET", "/cdn-cgi/access/authorized?token=made-up&redirect_url=/")
        self.assertEqual(response.status, 403)
        self.assertIsNone(response.getheader("Set-Cookie"))


class ExpiringSessionTests(GatewayTestCase):
    """Sessions that run out in two seconds, as `--session-seconds` sets them for a test."""

    session_seconds = 2

    def test_an_expired_session_is_refused_like_a_missing_one(self):
        value = self.sign_in().split(";", 1)[0].split("=", 1)[1]
        response, _ = self.request("GET", "/v1/models", {"Cookie": f"CF_Authorization={value}"})
        self.assertEqual(response.status, 200)
        time.sleep(self.session_seconds + 0.5)
        response, _ = self.request("GET", "/v1/models", {"Cookie": f"CF_Authorization={value}"})
        self.assertEqual(response.status, 403)
        response, _ = self.request("GET", "/v1/models", {"Cookie": f"CF_Authorization={value}", "Accept": "text/html"})
        self.assertEqual(response.status, 302)
        self.assertIn("/cdn-cgi/access/login", response.getheader("Location"))
        self.assertIn("cookie=[redacted] (expired)", self.log_text())

    def test_a_stream_a_session_let_in_is_cut_when_it_runs_out(self):
        value = self.sign_in().split(";", 1)[0].split("=", 1)[1]
        started = time.time()
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=15)
        connection.request("GET", "/forever", headers={"Cookie": f"CF_Authorization={value}"})
        response = connection.getresponse()
        self.assertEqual(response.status, 200)
        try:
            received = response.read()
        except http.client.IncompleteRead as error:
            received = error.partial
        connection.close()
        self.assertLess(time.time() - started, self.session_seconds + 3)
        self.assertIn(b"data: 0", received)
        self.assertNotIn(b"data: 199", received)
        self.assertIn("session expired -> connection cut", self.log_text())


if __name__ == "__main__":
    unittest.main()
