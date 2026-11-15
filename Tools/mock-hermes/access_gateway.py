#!/usr/bin/env python3
"""A mock access gateway (Cloudflare Access and the like) in front of the mock gateway and backend.

Each route listens on its own port and passes requests to the mock behind it once they carry the
service token's two headers. It reads only the request's head and then passes bytes through both
ways, so plain calls, event streams, socket upgrades, uploads and downloads all go through
unchanged. It never sees or changes Hermes's own Authorization header, and it drops the token's
headers before the request reaches the mock, as Cloudflare does.

    python3 -I Tools/mock-hermes/backend.py --port 21119 --gateway-port 21642
    python3 -I Tools/mock-hermes/access_gateway.py --route 20642=21642 --route 20119=21119 \\
        --sign-in-port 20999 --log "$TMPDIR/access.log"

Then pair the app with http://127.0.0.1:20642 (and Bot Mode at http://127.0.0.1:20119) and set
Access to Service token with the mock's client ID and secret (--client-id, --client-secret).

Without the headers it answers the way Cloudflare Access does: a request that accepts HTML (a
browser, a web view) is redirected to the sign-in page on another origin (--sign-in-port, at
`localhost`), and anything else gets a 403 HTML page. Wrong headers get the same 403. A request
let in gets a `CF_Authorization` cookie, which lets later requests in without the headers, as
Cloudflare's does for a page's own images and scripts. `GET /__mock/leave` on a route, once let
in, redirects to the sign-in origin (`/__mock/left`), which logs whether the token came along: a
web view must leave it behind. Every request is logged as one line, with the token, the cookie,
Hermes's key and query secrets redacted.
"""

import argparse
import datetime
import os
import re
import secrets
import socket
import socketserver
import sys
import threading
import urllib.parse

ID_HEADER = "cf-access-client-id"
SECRET_HEADER = "cf-access-client-secret"
SIGN_IN_PATH = "/cdn-cgi/access/login"
COOKIE = "CF_Authorization"
LEAVE_PATH = "/__mock/leave"
LEFT_PATH = "/__mock/left"
SECRET_QUERY = re.compile(r"(token|key|secret|password|auth|sig|ticket|credential)", re.IGNORECASE)

FORBIDDEN_PAGE = b"""<!DOCTYPE html>
<html><head><title>Forbidden | Access</title></head>
<body><h1>Forbidden</h1><p>You don't have permission to view this application.</p>
<p>Mock access gateway</p></body></html>
"""

SIGN_IN_PAGE = b"""<!DOCTYPE html>
<html><head><title>Sign in | Access</title>
<meta name="viewport" content="width=device-width, initial-scale=1"></head>
<body><h1>Sign in</h1><p>Get a login code sent to your email.</p>
<form><input type="email" placeholder="you@example.com"><button>Send me a code</button></form>
<p>Mock access gateway</p></body></html>
"""


class Log:
    """One line per request, to stdout and, with --log, to a file. Never a secret's value."""

    def __init__(self, path):
        self.path = path
        self.lock = threading.Lock()

    def write(self, line):
        stamp = datetime.datetime.now().strftime("%H:%M:%S.%f")[:-3]
        line = f"{stamp} {line}"
        with self.lock:
            print(line, flush=True)
            if self.path:
                with open(self.path, "a", encoding="utf-8") as log:
                    log.write(line + "\n")


def redact_target(target):
    """The request target with the values of secret-looking query fields hidden."""
    path, _, query = target.partition("?")
    if not query:
        return path
    fields = []
    for part in query.split("&"):
        name, eq, value = part.partition("=")
        fields.append(f"{name}=[redacted]" if eq and SECRET_QUERY.search(urllib.parse.unquote(name)) else part)
    return f"{path}?{'&'.join(fields)}"


def read_head(sock):
    """The bytes up to and including the blank line ending a head, and whatever followed them."""
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = sock.recv(65536)
        if not chunk:
            return None, b""
        data += chunk
        if len(data) > 256 * 1024:
            return None, b""
    head, _, rest = data.partition(b"\r\n\r\n")
    return head + b"\r\n\r\n", rest


def parse_head(head):
    lines = head.decode("latin-1").split("\r\n")
    first = lines[0]
    headers = []
    for line in lines[1:]:
        if not line:
            break
        name, _, value = line.partition(":")
        headers.append((name.strip(), value.strip()))
    return first, headers


def header(headers, name):
    return next((value for key, value in headers if key.lower() == name), None)


def cookie(headers, name):
    """A cookie's value from the request's Cookie headers."""
    for key, value in headers:
        if key.lower() != "cookie":
            continue
        for part in value.split(";"):
            field, eq, content = part.strip().partition("=")
            if eq and field == name:
                return content
    return None


