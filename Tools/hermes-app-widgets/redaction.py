"""Secrets never go in a payload (payload-contract.md §9): the gateway's own redaction patterns, plus
card numbers (masked values show at most four digits)."""
from __future__ import annotations

import re

_CARD = re.compile(r"(?<![\d.])(?:\d[ -]?){12,18}\d(?![\d.])")


def _luhn(digits: str) -> bool:
    total, parity = 0, len(digits) % 2
    for n, char in enumerate(digits):
        value = int(char)
        if n % 2 == parity:
            value *= 2
            if value > 9:
                value -= 9
        total += value
    return total % 10 == 0


def _redactor():
    try:
        from agent import redact
    except Exception:
        return None, None
    return getattr(redact, "redact_sensitive_text", None), getattr(redact, "_SIGNAL_PHONE_RE", None)


def secret_issue(text: str) -> str | None:
    """Why ``text`` can't go in a widget, or None. Phone numbers are fields, not secrets, so the
    redactor's phone masking doesn't count."""
    if not isinstance(text, str) or len(text) < 8:
        return None
    for match in _CARD.finditer(text):
        digits = re.sub(r"\D", "", match.group(0))
        if 13 <= len(digits) <= 19 and _luhn(digits) and len(set(digits)) > 1:
            return "looks like a card number"
    redact, phone = _redactor()
    if redact is None:
        return None
    probe = phone.sub("PHONE", text) if phone is not None and "+" in text else text
    try:
        redacted = redact(probe, force=True)
    except TypeError:
        redacted = redact(probe)
    except Exception:
        return None
    if redacted != probe:
        return "matches the gateway's secret patterns"
    return None
