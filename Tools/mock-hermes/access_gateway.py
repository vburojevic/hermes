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
Access to Service token with the mock's client ID and secret (--client-id, --client-secret), or to
Browser sign-in.

Without the headers it answers the way Cloudflare Access does: a request that accepts HTML (a
browser, a web view) is redirected to the sign-in page on another origin (--sign-in-port, at
`localhost`), and anything else gets a 403 HTML page. Wrong headers get the same 403. A request
let in gets a `CF_Authorization` cookie, which lets later requests in without the headers, as
Cloudflare's does for a page's own images and scripts.

The sign-in page is a form that takes any email address (no identity provider, no code). It sends
the browser back through the route's `/cdn-cgi/access/authorized`, which sets `CF_Authorization`
(a JWT-shaped token with the email and `exp`) for that origin and redirects to where the browser
was going. Sessions last --session-seconds (a day by default; a minute or so to see one run out).
An expired cookie is refused like a missing one, and a connection a session let in (a stream, a
socket) is cut when the session runs out, so expiry shows mid-reply.

`GET /__mock/leave` on a route, once let in, redirects to the sign-in origin (`/__mock/left`),
which logs whether the token came along: a web view must leave it behind. Every request is logged
as one line, with the token, the cookie, Hermes's key and query secrets redacted.
"""

import argparse
import base64
import datetime
import email.utils
import hashlib
import hmac
import html
import json
import os
import re
import secrets
import socket
import socketserver
import sys
import threading
import time
import urllib.parse

ID_HEADER = "cf-access-client-id"
SECRET_HEADER = "cf-access-client-secret"
SIGN_IN_PATH = "/cdn-cgi/access/login"
AUTHORIZED_PATH = "/cdn-cgi/access/authorized"
COOKIE = "CF_Authorization"
LEAVE_PATH = "/__mock/leave"
LEFT_PATH = "/__mock/left"
SECRET_QUERY = re.compile(r"(token|key|secret|password|auth|sig|ticket|credential)", re.IGNORECASE)

FORBIDDEN_PAGE = b"""<!DOCTYPE html>
<html><head><title>Forbidden | Access</title></head>
<body><h1>Forbidden</h1><p>You don't have permission to view this application.</p>
<p>Mock access gateway</p></body></html>
"""

SIGN_IN_PAGE = """<!DOCTYPE html>
<html><head><title>Sign in | Access</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>body{{font:16px -apple-system,system-ui,sans-serif;max-width:22rem;margin:3rem auto;padding:0 1rem}}
input,button{{font:inherit;width:100%;box-sizing:border-box;padding:.6rem;margin:.4rem 0}}</style></head>
<body><h1>Sign in</h1><p>Sign in with your email to reach this application.</p>{error}
<form method="post" action="{action}"><input type="email" name="email" placeholder="you@example.com" required
autocomplete="email" aria-label="Email"><input type="hidden" name="redirect_url" value="{redirect}">
<button type="submit">Sign in</button></form>
<p>Mock access gateway. Any email signs in.</p></body></html>
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


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


class Sessions:
    """The CF_Authorization cookies handed out, shared by every route. Each is a JWT-shaped token
    signed with a key made at start, carrying the email and when it runs out, as Cloudflare's does."""

    def __init__(self, lifetime):
        self.lock = threading.Lock()
        self.expiry = {}
        self.lifetime = lifetime
        self.key = secrets.token_bytes(32)

    def issue(self, email="service-token@example.com", issuer="mock-access"):
        now = int(time.time())
        expires = now + self.lifetime
        claims = {"aud": ["mock-application"], "email": email, "exp": expires, "iat": now, "nbf": now,
                  "iss": issuer, "sub": hashlib.sha256(email.encode()).hexdigest()[:32], "type": "app",
                  "nonce": secrets.token_urlsafe(12)}
        signing = b64url(json.dumps({"alg": "HS256", "kid": "mock", "typ": "JWT"}).encode()) + "." + \
            b64url(json.dumps(claims, separators=(",", ":")).encode())
        value = signing + "." + b64url(hmac.new(self.key, signing.encode(), hashlib.sha256).digest())
        with self.lock:
            self.expiry[value] = expires
        return value, expires

    def state(self, value):
        """none, ok, expired or wrong."""
        if value is None:
            return "none"
        with self.lock:
            expires = self.expiry.get(value)
        if expires is None:
            return "wrong"
        return "ok" if time.time() < expires else "expired"

    def valid(self, value):
        return self.state(value) == "ok"

    def expires(self, value):
        with self.lock:
            return self.expiry.get(value)


