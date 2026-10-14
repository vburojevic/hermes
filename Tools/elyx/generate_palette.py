#!/usr/bin/env python3
"""Generates App/Design/Palette.swift from the Elyx design tokens.

The colour tokens live in the Hermes Elyx project (tokens/colors*.elyx), one file per
appearance: light, dark, Increase Contrast, and dark with Increase Contrast. `elyx tokens`
exports all of them; this script turns them into `Color(light:dark:increasedContrastLight:
increasedContrastDark:)` values. A token an appearance doesn't override falls back to the dark
value (for dark + contrast) and then to the light one.

Usage: Tools/elyx/generate_palette.py [path to the Elyx project]
"""

import json
import pathlib
import re
import subprocess
import sys

DESIGN = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "~/Documents/Elyx/Hermes").expanduser()
OUT = pathlib.Path(__file__).resolve().parents[2] / "App/Design/Palette.swift"

# Mock-up chrome and static stand-ins for Liquid Glass and scroll edges: the system draws those
# (docs/design-to-swiftui.md, section 1), so the app gets no colours for them.
SKIPPED = re.compile(
    r"^(desktop-|traffic-|keyboard-|camera-backdrop|qr-|window-|glass-|clear-glass|on-glass-dark"
    r"|.*-veil$|.*-clear$)"
)
SCOPES = {"colors": None, "accents": "Accents", "faces": "Faces", "syntax": "Syntax"}


SWIFT_KEYWORDS = {"default", "case", "class", "func", "in", "is", "operator", "protocol", "repeat", "return", "self", "static", "struct", "switch", "var", "let"}


def camel(name: str) -> str:
    head, *rest = name.split("-")
    identifier = head + "".join(part[:1].upper() + part[1:] for part in rest)
    return f"`{identifier}`" if identifier in SWIFT_KEYWORDS else identifier


def color(value: str) -> str:
    match = re.fullmatch(r"rgb\(([\d.]+) ([\d.]+) ([\d.]+)(?: / ([\d.]+))?\)", value)
    if not match:
        raise SystemExit(f"unexpected colour value: {value}")
    r, g, b = (float(match.group(i)) / 255 for i in (1, 2, 3))
    a = float(match.group(4) or 1)

    def short(x: float) -> str:
        return f"{x:.4f}".rstrip("0").rstrip(".") if x not in (0, 1) else str(int(x))

    if a == 1:
        return f"Color(.sRGB, red: {short(r)}, green: {short(g)}, blue: {short(b)})"
    return f"Color(.sRGB, red: {short(r)}, green: {short(g)}, blue: {short(b)}, opacity: {short(a)})"


def comments(path: pathlib.Path) -> dict[str, str]:
    """The `//` lines above each token in its source file."""
    notes: dict[str, str] = {}
    pending: list[str] = []
    for line in path.read_text().splitlines():
        stripped = line.strip()
        if stripped.startswith("//"):
            pending.append(stripped.lstrip("/").strip())
            continue
        match = re.match(r"([a-z0-9-]+):", stripped)
        if match and pending and line.startswith("  "):
            notes[match.group(1)] = " ".join(pending)
        pending = []
    return notes


def main() -> None:
    exported = subprocess.run(
        ["elyx", "tokens", str(DESIGN / "tokens/colors.elyx")],
        check=True, capture_output=True, text=True,
    ).stdout
    tokens: dict[tuple[str, str], dict[str, str]] = {}
    for token in json.loads(exported)["tokens"]:
        if token["type"] != "color":
            continue
        context = token.get("context") or {}
        appearance = {
            (): "light",
            (("theme", "dark"),): "dark",
            (("contrast", "high"),): "contrast",
            (("contrast", "high"), ("theme", "dark")): "darkContrast",
        }[tuple(sorted(context.items()))]
        tokens.setdefault((token["rootScope"][0], token["name"]), {})[appearance] = token["value"]

    notes = comments(DESIGN / "tokens/colors.elyx")
    groups: dict[str | None, list[str]] = {scope: [] for scope in SCOPES.values()}
    for (scope, name), values in sorted(tokens.items()):
        if scope == "colors" and SKIPPED.match(name):
            continue
        light = values["light"]
        dark = values.get("dark", light)
        contrast = values.get("contrast", light)
        dark_contrast = values.get("darkContrast", dark)
        lines = []
        if scope == "colors" and name in notes:
            lines.append(f"/// {notes[name]}")
        if len({light, dark, contrast, dark_contrast}) == 1:
            lines.append(f"static let {camel(name)} = {color(light)}")
        else:
            args = [f"light: {color(light)}", f"dark: {color(dark)}"]
            if contrast != light:
                args.append(f"increasedContrastLight: {color(contrast)}")
            if dark_contrast != dark:
                args.append(f"increasedContrastDark: {color(dark_contrast)}")
            body = ",\n    ".join(args)
            lines.append(f"static let {camel(name)} = Color(\n    {body}\n)")
        groups[SCOPES[scope]].append("\n".join(lines))

    def indent(text: str, level: int) -> str:
        return "\n".join(("    " * level + line) if line else line for line in text.splitlines())

    out = [
        "// Generated from the Elyx design tokens (tokens/colors*.elyx) by",
        "// Tools/elyx/generate_palette.py. Do not edit by hand: change the tokens and regenerate.",
        "",
        "import SwiftUI",
        "",
        "/// Every colour in the design, with its light, dark and Increase Contrast values.",
        "nonisolated enum Palette {",
    ]
    out += [indent(entry, 1) for entry in groups[None]]
    for scope_name in ("Accents", "Faces", "Syntax"):
        out.append("")
        out.append(f"    enum {scope_name} {{")
        out += [indent(entry, 2) for entry in groups[scope_name]]
        out.append("    }")
    out.append("}")
    OUT.write_text("\n".join(out) + "\n")
    print(f"wrote {OUT} ({sum(len(v) for v in groups.values())} colours)")


if __name__ == "__main__":
    main()
