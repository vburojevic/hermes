#!/usr/bin/env python3
"""Copy the widget spec from the design project into the plugin (maintainers only).

    python3 Tools/hermes-app-widgets/sync-spec.py [~/Documents/Elyx/Hermes]

The design project generates docs/widgets/ from tools/widgets/; this copies the generated schemas,
examples, catalog.json and semantic-rules.json verbatim, ships agent-usage.md as the `widgets` skill,
and writes spec/symbols.json (the SF Symbol names controls/symbols.elyx can draw, for the icon
allowlist warning, payload-contract.md §7). Never edit the copies by hand: edit the model there,
regenerate, and run this again.
"""
from __future__ import annotations

import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
# payload-contract.md §7: the core set agents should reach for.
CORE = """checkmark.circle.fill exclamationmark.triangle.fill xmark.octagon.fill info.circle.fill questionmark.circle.fill
clock.fill hourglass house.fill building.2.fill cart.fill creditcard.fill banknote.fill gift.fill ticket.fill airplane
car.fill tram.fill bicycle figure.walk figure.run fork.knife carrot.fill pills.fill cross.case.fill heart.fill
bed.double.fill waveform.path.ecg allergens leaf.fill drop.fill flame.fill bolt.fill lightbulb.fill sofa.fill
thermometer.medium sun.max.fill cloud.fill cloud.sun.fill cloud.rain.fill cloud.bolt.rain.fill cloud.snow.fill
cloud.fog.fill wind umbrella.fill moon.stars.fill sunrise.fill sunset.fill doc.fill doc.text folder.fill terminal
hammer arrow.triangle.branch server.rack cpu externaldrive.fill network chart.bar.fill chart.line.uptrend.xyaxis
chart.pie.fill checklist calendar envelope.fill message.fill newspaper.fill person.fill person.2.fill trophy.fill
medal.fill star.fill graduationcap.fill book.fill sportscourt.fill gamecontroller lock.fill key.fill shippingbox.fill
storefront.fill map.fill location.fill mappin.and.ellipse""".split()


def main() -> None:
    project = Path(sys.argv[1] if len(sys.argv) > 1 else Path.home() / "Documents" / "Elyx" / "Hermes").expanduser()
    source = project / "docs" / "widgets"
    spec = HERE / "spec"
    for name in ("schemas", "examples"):
        shutil.rmtree(spec / name, ignore_errors=True)
        shutil.copytree(source / name, spec / name)
    for name in ("catalog.json", "semantic-rules.json"):
        shutil.copy2(source / name, spec / name)
    (HERE / "skills" / "widgets").mkdir(parents=True, exist_ok=True)
    shutil.copy2(source / "agent-usage.md", HERE / "skills" / "widgets" / "SKILL.md")

    names = set(CORE)
    elyx = (project / "controls" / "symbols.elyx").read_text()
    for name in re.findall(r'import "resources/assets/symbols/([a-z0-9.]+)\.svg"', elyx):
        base = re.sub(r"(\.circle)?(\.fill)?$", "", name)
        names |= {name, base, f"{base}.fill", f"{base}.circle", f"{base}.circle.fill"}
    revision = subprocess.run(["git", "-C", str(project), "rev-parse", "--short", "HEAD"],
                              capture_output=True, text=True).stdout.strip()
    (spec / "symbols.json").write_text(json.dumps(
        {"$comment": "SF Symbols the widget designs can draw: controls/symbols.elyx with their .fill / .circle "
                     "forms, plus the core set in payload-contract.md §7. Written by sync-spec.py.",
         "symbols": sorted(names)}, indent=1) + "\n")
    (spec / "VERSION").write_text(f"{revision or 'unknown'}\n")
    print(f"spec synced from {project} at {revision or '?'}: {len(names)} symbols")


if __name__ == "__main__":
    main()