def cookie_header(value, expires):
    when = email.utils.formatdate(expires, usegmt=True)
    return ("Set-Cookie", f"{COOKIE}={value}; Path=/; Expires={when}; HttpOnly; SameSite=Lax")


def safe_path(text):
    """A same-origin path to send the browser back to, or /."""
    if not text.startswith("/") or text.startswith("//") or "\\" in text or any(ord(c) < 0x21 for c in text):
        return "/"
    return text


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
        cookie_state = server.sessions.state(sent_cookie)
        by_cookie = token == "none" and cookie_state == "ok"
        key = "key" if header(headers, "authorization") else "no key"
        kind = request_kind(method, headers)
        where = f"{method} {redact_target(target)} :{server.server_address[1]}"
        note = token_note(token)
        if sent_cookie is not None:
            note += f" cookie=[redacted] ({cookie_state})"
        origin = f"http://{header(headers, 'host') or f'{server.settings.host}:{server.server_address[1]}'}"

        if target.split("?", 1)[0] == AUTHORIZED_PATH:
            self.authorized(target, where)
            return

        if token != "ok" and not by_cookie:
            wants_page = kind == "page" and token == "none"
            if wants_page:
                location = (f"http://localhost:{server.settings.sign_in_port}{SIGN_IN_PATH}"
                            f"?redirect_url={urllib.parse.quote(origin + target, safe='')}")
                answer(client, 302, "Found", [("Location", location), ("Content-Type", "text/html")])
                server.log.write(f"{where} {kind} {note} {key} -> 302 sign-in")
            else:
                answer(client, 403, "Forbidden", [("Content-Type", "text/html; charset=utf-8")], FORBIDDEN_PAGE)
                server.log.write(f"{where} {kind} {note} {key} -> 403")
            return

        # The token passes for this origin only: a token pass gets a session cookie, as
        # Cloudflare's CF_Authorization, so a page's own images and scripts come in with it.
        issued = [cookie_header(*server.sessions.issue())] if token == "ok" else []

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
        # A connection a session let in ends with the session, as the access gateway stops
        # passing it: the app sees a reply stop and its next request refused.
        cut = None
        if by_cookie:
            remaining = server.sessions.expires(sent_cookie) - time.time()
            cut = threading.Timer(max(0, remaining), self.cut, args=(client, upstream, where))
            cut.daemon = True
            cut.start()
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
            if cut:
                cut.cancel()
            for sock in (upstream, client):
                try:
                    sock.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
            upstream.close()

    def authorized(self, target, where):
        """The sign-in page's way back: sets the session cookie for this origin and goes on."""
        server = self.server
        query = urllib.parse.parse_qs(target.partition("?")[2])
        value = (query.get("token") or [None])[0]
        back = safe_path((query.get("redirect_url") or ["/"])[0])
        if server.sessions.state(value) != "ok":
            answer(self.request, 403, "Forbidden", [("Content-Type", "text/html; charset=utf-8")], FORBIDDEN_PAGE)
            server.log.write(f"{where} page sign-in token wrong -> 403")
            return
        answer(self.request, 302, "Found", [("Location", back), ("Content-Type", "text/html"),
                                            cookie_header(value, server.sessions.expires(value))])
        server.log.write(f"{where} page sign-in -> 302 with cookie")

    def cut(self, client, upstream, where):
        self.server.log.write(f"{where} session expired -> connection cut")
        for sock in (upstream, client):
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass

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

    def __init__(self, host, port, log, settings, sessions, routes):
        self.log = log
        self.settings = settings
        self.sessions = sessions
        self.routes = routes
        super().__init__((host, port), SignInHandler)

    def route_origin(self, url):
        """The origin of `url` and its path, when it is one of the routes, or None: the page sends
        a session only to the applications in front of which it stands."""
        parts = urllib.parse.urlsplit(url)
        if parts.scheme != "http" or parts.hostname not in ("127.0.0.1", "localhost") or parts.port not in self.routes:
            return None
        path = parts.path or "/"
        return f"http://{parts.hostname}:{parts.port}", path + (f"?{parts.query}" if parts.query else "")


