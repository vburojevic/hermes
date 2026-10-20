"""Signed answers (payload-contract.md §6.3).

Each paired device holds a Secure Enclave P-256 key that only Face ID or Touch ID unlocks, and
registers its public key with ``/app-widgets keys.register``. After the check, the app signs

    hermes-widgets-v1|<widget id>|<rev>|<action>|<sha256 hex of the canonical values JSON>|<mid>

(UTF-8; CryptoKit's ``signature(for:)`` hashes it with SHA-256) and sends the signature as ``sig``
(base64 of the DER form, or of the 64-byte raw r‖s). The canonical values JSON is the ``values``
object with keys sorted, no whitespace and no escaping beyond JSON's own (raw UTF-8, ``/`` unescaped):
``json.dumps(values, sort_keys=True, separators=(",", ":"), ensure_ascii=False)``.
"""
from __future__ import annotations

import base64
import binascii
import hashlib
import json
from typing import Any

PREFIX = "hermes-widgets-v1"


def canonical(values: Any) -> str:
    return json.dumps(values if values is not None else {}, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def signing_input(widget_id: str, rev: int, action: str, values: Any, mid: str) -> bytes:
    digest = hashlib.sha256(canonical(values).encode()).hexdigest()
    return f"{PREFIX}|{widget_id}|{int(rev)}|{action}|{digest}|{mid}".encode()


def _b64(text: str) -> bytes:
    text = (text or "").strip()
    try:
        return base64.b64decode(text + "=" * (-len(text) % 4), altchars=b"-_" if ("-" in text or "_" in text) else None,
                                validate=False)
    except (binascii.Error, ValueError):
        raise ValueError("not base64") from None


def load_public_key(encoded: str):
    """A P-256 public key: base64 of the X9.63 point (CryptoKit ``x963Representation``, 65 bytes) or
    of the SubjectPublicKeyInfo DER (``derRepresentation``)."""
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.hazmat.primitives.serialization import load_der_public_key
    raw = _b64(encoded)
    if len(raw) == 65 and raw[0] == 4:
        return ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), raw)
    key = load_der_public_key(raw)
    if not isinstance(key, ec.EllipticCurvePublicKey) or key.curve.name != "secp256r1":
        raise ValueError("not a P-256 key")
    return key


def verify(public_key: str, signature: str, message: bytes) -> bool:
    from cryptography.exceptions import InvalidSignature
    from cryptography.hazmat.primitives import hashes
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.hazmat.primitives.asymmetric.utils import encode_dss_signature
    try:
        key = load_public_key(public_key)
        sig = _b64(signature)
        if len(sig) == 64:
            sig = encode_dss_signature(int.from_bytes(sig[:32], "big"), int.from_bytes(sig[32:], "big"))
        key.verify(sig, message, ec.ECDSA(hashes.SHA256()))
        return True
    except (InvalidSignature, ValueError, TypeError):
        return False


def fingerprint(public_key: str) -> str:
    return hashlib.sha256(_b64(public_key)).hexdigest()[:16]
