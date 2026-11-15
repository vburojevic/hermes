#!/usr/bin/env python3
"""A mock TLS proxy that asks for a client certificate, in front of the mock gateway and backend.

Like nginx's `ssl_verify_client on` or Caddy's `client_auth require_and_verify`: each route
listens with TLS on its own port, turns away a device without a certificate its CA signed, and
passes everything else to the mock behind it (plain HTTP) unchanged: calls, event streams, socket
upgrades, uploads and downloads. It never reads or changes Hermes's own headers.

    python3 -I Tools/mock-hermes/backend.py --port 27119 --gateway-port 27642
    python3 -I Tools/mock-hermes/mtls_proxy.py --route 25642=27642 --route 25119=27119 \\
        --certs "$TMPDIR/mtls" --log "$TMPDIR/mtls.log"

It makes its certificates at start, with the openssl command, in the --certs folder (a new
temporary folder when none is given), and reuses them when that folder already has them, so a
simulator that trusts the CA keeps trusting it across restarts:

    ca.pem                  the root CA, the only one the proxy trusts. Trust it on a simulator
                            with `xcrun simctl keychain <UDID> add-root-cert ca.pem`.
    issuing-ca.pem          the intermediate the root signed, which issues the client
                            certificates, as most company CAs do. The .p12 files carry it, so the
                            proxy lets a device in only when it sends the intermediate too.
    client.p12              a client certificate the proxy lets in (password: --password).
    expired.p12             one that ran out, from the same intermediate.
    other.p12               a current one from a CA the proxy doesn't trust.
    server.pem, *.key       the proxy's own certificate (127.0.0.1 and localhost) and the keys.

Nothing here is committed; the keys exist only in that folder. Then pair the app with
https://127.0.0.1:25642 (Bot Mode at https://127.0.0.1:25119) and import client.p12 in Access.

Every connection is logged as one line: the certificate the proxy verified (its subject, issuer
and expiry), or why it turned the device away. Every request is logged after it, as the access
gateway logs them, with Hermes's key and query secrets redacted. Put access_gateway.py behind it
(`--route 25642=26642`, the access gateway on 26642 in front of the mock) to need both a service
token and a certificate.

`--keep-alive` keeps each connection open for as many requests as the device sends on it, as nginx
does, passing the bytes through without reading them: the certificate is asked for once per
connection, so it shows whether a check reaches the proxy on a connection of its own. Requests
aren't logged then, only each connection and when it closes.
"""

import argparse
import datetime
import importlib.util
import os
import pathlib
import socket
import socketserver
import ssl
import subprocess
import sys
import tempfile
import threading


def load_access_gateway():
    """access_gateway.py: the request head parsing, kinds and log this proxy shares."""
    module = sys.modules.get("mock_access_gateway")
    if module is None:
        path = pathlib.Path(__file__).resolve().parent / "access_gateway.py"
        spec = importlib.util.spec_from_file_location("mock_access_gateway", path)
        module = importlib.util.module_from_spec(spec)
        sys.modules["mock_access_gateway"] = module
        spec.loader.exec_module(module)
    return module


gateway = load_access_gateway()

CA_CONFIG = """\
[ca]
default_ca = mock

[mock]
dir = {dir}
database = $dir/{name}-index.txt
serial = $dir/{name}-serial.txt
new_certs_dir = $dir/{name}-issued
default_md = sha256
policy = anything
unique_subject = no
copy_extensions = none

[anything]
commonName = supplied
organizationName = optional

[root]
basicConstraints = critical, CA:TRUE
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash

[intermediate]
basicConstraints = critical, CA:TRUE, pathlen:0
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid

[server]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = IP:127.0.0.1, DNS:localhost
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid

[client]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = clientAuth
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid
"""


def stamp(moment):
    return moment.strftime("%Y%m%d%H%M%SZ")


