"""Remote media, fetched and stored by the gateway (payload-contract.md §9, a proposal).

Off by default (``store_media: true`` turns it on). Widgets keep ``src`` as the https URL, and the
app waits for a tap that shows the domain, until a gateway route can serve the stored copies. When
it's on, ``create`` fetches each https image, video or audio file once:
- refuses private, loopback, link-local, shared, multicast, reserved and cloud metadata addresses,
  checked on the address it actually connects to and again on every redirect (the name is resolved
  once and the connection pinned to that address, so a second DNS answer can't swap it);
- caps the size at 10 MB, reading no further;
- sniffs the bytes (images, video and audio only; never SVG or HTML);
- strips metadata from JPEG and PNG (EXIF, XMP, IPTC, text chunks: the location a photo carries).
"""
from __future__ import annotations

import hashlib
import http.client
import ipaddress
import socket
import ssl
import struct
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Iterable
from urllib.parse import urljoin, urlsplit

MAX_BYTES = 10 * 1024 * 1024
MAX_REDIRECTS = 3
TIMEOUT = 8.0
_METADATA_HOSTS = {"metadata.google.internal", "metadata", "instance-data", "metadata.azure.com"}
_EXTRA_BLOCKED = [ipaddress.ip_network(n) for n in (
    "0.0.0.0/8", "100.64.0.0/10", "169.254.0.0/16", "192.0.0.0/24", "192.0.2.0/24", "198.18.0.0/15",
    "198.51.100.0/24", "203.0.113.0/24", "224.0.0.0/4", "240.0.0.0/4", "255.255.255.255/32",
    "::/128", "::1/128", "64:ff9b::/96", "64:ff9b:1::/48", "100::/64", "2001::/32", "2001:db8::/32", "2002::/16",
    "fc00::/7", "fe80::/10", "fec0::/10", "ff00::/8")]


class MediaError(ValueError):
    pass


@dataclass
class Fetched:
    url: str
    data: bytes
    mime: str
    ext: str

    @property
    def sha256(self) -> str:
        return hashlib.sha256(self.data).hexdigest()


def address_allowed(address: str) -> bool:
    """Only public unicast addresses; IPv4 inside IPv6 (mapped, NAT64, 6to4) is checked as IPv4."""
    try:
        ip = ipaddress.ip_address(address.split("%", 1)[0])
    except ValueError:
        return False
    if isinstance(ip, ipaddress.IPv6Address):
        if ip.ipv4_mapped is not None:
            return address_allowed(str(ip.ipv4_mapped))
        if ip.sixtofour is not None:
            return address_allowed(str(ip.sixtofour))
        if ip.teredo is not None:
            return False
    if (ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_multicast or ip.is_reserved
            or ip.is_unspecified or not ip.is_global):
        return False
    return not any(ip in net for net in _EXTRA_BLOCKED if net.version == ip.version)


def _check_url(url: str) -> tuple[str, int, str]:
    parts = urlsplit(url)
    if parts.scheme != "https":
        raise MediaError(f"only https media is fetched, not {parts.scheme or 'a relative URL'}")
    if parts.username or parts.password or "@" in parts.netloc:
        raise MediaError("media URLs can't carry user info")
    host = (parts.hostname or "").rstrip(".").lower()
    if not host:
        raise MediaError("the media URL has no host")
    if host in _METADATA_HOSTS or host.endswith((".internal", ".local", ".localhost")) or host == "localhost":
        raise MediaError(f"{host} is a private address")
    try:
        port = parts.port or 443
    except ValueError:
        raise MediaError("the media URL has an invalid port") from None
    path = (parts.path or "/") + (f"?{parts.query}" if parts.query else "")
    return host, port, path


def resolve(host: str, port: int) -> list[str]:
    infos = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)
    return list(dict.fromkeys(info[4][0] for info in infos))


class _PinnedHTTPS(http.client.HTTPSConnection):
    """HTTPS to one address, with the certificate checked against the host name."""

    def __init__(self, host: str, address: str, port: int, timeout: float):
        super().__init__(host, port, timeout=timeout, context=ssl.create_default_context())
        self._address = address

    def connect(self) -> None:
        sock = socket.create_connection((self._address, self.port), self.timeout)
        peer = sock.getpeername()[0]
        if not address_allowed(peer):
            sock.close()
            raise MediaError(f"connected to a private address ({peer})")
        self.sock = self._context.wrap_socket(sock, server_hostname=self.host)


def _get(host: str, address: str, port: int, path: str) -> tuple[int, dict, Iterable[bytes]]:
    connection = _PinnedHTTPS(host, address, port, TIMEOUT)
    connection.request("GET", path, headers={"Host": host if port == 443 else f"{host}:{port}",
                                             "User-Agent": "hermes-app-widgets/1", "Accept": "image/*,video/*,audio/*"})
    response = connection.getresponse()
    headers = {k.lower(): v for k, v in response.getheaders()}

    def body() -> Iterable[bytes]:
        try:
            while True:
                chunk = response.read(65536)
                if not chunk:
                    return
                yield chunk
        finally:
            connection.close()

    return response.status, headers, body()