def token_state(headers, settings):
    """none, ok or wrong, for the service token's two headers."""
    sent_id = header(headers, ID_HEADER)
    sent_secret = header(headers, SECRET_HEADER)
    if sent_id is None and sent_secret is None:
        return "none"
    return "ok" if sent_id == settings.client_id and sent_secret == settings.client_secret else "wrong"


def token_note(state):
    return "token=none" if state == "none" else f"token=id:[redacted] secret:[redacted] ({state})"


def build_head(first, headers):
    return (first + "\r\n" + "".join(f"{k}: {v}\r\n" for k, v in headers) + "\r\n").encode("latin-1")


def answer(sock, status, reason, headers, body=b""):
    head = [("Content-Length", str(len(body))), ("Connection", "close")] + headers
    sock.sendall(build_head(f"HTTP/1.1 {status} {reason}", head) + body)


def request_kind(method, headers):
    """What kind of request it is, for the log."""
    if (header(headers, "upgrade") or "").lower() == "websocket":
        return "socket"
    if "text/event-stream" in (header(headers, "accept") or ""):
        return "stream"
    content_type = (header(headers, "content-type") or "").lower()
    if method in ("POST", "PUT") and ("multipart/" in content_type or "octet-stream" in content_type):
        return "upload"
    if "text/html" in (header(headers, "accept") or ""):
        return "page"
    return "call"


def response_kind(kind, headers):
    """Names a download or an event stream by what came back."""
    content_type = (header(headers, "content-type") or "").lower()
    if kind == "call" and "text/event-stream" in content_type:
        return "stream"
    disposition = (header(headers, "content-disposition") or "").lower()
    if kind in ("call", "page") and (disposition.startswith("attachment") or content_type.startswith(("image/", "application/octet-stream"))):
        return "download"
    return kind


class Proxy(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, port, upstream, settings, log, sessions):
        self.upstream = upstream
        self.settings = settings
        self.log = log
        self.sessions = sessions
        super().__init__((settings.host, port), ProxyHandler)


class Sessions:
    """The CF_Authorization cookies handed out, shared by every route."""

    def __init__(self):
        self.lock = threading.Lock()
        self.values = set()

    def issue(self):
        value = secrets.token_urlsafe(24)
        with self.lock:
            self.values.add(value)
        return value

    def valid(self, value):
        with self.lock:
            return value is not None and value in self.values


class ProxyHandler(socketserver.BaseRequestHandler):
    def handle(self):
        server = self.server
        client = self.request
        head, rest = read_head(client)
        if head is None:
            return
        first, headers = parse_head(head)
        try:
            method, target, version = first.split(" ", 2)
        except ValueError:
            answer(client, 400, "Bad Request", [])
            return
        token = token_state(headers, server.settings)
        sent_cookie = cookie(headers, COOKIE)
        by_cookie = token == "none" and server.sessions.valid(sent_cookie)
        key = "key" if header(headers, "authorization") else "no key"
        kind = request_kind(method, headers)
        where = f"{method} {redact_target(target)} :{server.server_address[1]}"
        note = token_note(token)
        if sent_cookie is not None:
            note += f" cookie=[redacted] ({'ok' if server.sessions.valid(sent_cookie) else 'wrong'})"

        if token != "ok" and not by_cookie:
            wants_page = kind == "page" and token == "none"
            if wants_page:
                location = (f"http://localhost:{server.settings.sign_in_port}{SIGN_IN_PATH}"
                            f"?redirect_url={urllib.parse.quote(target, safe='')}")
                answer(client, 302, "Found", [("Location", location), ("Content-Type", "text/html")])
                server.log.write(f"{where} {kind} {note} {key} -> 302 sign-in")
            else:
                answer(client, 403, "Forbidden", [("Content-Type", "text/html; charset=utf-8")], FORBIDDEN_PAGE)
                server.log.write(f"{where} {kind} {note} {key} -> 403")
            return

        # The token passes for this origin only: a token pass gets a session cookie, as
        # Cloudflare's CF_Authorization, so a page's own images and scripts come in with it.
        issued = [("Set-Cookie", f"{COOKIE}={server.sessions.issue()}; Path=/; HttpOnly; SameSite=Lax")] if token == "ok" else []

        if target.split("?", 1)[0] == LEAVE_PATH:
            location = f"http://localhost:{server.settings.sign_in_port}{LEFT_PATH}"
            answer(client, 302, "Found", [("Location", location), ("Content-Type", "text/html")] + issued)
            server.log.write(f"{where} page {note} {key} -> 302 to the sign-in origin")
            return

        # The token's headers stop here; Hermes's key and everything else go through.
        # One request per connection, so every request is checked and logged; a socket keeps its upgrade.
        dropped = (ID_HEADER, SECRET_HEADER) if kind == "socket" else (ID_HEADER, SECRET_HEADER, "connection")
        forwarded = [(k, v) for k, v in headers if k.lower() not in dropped]
        if kind != "socket":
            forwarded.append(("Connection", "close"))
        try:
            upstream = socket.create_connection(server.upstream, timeout=10)
        except OSError:
            answer(client, 502, "Bad Gateway", [("Content-Type", "text/html; charset=utf-8")], b"<h1>Bad gateway</h1>")
            server.log.write(f"{where} {kind} {note} {key} -> 502 (the mock behind is down)")
            return
        upstream.settimeout(None)
        try:
            upstream.sendall(build_head(f"{method} {target} {version}", forwarded) + rest)
            # The body (an upload's included) goes on in the background while the answer comes back.
            upload = threading.Thread(target=self.pass_body, args=(client, upstream), daemon=True)
            upload.start()
            reply, tail = read_head(upstream)
            if reply is None:
                server.log.write(f"{where} {kind} {note} {key} -> no answer")
                return
            status_line, reply_headers = parse_head(reply)
            status = status_line.split(" ", 2)[1] if " " in status_line else "?"
            kind = response_kind(kind, reply_headers)
            server.log.write(f"{where} {kind} {note} {key} -> {status}")
            if status != "101":
                reply_headers = [(k, v) for k, v in reply_headers if k.lower() != "connection"] + [("Connection", "close")]
                reply = build_head(status_line, reply_headers + issued)
            client.sendall(reply + tail)
            while True:
                data = upstream.recv(65536)
                if not data:
                    break
                client.sendall(data)
        except OSError:
            pass
        finally:
            for sock in (upstream, client):
                try:
                    sock.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
            upstream.close()

    @staticmethod
    def pass_body(client, upstream):
        try:
            while True:
                data = client.recv(65536)
                if not data:
                    break
                upstream.sendall(data)
        except OSError:
            pass