class Certificates:
    """Makes and keeps the throwaway CAs and certificates, with the openssl command."""

    def __init__(self, folder, openssl, password):
        self.folder = pathlib.Path(folder)
        self.openssl = openssl
        self.password = password

    def path(self, name):
        return str(self.folder / name)

    def run(self, *args):
        result = subprocess.run([self.openssl, *args], capture_output=True, text=True)
        if result.returncode != 0:
            raise SystemExit(f"openssl {args[0]} failed: {result.stderr.strip()}")

    def ensure(self):
        """Makes whatever the folder is missing; a folder that has them all is left as it is."""
        wanted = ["ca.pem", "issuing-ca.pem", "server.pem", "server.key", "client.p12", "expired.p12", "other.p12"]
        if all((self.folder / name).exists() for name in wanted):
            return False
        self.folder.mkdir(parents=True, exist_ok=True)
        os.chmod(self.folder, 0o700)
        now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)
        day = datetime.timedelta(days=1)
        self.authority("ca", "Hermes Mock CA", now - 90 * day, now + 90 * day)
        self.authority("other-ca", "Somebody Else's CA", now - 90 * day, now + 90 * day)
        self.issue("ca", "issuing-ca", "Hermes Mock Issuing CA", "intermediate", now - 90 * day, now + 60 * day)
        self.issue("ca", "server", "127.0.0.1", "server", now - day, now + 30 * day)
        self.issue("issuing-ca", "client", "Home Server Device", "client", now - day, now + 30 * day)
        self.issue("issuing-ca", "expired", "Home Server Device", "client", now - 60 * day, now - 2 * day)
        self.issue("other-ca", "other", "Home Server Device", "client", now - day, now + 30 * day)
        for name, authority in (("client", "issuing-ca"), ("expired", "issuing-ca"), ("other", "other-ca")):
            self.bundle(name, authority)
        return True

    def config(self, name):
        """The openssl ca settings for one CA, with its own index, serial and issued folder."""
        path = self.folder / f"{name}.cnf"
        path.write_text(CA_CONFIG.format(dir=self.folder, name=name), encoding="utf-8")
        (self.folder / f"{name}-index.txt").touch()
        serial = self.folder / f"{name}-serial.txt"
        if not serial.exists():
            serial.write_text(os.urandom(8).hex().upper() + "\n", encoding="utf-8")
        (self.folder / f"{name}-issued").mkdir(exist_ok=True)
        return str(path)

    def request(self, name, common_name):
        self.run("req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", self.path(f"{name}.key"),
                 "-out", self.path(f"{name}.csr"), "-subj", f"/O=Hermes Mock/CN={common_name}")
        os.chmod(self.path(f"{name}.key"), 0o600)

    def authority(self, name, common_name, start, end):
        self.request(name, common_name)
        self.run("ca", "-batch", "-notext", "-selfsign", "-config", self.config(name),
                 "-keyfile", self.path(f"{name}.key"), "-in", self.path(f"{name}.csr"),
                 "-out", self.path(f"{name}.pem"), "-extensions", "root",
                 "-startdate", stamp(start), "-enddate", stamp(end))

    def issue(self, authority, name, common_name, kind, start, end):
        self.request(name, common_name)
        self.run("ca", "-batch", "-notext", "-config", self.config(authority),
                 "-cert", self.path(f"{authority}.pem"), "-keyfile", self.path(f"{authority}.key"),
                 "-in", self.path(f"{name}.csr"), "-out", self.path(f"{name}.pem"), "-extensions", kind,
                 "-startdate", stamp(start), "-enddate", stamp(end))

    def bundle(self, name, authority):
        # SHA-1 and 3DES, the protection every iPhone and Mac opens, from OpenSSL and LibreSSL alike.
        self.run("pkcs12", "-export", "-inkey", self.path(f"{name}.key"), "-in", self.path(f"{name}.pem"),
                 "-certfile", self.path(f"{authority}.pem"), "-name", "Home Server Device",
                 "-out", self.path(f"{name}.p12"), "-passout", f"pass:{self.password}",
                 "-certpbe", "PBE-SHA1-3DES", "-keypbe", "PBE-SHA1-3DES", "-macalg", "sha1")


def name_of(fields):
    """A certificate name from ssl's getpeercert(), as CN (or O)."""
    values = dict(pair for rdn in fields for pair in rdn)
    return values.get("commonName") or values.get("organizationName") or "?"


def refusal(error):
    """Why the handshake turned the device away, in a few words for the log."""
    reason = getattr(error, "reason", None) or ""
    message = getattr(error, "verify_message", None) or ""
    if reason in ("PEER_DID_NOT_RETURN_A_CERTIFICATE", "TLSV13_ALERT_CERTIFICATE_REQUIRED"):
        return "no certificate"
    if "expired" in message:
        return "certificate expired"
    if reason == "CERTIFICATE_VERIFY_FAILED":
        return f"certificate not trusted ({message or 'verify failed'})"
    if "UNKNOWN_CA" in reason or "BAD_CERTIFICATE" in reason or "CERTIFICATE_UNKNOWN" in reason:
        return f"the device didn't trust this proxy ({reason.lower()})"
    return reason.lower() or str(error)


class Proxy(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, port, upstream, settings, log, context):
        self.upstream = upstream
        self.settings = settings
        self.log = log
        self.context = context
        super().__init__((settings.host, port), ProxyHandler)


