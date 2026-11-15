"""The mock TLS proxy that asks for a client certificate (mtls_proxy.py,
`docs/connecting-and-voice.md` §11.7): a device without a certificate the CA signed is turned away,
one with it gets through to the mock behind, and the log names the certificate it verified.

Makes its certificates in a temporary folder and starts its own upstream and proxy on free ports,
stdlib and the openssl command only:
    python3 -I -m unittest discover -s Tools/mock-hermes/tests
"""

import http.client
import http.server
import json
import os
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
MTLS_PROXY = os.path.join(os.path.dirname(HERE), "mtls_proxy.py")
PASSWORD = "test-password-0123"


def free_port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


class Upstream(http.server.BaseHTTPRequestHandler):
    """Stands in for Hermes: echoes the path and headers that reached it."""

    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_GET(self):
        body = json.dumps({"path": self.path, "headers": {k.lower(): v for k, v in self.headers.items()}}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


@unittest.skipUnless(shutil.which("openssl"), "the proxy makes its certificates with openssl")
class MTLSProxyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.folder = tempfile.TemporaryDirectory()
        cls.certs = os.path.join(cls.folder.name, "certs")
        cls.log_path = os.path.join(cls.folder.name, "mtls.log")
        cls.upstream = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Upstream)
        threading.Thread(target=cls.upstream.serve_forever, daemon=True).start()
        cls.proxies = {}
        for name, flags in (("1.3", ["--tls-max", "1.3"]), ("1.2", ["--tls-max", "1.2"]), ("keep-alive", ["--keep-alive"])):
            port = free_port()
            process = subprocess.Popen(
                [sys.executable, "-I", MTLS_PROXY, "--route", f"{port}={cls.upstream.server_address[1]}",
                 "--certs", cls.certs, "--password", PASSWORD, *flags, "--log", cls.log_path],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
            cls.proxies[name] = (port, process)
            cls.wait_for(port, process)

    @classmethod
    def wait_for(cls, port, process):
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            if process.poll() is not None:
                raise RuntimeError("the proxy didn't start")
            try:
                socket.create_connection(("127.0.0.1", port), timeout=0.2).close()
                return
            except OSError:
                time.sleep(0.1)
        raise RuntimeError("the proxy didn't start in time")

    @classmethod
    def tearDownClass(cls):
        for _, process in cls.proxies.values():
            process.terminate()
            process.wait(timeout=10)
        cls.upstream.shutdown()
        cls.upstream.server_close()
        cls.folder.cleanup()

    def pem(self, name, chain=True):
        """A .p12's certificate and key as PEM, for Python's ssl, which doesn't read PKCS #12:
        with the intermediate the file carries, or the device's own certificate alone."""
        path = os.path.join(self.folder.name, f"{name}-{'chain' if chain else 'leaf'}.pem")
        if not os.path.exists(path):
            subprocess.run(
                ["openssl", "pkcs12", "-in", os.path.join(self.certs, f"{name}.p12"), "-nodes",
                 *([] if chain else ["-clcerts"]), "-passin", f"pass:{PASSWORD}", "-out", path],
                check=True, capture_output=True,
            )
        return path

    def get(self, version, identity=None, path="/v1/models", chain=True):
        """GETs through the proxy, presenting `identity` (a .p12's name) or no certificate."""
        port = self.proxies[version][0]
        context = ssl.create_default_context(cafile=os.path.join(self.certs, "ca.pem"))
        if identity:
            context.load_cert_chain(self.pem(identity, chain))
        with socket.create_connection(("127.0.0.1", port), timeout=10) as raw:
            with context.wrap_socket(raw, server_hostname="127.0.0.1") as tls:
                tls.sendall(f"GET {path} HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer k\r\n\r\n".encode())
                reply = b""
                while chunk := tls.recv(65536):
                    reply += chunk
        return reply

    def log(self):
        # The proxy writes each line as it happens; give the last one a moment to land.
        time.sleep(0.2)
        with open(self.log_path, encoding="utf-8") as file:
            return file.read()

    def test_it_makes_the_files_the_docs_name(self):
        for name in ("ca.pem", "issuing-ca.pem", "client.p12", "expired.p12", "other.p12", "server.pem"):
            self.assertTrue(os.path.exists(os.path.join(self.certs, name)), name)
        self.assertEqual(os.stat(self.certs).st_mode & 0o777, 0o700)

    def test_the_certificate_gets_through_and_is_logged(self):
        for version in ("1.3", "1.2"):
            with self.subTest(tls=version):
                reply = self.get(version, "client", "/v1/models")
                self.assertTrue(reply.startswith(b"HTTP/1.1 200"), reply[:40])
                body = json.loads(reply.split(b"\r\n\r\n", 1)[1])
                self.assertEqual(body["path"], "/v1/models")
                # Hermes's own key passes through untouched.
                self.assertEqual(body["headers"]["authorization"], "Bearer k")
        log = self.log()
        self.assertIn("client certificate verified: cert=Home Server Device issuer=Hermes Mock Issuing CA", log)
        self.assertIn("GET /v1/models", log)
        self.assertNotIn("Bearer k", log)

    def test_no_certificate_an_expired_one_and_another_cas_are_turned_away(self):
        cases = [(None, "no certificate"), ("expired", "certificate expired"), ("other", "certificate not trusted")]
        for version in ("1.3", "1.2"):
            for identity, reason in cases:
                with self.subTest(tls=version, identity=identity):
                    before = len(self.log())
                    # TLS 1.3 turns the device away after its side of the handshake, TLS 1.2 inside it.
                    with self.assertRaises((ssl.SSLError, ConnectionError)):
                        reply = self.get(version, identity)
                        if not reply:
                            raise ConnectionResetError("closed without an answer")
                    self.assertIn(f"handshake refused: {reason}", self.log()[before:])

    def test_the_proxy_trusts_the_root_alone_so_the_intermediate_must_come_along(self):
        with open(os.path.join(self.certs, "ca.pem"), encoding="utf-8") as file:
            self.assertEqual(file.read().count("BEGIN CERTIFICATE"), 1)
        with open(self.pem("client"), encoding="utf-8") as file:
            self.assertEqual(file.read().count("BEGIN CERTIFICATE"), 2)
        for version in ("1.3", "1.2"):
            with self.subTest(tls=version):
                before = len(self.log())
                with self.assertRaises((ssl.SSLError, ConnectionError)):
                    if not self.get(version, "client", chain=False):
                        raise ConnectionResetError("closed without an answer")
                self.assertIn("handshake refused: certificate not trusted", self.log()[before:])

    def test_keep_alive_asks_for_the_certificate_once_per_connection(self):
        port = self.proxies["keep-alive"][0]
        context = ssl.create_default_context(cafile=os.path.join(self.certs, "ca.pem"))
        context.load_cert_chain(self.pem("client"))
        before = len(self.log())
        connection = http.client.HTTPSConnection("127.0.0.1", port, context=context, timeout=10)
        try:
            for path in ("/v1/models", "/v1/runs"):
                connection.request("GET", path, headers={"Authorization": "Bearer k"})
                reply = connection.getresponse()
                self.assertEqual(reply.status, 200)
                self.assertEqual(json.loads(reply.read())["path"], path)
        finally:
            connection.close()
        log = self.log()[before:]
        self.assertEqual(log.count(f":{port} client certificate verified"), 1)
        self.assertIn(f":{port} connection closed", log)


if __name__ == "__main__":
    unittest.main()
