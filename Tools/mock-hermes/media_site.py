#!/usr/bin/env python3
"""A press site that serves one video over https, for the app's web video route (docs/widgets.md
§9.3): what "widget media web <port>" points a card at.

    python3 -I Tools/mock-hermes/media_site.py --port 24443 --certs "$TMPDIR/mtls"

It answers `GET /clips/launch.mp4` with Range, as a web server does, and nothing else. The
certificate is mtls_proxy.py's server certificate (127.0.0.1 and localhost), made in the --certs
folder when it isn't there yet; a Debug build trusts its CA with `-HERMES_TRUST_CA <certs>/ca.pem`.

`--rate` sends each answer that many bytes a second, so a seek lands while a read is still
coming in and the app lets go of it; the log says how far each read got. `--ignore-ranges`
answers every read with the whole file (200), which the app refuses ("Couldn't play this video").
"""

import argparse
import http.server
import importlib.util
import pathlib
import socketserver
import ssl
import sys
import time

HERE = pathlib.Path(__file__).resolve().parent


def load_certificates():
    """mtls_proxy.py's `Certificates`, so both share one CA."""
    spec = importlib.util.spec_from_file_location("mock_mtls_proxy", HERE / "mtls_proxy.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules["mock_mtls_proxy"] = module
    spec.loader.exec_module(module)
    return module.Certificates


class Site(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True


def handler_for(data, settings):
    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *args):
            pass

        def do_HEAD(self):
            self.answer(head=True)

        def do_GET(self):
            self.answer(head=False)

        def answer(self, head):
            if self.path.split("?", 1)[0] != "/clips/launch.mp4":
                self.send_response(404)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return print(f"{self.command} {self.path}: 404", flush=True)
            start, end, status = 0, len(data) - 1, 200
            ranged = self.headers.get("Range") or ""
            if ranged.startswith("bytes=") and not settings.ignore_ranges:
                first, _, last = ranged[6:].partition("-")
                start = int(first) if first else max(0, len(data) - int(last or 0))
                end = min(len(data) - 1, int(last)) if first and last else len(data) - 1
                if start >= len(data):
                    self.send_response(416)
                    self.send_header("Content-Range", f"bytes */{len(data)}")
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return print(f"{self.command} {ranged}: 416", flush=True)
                status = 206
            chunk = data[start:end + 1]
            self.send_response(status)
            self.send_header("Content-Type", "video/mp4")
            self.send_header("Accept-Ranges", "none" if settings.ignore_ranges else "bytes")
            if status == 206:
                self.send_header("Content-Range", f"bytes {start}-{end}/{len(data)}")
            self.send_header("Content-Length", str(len(chunk)))
            self.end_headers()
            label = f"{self.command} {ranged or 'whole'}: {status}"
            if head:
                return print(label, flush=True)
            sent = 0
            piece = max(1, settings.rate // 10) if settings.rate else len(chunk) or 1
            try:
                while sent < len(chunk):
                    self.wfile.write(chunk[sent:sent + piece])
                    sent += len(chunk[sent:sent + piece])
                    if settings.rate:
                        time.sleep(0.1)
                print(f"{label}, sent {sent} bytes", flush=True)
            except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
                # The app let go of the read: a seek, or the player closed.
                print(f"{label}, closed by the app after {sent} of {len(chunk)} bytes", flush=True)
                self.close_connection = True

    return Handler


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--certs", required=True,
                        help="mtls_proxy.py's certificate folder (made when missing)")
    parser.add_argument("--file", default=str(HERE / "media" / "sample-clip.mp4"),
                        help="the video to serve")
    parser.add_argument("--rate", type=int, default=0,
                        help="bytes a second for each answer (default: as fast as it can)")
    parser.add_argument("--ignore-ranges", action="store_true",
                        help="answer every read with the whole file (200)")
    settings = parser.parse_args()

    certificates = load_certificates()(settings.certs, "openssl", "hermes-mock")
    certificates.ensure()
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(certificates.path("server.pem"), certificates.path("server.key"))
    data = pathlib.Path(settings.file).read_bytes()
    site = Site((settings.host, settings.port), handler_for(data, settings))
    site.socket = context.wrap_socket(site.socket, server_side=True)
    print(f"https://localhost:{settings.port}/clips/launch.mp4 ({len(data)} bytes)", flush=True)
    site.serve_forever()


if __name__ == "__main__":
    main()