class ProxyHandler(socketserver.BaseRequestHandler):
    def handle(self):
        server = self.server
        port = server.server_address[1]
        self.request.settimeout(15)
        try:
            client = server.context.wrap_socket(self.request, server_side=True)
        except ssl.SSLError as error:
            server.log.write(f":{port} handshake refused: {refusal(error)}")
            return
        except OSError as error:
            server.log.write(f":{port} handshake dropped: {error.__class__.__name__}")
            return
        peer = client.getpeercert() or {}
        certificate = (f"cert={name_of(peer.get('subject', ()))} "
                       f"issuer={name_of(peer.get('issuer', ()))} until={peer.get('notAfter', '?')}")
        server.log.write(f":{port} client certificate verified: {certificate}")
        client.settimeout(None)
        if server.settings.keep_alive:
            self.tunnel(client)
        else:
            self.forward(client)

    def tunnel(self, client):
        """--keep-alive: the bytes both ways until either side closes, every request on the
        connection included."""
        server = self.server
        port = server.server_address[1]
        try:
            upstream = socket.create_connection(server.upstream, timeout=10)
        except OSError:
            server.log.write(f":{port} the mock behind is down")
            return
        upstream.settimeout(None)
        upload = threading.Thread(target=self.pump, args=(client, upstream), daemon=True)
        upload.start()
        self.pump(upstream, client)
        upload.join(timeout=5)
        upstream.close()
        server.log.write(f":{port} connection closed")

    def forward(self, client):
        server = self.server
        head, rest = gateway.read_head(client)
        if head is None:
            return
        first, headers = gateway.parse_head(head)
        try:
            method, target, version = first.split(" ", 2)
        except ValueError:
            gateway.answer(client, 400, "Bad Request", [])
            return
        kind = gateway.request_kind(method, headers)
        key = "key" if gateway.header(headers, "authorization") else "no key"
        where = f"{method} {gateway.redact_target(target)} :{server.server_address[1]}"
        # One request per connection, so every request follows the line with the certificate it
        # came with; a socket keeps its upgrade.
        forwarded = [(k, v) for k, v in headers if kind == "socket" or k.lower() != "connection"]
        if kind != "socket":
            forwarded.append(("Connection", "close"))
        try:
            upstream = socket.create_connection(server.upstream, timeout=10)
        except OSError:
            gateway.answer(client, 502, "Bad Gateway", [("Content-Type", "text/html; charset=utf-8")],
                           b"<h1>Bad gateway</h1>")
            server.log.write(f"{where} {kind} {key} -> 502 (the mock behind is down)")
            return
        upstream.settimeout(None)
        try:
            upstream.sendall(gateway.build_head(f"{method} {target} {version}", forwarded) + rest)
            upload = threading.Thread(target=self.pass_body, args=(client, upstream), daemon=True)
            upload.start()
            reply, tail = gateway.read_head(upstream)
            if reply is None:
                server.log.write(f"{where} {kind} {key} -> no answer")
                return
            status_line, reply_headers = gateway.parse_head(reply)
            status = status_line.split(" ", 2)[1] if " " in status_line else "?"
            kind = gateway.response_kind(kind, reply_headers)
            server.log.write(f"{where} {kind} {key} -> {status}")
            if status != "101":
                reply_headers = [(k, v) for k, v in reply_headers if k.lower() != "connection"]
                reply = gateway.build_head(status_line, reply_headers + [("Connection", "close")])
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
    def pump(source, sink):
        """Copies one direction, then tells the other side nothing more is coming."""
        try:
            while data := source.recv(65536):
                sink.sendall(data)
        except OSError:
            pass
        try:
            sink.shutdown(socket.SHUT_WR)
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


def make_context(certificates, settings):
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(certificates.path("server.pem"), certificates.path("server.key"))
    context.load_verify_locations(certificates.path("ca.pem"))
    context.verify_mode = ssl.CERT_REQUIRED
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    if settings.tls_max == "1.2":
        context.maximum_version = ssl.TLSVersion.TLSv1_2
    return context


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--route", action="append", type=gateway.parse_route, required=True, metavar="PORT=UPSTREAM",
                        help="listen with TLS on PORT and pass requests to UPSTREAM (a port, or host:port); repeatable")
    parser.add_argument("--certs", help="the folder for the CA, certificates and keys (default: a new temporary one)")
    parser.add_argument("--password", default="hermes-mock", help="the client .p12 files' password")
    parser.add_argument("--openssl", default="openssl", help="the openssl command that makes the certificates")
    parser.add_argument("--tls-max", choices=["1.2", "1.3"], default="1.3",
                        help="the newest TLS version offered (1.2 refuses a certificate inside the handshake)")
    parser.add_argument("--keep-alive", action="store_true",
                        help="keep each connection open for more requests, asking for the certificate once")
    parser.add_argument("--log", help="also append the log to this file")
    settings = parser.parse_args()

    folder = settings.certs or tempfile.mkdtemp(prefix="hermes-mtls-")
    certificates = Certificates(folder, settings.openssl, settings.password)
    made = certificates.ensure()
    context = make_context(certificates, settings)
    log = gateway.Log(settings.log)
    proxies = [Proxy(port, upstream, settings, log, context) for port, upstream in settings.route]
    for proxy in proxies[1:]:
        threading.Thread(target=proxy.serve_forever, daemon=True).start()
    print(f"certificates {'made' if made else 'reused'} in {folder}", file=sys.stderr, flush=True)
    print(f"client certificate: {certificates.path('client.p12')} (password: {settings.password})",
          file=sys.stderr, flush=True)
    for proxy in proxies:
        upstream = f"{proxy.upstream[0]}:{proxy.upstream[1]}"
        print(f"TLS proxy on {settings.host}:{proxy.server_address[1]} -> {upstream}, asks for a client certificate",
              file=sys.stderr, flush=True)
    try:
        proxies[0].serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
