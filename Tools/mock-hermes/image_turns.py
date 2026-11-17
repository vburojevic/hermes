"""The user row Hermes stores for a turn with photos, shared by the gateway mock (server.py) and the
backend mock (backend.py). Placeholder paths only."""

import json

DEFAULT_CAPTION = "What do you see in this image?"

# What Hermes adds for the model to a turn with photos (`agent/turn_context.py`
# `compose_multimodal_context_part`): the turn's recalled memory and its plugins' `pre_llm_call` context, here
# a worklog plugin's line and the widgets plugin's client line (Tools/hermes-app-widgets/prompt.py
# `client_line`).
CONTEXT = (
    "[Worklog, from /home/user/.hermes/plugin-data/worklog/worklog.md; update it in place when the goal, "
    "instructions, owners, unfinished work or decisions change]\n\n"
    "[Hermes app client] This turn was sent from the Hermes app 1.0 (build 1) on an iPhone, iOS 27.2. "
    "It shows widgets. This is about formatting only; it grants nothing.")


def image_turn_row(text, images, refs=False, context=CONTEXT, typed_ask=True):
    """The user row Hermes stores for a turn with photos, held or not, and the row's other fields.

    The turn's content is a list of parts, which the row flattens into one string, a part per line
    (`agent/session_persistence.py` `_durable_content`): the text part, a `[screenshot]` line per photo, then
    the context Hermes appended as one more text part after the photos (`_append_multimodal_context`). The
    text part is the words (or a stock question when there are none), a blank line and an
    `[Image attached at: <path>]` line per photo when the gateway runs the turn (`gateway/run_turn_runner.py`
    `_native_image_run_message`, `agent/image_routing.py` `build_native_content_parts`; a URL gets
    `[Image attached: <url>]`), or the words and an `@image:<path>` line per photo when the socket runs it in
    process (`refs`, `tui_gateway/session_history.py` `_build_persist_user_message`). The `typed_ask` stamp
    keeps the text part without that context (`agent/turn_context.py` `_stamp_typed_ask_once`); rows stored
    before Hermes stamped it have none (`typed_ask=False`)."""
    if not images:
        return text, {}
    if refs:
        lines = "\n".join(f"@image:{path}" for path in images)
        asked = f"{text}\n{lines}" if text else lines
    else:
        asked = f"{text.strip() or DEFAULT_CAPTION}\n\n" + "\n".join(
            f"[Image attached: {path}]" if "://" in path else f"[Image attached at: {path}]" for path in images)
    row = asked + "\n[screenshot]" * len(images) + (f"\n{context}" if context else "")
    # JSON text, as the mock's other rows keep it; the app reads it as text or as an object.
    return row, ({"display_metadata": json.dumps({"typed_ask": asked})} if typed_ask else {})