class SignIn(socketserver.ThreadingTCPServer):
    """The access gateway's sign-in page, on its own origin."""

    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, host, port, log, settings):
        self.log = log
        self.settings = settings
        super().__init__((host, port), SignInHandler)


class SignInHandler(socketserver.BaseRequestHandler):
    def handle(self):
        head, _ = read_head(self.request)
        if head is None:
            return
        first, headers = parse_head(head)
        parts = first.split(" ")
        target = parts[1] if len(parts) > 1 else "/"
        answer(self.request, 200, "OK", [("Content-Type", "text/html; charset=utf-8")], SIGN_IN_PAGE)
        # Whether a token followed a page here: it never should.
        note = token_note(token_state(headers, self.server.settings))
        if cookie(headers, COOKIE) is not None:
            note += " cookie=[redacted]"
        self.server.log.write(f"{parts[0]} {redact_target(target)} :{self.server.server_address[1]} sign-in page {note} -> 200")


def parse_route(text):
    listen, sep, upstream = text.partition("=")
    if not sep:
        raise argparse.ArgumentTypeError("a route is LISTEN-PORT=UPSTREAM-PORT or LISTEN-PORT=HOST:PORT")
    host, _, port = upstream.rpartition(":")
    return int(listen), (host or "127.0.0.1", int(port))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--route", action="append", type=parse_route, required=True, metavar="PORT=UPSTREAM",
                        help="listen on PORT and pass requests to UPSTREAM (a port, or host:port); repeatable")
    parser.add_argument("--sign-in-port", type=int, default=0, help="the sign-in page's port (default: any free one)")
    parser.add_argument("--client-id", default="mock-client.access")
    parser.add_argument("--client-secret", default="mock-secret-0123456789abcdef")
    parser.add_argument("--log", help="also append the request log to this file")
    settings = parser.parse_args()

    log = Log(settings.log)
    sign_in = SignIn(settings.host, settings.sign_in_port, log, settings)
    settings.sign_in_port = sign_in.server_address[1]
    threading.Thread(target=sign_in.serve_forever, daemon=True).start()
    sessions = Sessions()
    proxies = [Proxy(port, upstream, settings, log, sessions) for port, upstream in settings.route]
    for proxy in proxies[1:]:
        threading.Thread(target=proxy.serve_forever, daemon=True).start()
    for proxy in proxies:
        upstream = f"{proxy.upstream[0]}:{proxy.upstream[1]}"
        print(f"access gateway on {settings.host}:{proxy.server_address[1]} -> {upstream}", file=sys.stderr, flush=True)
    print(f"sign-in page on localhost:{settings.sign_in_port}", file=sys.stderr, flush=True)
    try:
        proxies[0].serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
