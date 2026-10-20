"""Generated plain text for the everyday cards (design 566b144): a quote's stats and previous close, a
flight, a watched price, and weather alerts. Each follows its spec's "Text fallback" rule."""
from __future__ import annotations

import copy
import json
from pathlib import Path

import pytest

from harness import plugin_module

SPEC = Path(__file__).resolve().parents[1] / "spec"


def example(name: str) -> dict:
    payload = json.loads((SPEC / "examples" / f"{name}.json").read_text())
    payload.pop("fallback_text", None)
    return payload


@pytest.fixture
def f(hermes):
    return plugin_module("fallback")


def test_a_quote_reads_its_stats_and_previous_close(f):
    text = f.generate(example("chart-4"))
    assert text.startswith("AAPL · Apple (Nasdaq · closed · 15 min delayed): $242.18 at the close (+1.4% today), Fri 16 Oct.")
    assert "Prev close $238.84." in text  # the target in the axis's currency, not a bare 238.84
    assert "Open $239.10, high $243.90, low $238.70, volume 41.2M." in text
    assert "15:30" not in text  # the stats are the key values; the series isn't retold


def test_a_flight_reads_like_the_spec(f):
    flight = example("route-4")
    assert f.generate(flight) == ("UA 1187 Newark → San Francisco, Tue 20 Oct: in the air, left gate C112 at 11:02. "
                                  "Landing at Terminal 3 at 14:16 San Francisco time, 4 minutes early; baggage belt 7.")
    waiting = copy.deepcopy(flight)
    waiting["status"] = {"state": "warning", "label": "Delayed"}
    waiting["flight"].update(state="delayed", changes=["Departure +20 min"])
    waiting["flight"]["depart"] = {"airport": "EWR", "terminal": "C", "gate": "C112",
                                   "scheduled": "2026-10-20T10:55:00-04:00", "estimated": "2026-10-20T11:15:00-04:00"}
    waiting["flight"]["arrive"].pop("estimated")
    text = f.generate(waiting)
    assert "delayed, leaves terminal C, gate C112 at 11:15 (20 minutes late)" in text
    assert "Landing at Terminal 3 at 14:20 San Francisco time; baggage belt 7." in text and "Departure +20 min." in text
    gone = copy.deepcopy(flight)
    gone["status"] = {"state": "critical", "label": "Cancelled"}
    gone["flight"]["state"] = "cancelled"
    assert f.generate(gone) == "UA 1187 Newark → San Francisco, Tue 20 Oct: cancelled."


def test_a_watched_price_says_when_it_is_the_lowest(f):
    product = example("entity-4")
    text = f.generate(product)
    assert "$349 (was $399, −12.5% since yesterday): lowest in 90 days." in text
    assert "(2,140 ratings)" in text
    higher = copy.deepcopy(product)
    higher["price"]["lowest"] = {"amount": {"value": 329, "format": "currency", "currency": "USD"}, "label": "All-time low"}
    assert "; all-time low: $329." in f.generate(higher)
    history_only = copy.deepcopy(product)
    history_only["price"].pop("lowest")
    assert "; between $349 and $399 recently." in f.generate(history_only)


def test_a_weather_alert_leads(f):
    text = f.generate(example("weather-3"))
    assert text.startswith("New York, Saturday: 52°F and windy (feels 46°), high 58°, low 47°. "
                           "Wind advisory: gusts to 45 mph, 10:00–18:00 (National Weather Service).")
    assert text.index("Wind advisory") < text.index("A jacket for the ferry")
    severe = example("weather-3")
    severe["alerts"][0].update(severity="critical", until="2026-11-01T06:00:00-04:00")
    assert "Warning: Wind advisory: gusts to 45 mph, Sat 31 Oct at 10:00 – Sun 1 Nov at 06:00" in f.generate(severe)


@pytest.mark.parametrize("name", ["chart-4", "route-4", "entity-4", "weather-3"])
def test_the_new_cards_are_accepted_with_generated_text(widgets, name):
    from harness import as_input, call, session
    payload = as_input(json.loads((SPEC / "examples" / f"{name}.json").read_text()))
    payload.pop("fallback_text")
    with session(platform="api_server", session_id="sess-app", profile="hermes"):
        result = call(widgets, {"op": "create", "payload": payload})
    assert "error" not in result, result
    assert result["fallback_text"] == plugin_module("fallback").generate(result["payload"] | {"fallback_text": ""})