def fetch(url: str, *, resolver: Callable[[str, int], list[str]] = resolve,
          getter: Callable[[str, str, int, str], tuple[int, dict, Iterable[bytes]]] = _get,
          max_bytes: int = MAX_BYTES) -> Fetched:
    for _ in range(MAX_REDIRECTS + 1):
        host, port, path = _check_url(url)
        try:
            addresses = resolver(host, port)
        except OSError as exc:
            raise MediaError(f"couldn't resolve {host}: {exc}") from None
        if not addresses:
            raise MediaError(f"{host} has no address")
        refused = [a for a in addresses if not address_allowed(a)]
        if refused:
            raise MediaError(f"{host} resolves to a private address ({refused[0]})")
        status, headers, body = getter(host, addresses[0], port, path)
        if status in (301, 302, 303, 307, 308):
            location = headers.get("location")
            if not location:
                raise MediaError("a redirect without a location")
            url = urljoin(url, location)
            continue
        if status != 200:
            raise MediaError(f"the server answered {status}")
        length = headers.get("content-length")
        if length and length.isdigit() and int(length) > max_bytes:
            raise MediaError(f"the file is {int(length) / 1048576:.1f} MB; at most {max_bytes // 1048576} MB")
        data = bytearray()
        for chunk in body:
            data += chunk
            if len(data) > max_bytes:
                raise MediaError(f"the file is over {max_bytes // 1048576} MB")
        mime, ext = sniff(bytes(data))
        return Fetched(url=url, data=strip_metadata(bytes(data), mime), mime=mime, ext=ext)
    raise MediaError(f"more than {MAX_REDIRECTS} redirects")


def sniff(data: bytes) -> tuple[str, str]:
    head = data[:32]
    if head.startswith(b"\xff\xd8\xff"):
        return "image/jpeg", "jpg"
    if head.startswith(b"\x89PNG\r\n\x1a\n"):
        return "image/png", "png"
    if head[:6] in (b"GIF87a", b"GIF89a"):
        return "image/gif", "gif"
    if head[:4] == b"RIFF" and head[8:12] == b"WEBP":
        return "image/webp", "webp"
    if head[:4] == b"RIFF" and head[8:12] == b"WAVE":
        return "audio/wav", "wav"
    if head[4:8] == b"ftyp":
        brand = head[8:12]
        if brand in (b"heic", b"heix", b"mif1", b"msf1", b"hevc"):
            return "image/heic", "heic"
        if brand in (b"avif", b"avis"):
            return "image/avif", "avif"
        if brand in (b"M4A ", b"M4B "):
            return "audio/mp4", "m4a"
        if brand == b"qt  ":
            return "video/quicktime", "mov"
        return "video/mp4", "mp4"
    if head.startswith(b"ID3") or head[:2] in (b"\xff\xfb", b"\xff\xf3", b"\xff\xf2"):
        return "audio/mpeg", "mp3"
    if head.startswith(b"OggS"):
        return "audio/ogg", "ogg"
    raise MediaError("the file isn't an image, video or audio file")


def strip_metadata(data: bytes, mime: str) -> bytes:
    if mime == "image/jpeg":
        return _strip_jpeg(data)
    if mime == "image/png":
        return _strip_png(data)
    return data


def _strip_jpeg(data: bytes) -> bytes:
    """Drop APP1 (EXIF, XMP), APP2–APP15 except ICC colour (APP2 ICC_PROFILE) and COM segments."""
    out = bytearray(data[:2])
    i = 2
    while i + 4 <= len(data) and data[i] == 0xFF:
        marker = data[i + 1]
        if marker == 0xDA:  # start of scan: the rest is image data
            out += data[i:]
            return bytes(out)
        if 0xD0 <= marker <= 0xD9 or marker == 0x01:
            out += data[i:i + 2]
            i += 2
            continue
        length = struct.unpack(">H", data[i + 2:i + 4])[0]
        segment = data[i:i + 2 + length]
        keep = not (marker == 0xFE or (0xE1 <= marker <= 0xEF and not segment[4:16].startswith(b"ICC_PROFILE")))
        if keep:
            out += segment
        i += 2 + length
    out += data[i:]
    return bytes(out)


def _strip_png(data: bytes) -> bytes:
    out = bytearray(data[:8])
    i = 8
    while i + 8 <= len(data):
        length = struct.unpack(">I", data[i:i + 4])[0]
        kind = data[i + 4:i + 8]
        chunk = data[i:i + 12 + length]
        if kind not in (b"tEXt", b"zTXt", b"iTXt", b"eXIf", b"tIME"):
            out += chunk
        i += 12 + length
        if kind == b"IEND":
            break
    return bytes(out)


def store(fetched: Fetched, directory: Path) -> dict:
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    path = directory / f"{fetched.sha256}.{fetched.ext}"
    if not path.exists():
        path.write_bytes(fetched.data)
        path.chmod(0o600)
    return {"sha256": fetched.sha256, "type": fetched.mime, "bytes": len(fetched.data), "file": path.name}


def media_urls(payload: dict) -> list[str]:
    """Every https ``src`` / ``thumb`` of a Media object, in order, at most 12."""
    found: list[str] = []

    def visit(value) -> None:
        if isinstance(value, dict):
            if "alt" in value and isinstance(value.get("src"), str):
                for key in ("src", "thumb"):
                    url = value.get(key)
                    if isinstance(url, str) and url.startswith("https://") and url not in found:
                        found.append(url)
            for item in value.values():
                visit(item)
        elif isinstance(value, list):
            for item in value:
                visit(item)

    visit(payload)
    return found[:12]
