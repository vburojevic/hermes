"""Stored media (payload-contract.md §9, behind store_media): the SSRF guard, the size cap, sniffing
and metadata stripping. No network: the resolver and the HTTP getter are injected."""
from __future__ import annotations

import struct
import zlib

import pytest

from harness import plugin_module

PUBLIC = "93.184.215.14"


def png(text_chunk: bool = True) -> bytes:
    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    body = chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0))
    if text_chunk:
        body += chunk(b"tEXt", b"GPS\x0045.81,15.98")
    body += chunk(b"IDAT", zlib.compress(b"\x00\xff\x00\x00")) + chunk(b"IEND", b"")
    return b"\x89PNG\r\n\x1a\n" + body


def jpeg_with_exif() -> bytes:
    exif = b"Exif\x00\x00" + b"GPS-and-camera-serial"
    app1 = b"\xff\xe1" + struct.pack(">H", len(exif) + 2) + exif
    return b"\xff\xd8" + app1 + b"\xff\xda\x00\x02" + b"image-data" + b"\xff\xd9"


@pytest.fixture
def media(hermes):
    return plugin_module("media")


def getter_for(responses: dict):
    calls = []

    def get(host, address, port, path):
        calls.append((host, address, port, path))
        status, headers, body = responses[(host, path)]
        return status, headers, iter([body])
    get.calls = calls
    return get


@pytest.mark.parametrize("address", ["127.0.0.1", "10.0.0.5", "192.168.1.1", "172.16.0.9", "169.254.169.254",
                                     "100.64.0.1", "0.0.0.0", "::1", "fc00::1", "fe80::1", "::ffff:127.0.0.1",
                                     "64:ff9b::a00:1", "2002:a00:1::1", "224.0.0.1", "198.18.0.1"])
def test_private_and_special_addresses_are_refused(media, address):
    assert not media.address_allowed(address)
    with pytest.raises(media.MediaError, match="private address"):
        media.fetch("https://cdn.example.com/a.png", resolver=lambda h, p: [address], getter=getter_for({}))


def test_public_addresses_are_allowed(media):
    assert media.address_allowed(PUBLIC) and media.address_allowed("2606:4700::1111")


def test_one_private_answer_among_public_ones_is_refused(media):
    with pytest.raises(media.MediaError, match="private address"):
        media.fetch("https://cdn.example.com/a.png", resolver=lambda h, p: [PUBLIC, "10.1.1.1"], getter=getter_for({}))


@pytest.mark.parametrize("url,message", [
    ("http://cdn.example.com/a.png", "only https"),
    ("https://user:pw@cdn.example.com/a.png", "user info"),
    ("https://localhost/a.png", "private address"),
    ("https://metadata.google.internal/computeMetadata/v1/", "private address"),
    ("https://printer.local/a.png", "private address"),
])
def test_urls_are_checked_before_resolving(media, url, message):
    with pytest.raises(media.MediaError, match=message):
        media.fetch(url, resolver=lambda h, p: [PUBLIC], getter=getter_for({}))


def test_every_redirect_is_checked_again(media):
    responses = {("cdn.example.com", "/a.png"): (302, {"location": "https://internal.example.com/secret"}, b"")}
    resolver = {"cdn.example.com": [PUBLIC], "internal.example.com": ["10.0.0.7"]}
    with pytest.raises(media.MediaError, match="private address"):
        media.fetch("https://cdn.example.com/a.png", resolver=lambda h, p: resolver[h], getter=getter_for(responses))
    downgrade = {("cdn.example.com", "/a.png"): (301, {"location": "http://cdn.example.com/a.png"}, b"")}
    with pytest.raises(media.MediaError, match="only https"):
        media.fetch("https://cdn.example.com/a.png", resolver=lambda h, p: [PUBLIC], getter=getter_for(downgrade))


def test_the_connection_is_pinned_to_the_checked_address(media):
    responses = {("cdn.example.com", "/a.png"): (200, {"content-type": "image/png"}, png())}
    get = getter_for(responses)
    media.fetch("https://cdn.example.com/a.png", resolver=lambda h, p: [PUBLIC], getter=get)
    assert get.calls == [("cdn.example.com", PUBLIC, 443, "/a.png")]


def test_size_cap_sniffing_and_metadata(media):
    big = {("cdn.example.com", "/big.png"): (200, {"content-length": str(11 * 1024 * 1024)}, b"")}
    with pytest.raises(media.MediaError, match="at most 10 MB"):
        media.fetch("https://cdn.example.com/big.png", resolver=lambda h, p: [PUBLIC], getter=getter_for(big))
    stream = {("cdn.example.com", "/s.png"): (200, {}, b"\x89PNG\r\n\x1a\n" + b"x" * 64)}
    with pytest.raises(media.MediaError, match="over 0 MB|over"):
        media.fetch("https://cdn.example.com/s.png", resolver=lambda h, p: [PUBLIC], getter=getter_for(stream), max_bytes=32)
    html = {("cdn.example.com", "/a.png"): (200, {"content-type": "image/png"}, b"<html><script>alert(1)</script>")}
    with pytest.raises(media.MediaError, match="isn't an image"):
        media.fetch("https://cdn.example.com/a.png", resolver=lambda h, p: [PUBLIC], getter=getter_for(html))
    svg = {("cdn.example.com", "/a.svg"): (200, {}, b"<svg xmlns='http://www.w3.org/2000/svg'/>")}
    with pytest.raises(media.MediaError, match="isn't an image"):
        media.fetch("https://cdn.example.com/a.svg", resolver=lambda h, p: [PUBLIC], getter=getter_for(svg))
    clean = media.fetch("https://cdn.example.com/a.png", resolver=lambda h, p: [PUBLIC],
                        getter=getter_for({("cdn.example.com", "/a.png"): (200, {}, png())}))
    assert clean.mime == "image/png" and b"tEXt" not in clean.data and clean.data == png(text_chunk=False)
    photo = media.fetch("https://cdn.example.com/p.jpg", resolver=lambda h, p: [PUBLIC],
                        getter=getter_for({("cdn.example.com", "/p.jpg"): (200, {}, jpeg_with_exif())}))
    assert photo.mime == "image/jpeg" and b"GPS-and-camera-serial" not in photo.data and photo.data.endswith(b"\xff\xd9")


def test_media_is_off_unless_turned_on(widgets, tmp_path):
    assert widgets._media({"items": [{"media": {"src": "https://cdn.example.com/a.png", "alt": "A"}}]}, []) == {}
