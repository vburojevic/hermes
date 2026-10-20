"""Sealing a notification for one device.

Each device registers an X25519 public key (CryptoKit ``Curve25519.KeyAgreement``). For every push
the plugin makes a fresh ephemeral key pair, derives a key with HKDF-SHA256 from the shared secret,
and seals the JSON content with ChaCha20-Poly1305 (CryptoKit ``ChaChaPoly``). The relay and Apple
only ever see the envelope; the app's Notification Service Extension opens it.

Envelope (all base64, standard alphabet): ``{"v": 1, "epk": <32 bytes>, "box": <nonce|ciphertext|tag>}``.
``box`` is CryptoKit's ``ChaChaPoly.SealedBox.combined`` layout: 12-byte nonce, ciphertext, 16-byte tag.
HKDF: salt = ephemeral public key || device public key, info = ``b"hermes-app-push v1"``, 32 bytes.
"""
from __future__ import annotations

import base64
import json
import os

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

INFO = b"hermes-app-push v1"
VERSION = 1


def _raw(public_key: X25519PublicKey) -> bytes:
    return public_key.public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)


def parse_public_key(encoded: str) -> X25519PublicKey:
    """A device key as the app sends it: 32 raw bytes, base64. Raises ValueError otherwise."""
    try:
        raw = base64.b64decode(encoded, validate=True)
    except Exception as exc:
        raise ValueError("public_key is not base64") from exc
    if len(raw) != 32:
        raise ValueError("public_key must be a 32-byte X25519 key")
    return X25519PublicKey.from_public_bytes(raw)


def _key(shared: bytes, ephemeral: bytes, device: bytes) -> bytes:
    return HKDF(algorithm=hashes.SHA256(), length=32, salt=ephemeral + device, info=INFO).derive(shared)


def seal(device_key: str, content: dict) -> dict:
    """Encrypt ``content`` (JSON-able) for the device whose base64 public key is ``device_key``."""
    device = parse_public_key(device_key)
    ephemeral = X25519PrivateKey.generate()
    ephemeral_raw = _raw(ephemeral.public_key())
    key = _key(ephemeral.exchange(device), ephemeral_raw, _raw(device))
    nonce = os.urandom(12)
    plaintext = json.dumps(content, ensure_ascii=False, separators=(",", ":")).encode()
    box = nonce + ChaCha20Poly1305(key).encrypt(nonce, plaintext, None)
    return {"v": VERSION, "epk": base64.b64encode(ephemeral_raw).decode(), "box": base64.b64encode(box).decode()}


def open_envelope(private_key: X25519PrivateKey, envelope: dict) -> dict:
    """The app's side, for tests and the mock: decrypt an envelope made by :func:`seal`."""
    ephemeral_raw = base64.b64decode(envelope["epk"])
    box = base64.b64decode(envelope["box"])
    device_raw = _raw(private_key.public_key())
    key = _key(private_key.exchange(X25519PublicKey.from_public_bytes(ephemeral_raw)), ephemeral_raw, device_raw)
    plaintext = ChaCha20Poly1305(key).decrypt(box[:12], box[12:], None)
    return json.loads(plaintext)
