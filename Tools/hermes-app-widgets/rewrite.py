"""Reply text (payload-contract.md §2): finding directives, neutralising fences, and the text other
platforms get.

``::widget{id="w_…" alt="…"}`` counts only on its own line, outside code fences. Before anything
else, every `` ```widget `` fence the agent wrote (or quoted from a page or a README) becomes
`` ```json ``, so the only inline blocks the app ever sees are the ones this plugin writes.
"""
from __future__ import annotations

import json
import re
import unicodedata
from dataclasses import dataclass
from typing import Callable

DIRECTIVE = re.compile(r'^\s*::widget\{(?P<attrs>(?:[^"}]|"(?:[^"\\]|\\.)*")*)\}\s*$')
_ATTR = re.compile(r'(?<![\w-])([A-Za-z_][\w-]*)\s*=\s*"((?:[^"\\]|\\.)*)"')
_FENCE = re.compile(r"^(?P<lead>(?:\s{0,3}>)*\s*)(?P<fence>`{3,}|~{3,})(?P<info>.*)$")
_WIDGET_INFO = re.compile(r"^\s*widget\b", re.IGNORECASE)
MAX_DIRECTIVES = 3


@dataclass
class Directive:
    line: int
    id: str
    alt: str


def _unescape(value: str) -> str:
    return re.sub(r"\\(.)", r"\1", value)


def parse_directive(line: str) -> Directive | None:
    match = DIRECTIVE.match(line)
    if not match:
        return None
    attrs = {k: _unescape(v) for k, v in _ATTR.findall(match.group("attrs"))}
    if not attrs.get("id"):
        return None
    return Directive(line=-1, id=attrs["id"], alt=attrs.get("alt", "")[:140])


def neutralise_fences(text: str) -> str:
    """Every fence opener whose info string starts with ``widget`` becomes ``json``, wherever it is
    (nested in another fence, in a quote or a list): a block the plugin didn't write never draws.
    Lines are read in their NFKC form: the app compares text canonically, so a look-alike such as
    U+1FEF GREEK VARIA (a backtick to it) would otherwise open a block this check never saw."""
    if "widget" not in unicodedata.normalize("NFKC", text).lower():
        return text
    lines = text.split("\n")
    for n, line in enumerate(lines):
        normal = unicodedata.normalize("NFKC", line)
        match = _FENCE.match(normal)
        if match and _WIDGET_INFO.match(match.group("info")):
            info = _WIDGET_INFO.sub("json", match.group("info"), count=1)
            lines[n] = f"{match.group('lead')}{match.group('fence')}{info}"
    return "\n".join(lines)


def directives(text: str) -> list[Directive]:
    """Directive lines outside code fences, in order."""
    found: list[Directive] = []
    fence: str | None = None
    for n, line in enumerate(text.split("\n")):
        match = _FENCE.match(line)
        if match and not match.group("lead").strip(" >"):
            marker = match.group("fence")
            if fence is None:
                fence = marker
                continue
            if marker[0] == fence[0] and len(marker) >= len(fence) and not match.group("info").strip():
                fence = None
                continue
        if fence is not None:
            continue
        directive = parse_directive(line)
        if directive is not None:
            directive.line = n
            found.append(directive)
    return found


def replace_directives(text: str, render: Callable[[Directive], str | None]) -> str:
    """Replace each directive line with ``render(directive)`` (None keeps the line)."""
    lines = text.split("\n")
    for directive in reversed(directives(text)):
        replacement = render(directive)
        if replacement is not None:
            lines[directive.line: directive.line + 1] = replacement.split("\n") if replacement else []
    return "\n".join(lines)


def inline_block(payload: dict) -> str:
    """The stored payload as an inline block, for a scheduled delivery into the app."""
    body = json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
    fence = "```"
    while fence in body:
        fence += "`"
    return f"{fence}widget\n{body}\n{fence}"