class SignInHandler(socketserver.BaseRequestHandler):
    def handle(self):
        head, rest = read_head(self.request)
        if head is None:
            return
        first, headers = parse_head(head)
        parts = first.split(" ")
        method = parts[0]
        target = parts[1] if len(parts) > 1 else "/"
        where = f"{method} {redact_target(target)} :{self.server.server_address[1]}"
        # Whether a token followed a page here: it never should.
        note = token_note(token_state(headers, self.server.settings))
        if cookie(headers, COOKIE) is not None:
            note += " cookie=[redacted]"
        if method == "POST" and target.split("?", 1)[0] == SIGN_IN_PATH:
            self.sign_in(headers, rest, where)
            return
        query = urllib.parse.parse_qs(target.partition("?")[2])
        redirect = (query.get("redirect_url") or [""])[0]
        self.page(200, "OK", redirect)
        self.server.log.write(f"{where} sign-in page {note} -> 200")

    def page(self, status, reason, redirect, error=""):
        body = SIGN_IN_PAGE.format(
            error=f'<p role="alert"><strong>{html.escape(error)}</strong></p>' if error else "",
            action=SIGN_IN_PATH, redirect=html.escape(redirect, quote=True),
        ).encode()
        answer(self.request, status, reason, [("Content-Type", "text/html; charset=utf-8")], body)

    def sign_in(self, headers, rest, where):
        length = min(int(header(headers, "content-length") or 0), 16 * 1024)
        body = rest
        while len(body) < length:
            chunk = self.request.recv(length - len(body))
            if not chunk:
                break
            body += chunk
        form = urllib.parse.parse_qs(body[:length].decode("utf-8", "replace"))
        address = (form.get("email") or [""])[0].strip()
        redirect = (form.get("redirect_url") or [""])[0]
        destination = self.server.route_origin(redirect)
        if destination is None:
            self.page(400, "Bad Request", "", "This sign-in link doesn't lead to an application here.")
            self.server.log.write(f"{where} sign-in refused: not a route -> 400")
            return
        if not re.fullmatch(r"[^@\s<>]+@[^@\s<>]+\.[^@\s<>]+", address) or len(address) > 254:
            self.page(400, "Bad Request", redirect, "Enter an email address.")
            self.server.log.write(f"{where} sign-in refused: no email -> 400")
            return
        origin, path = destination
        value, _ = self.server.sessions.issue(address, f"http://localhost:{self.server.server_address[1]}")
        location = f"{origin}{AUTHORIZED_PATH}?token={value}&redirect_url={urllib.parse.quote(path, safe='')}"
        answer(self.request, 302, "Found", [("Location", location), ("Content-Type", "text/html")])
        self.server.log.write(f"{where} signed in -> 302 to {origin}{AUTHORIZED_PATH}")


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
    parser.add_argument("--session-seconds", type=int, default=86400,
                        help="how long a session lasts, from the sign-in page or a token pass (default: a day)")
    parser.add_argument("--log", help="also append the request log to this file")
    settings = parser.parse_args()

    log = Log(settings.log)
    sessions = Sessions(max(1, settings.session_seconds))
    sign_in = SignIn(settings.host, settings.sign_in_port, log, settings, sessions, {port for port, _ in settings.route})
    settings.sign_in_port = sign_in.server_address[1]
    threading.Thread(target=sign_in.serve_forever, daemon=True).start()
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
