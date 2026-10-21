"""Hermes on the web in a chat, for the combined mock (`docs/web.md` §4): turns that sign in, enter a
2FA code and fill a card the way Hermes Agent's `browser_vault` tool does (`tools/browser_vault_tool.py`),
over Bot Mode's socket, where the vault's prompts can be asked:

  - "sign in to vercel": browser_navigate, browser_vault list, then fill with Hermes's vault login
    (no prompt), then enter_code from the authenticator key.
  - "sign in to github": the login lives in 1Password; while it's locked the fill asks
    vault.unlock_prompt (120 s; "" keeps it locked → unlock_cancelled), then vault.code (180 s;
    "" → code_declined).
  - "sign in to linear": nothing saved: vault.save_login (180 s; "" → save_declined), saved to the
    mock vault and filled at once.
  - "reorder" (cat food on Amazon): browser_vault fill of the Personal Visa → an approval with
    command "Fill payment card 'Personal Visa' on https://www.amazon.com" and pattern_key
    mcp_elicitation, like `_confirm_payment_fill`; once → filled, anything else → payment_declined.
  - "wrong site": a fill on gist.github.com refused with origin_mismatch.

Answers are never echoed: a tool result carries counts and origins only, like Hermes's.
"""

import json
import time
import uuid

B = None  # backend.py's module globals
G = None  # server.py
C = None  # chats.py
V = None  # vault.py


def install(backend_globals, gateway_module, chats_module, vault_module):
    global B, G, C, V
    B, G, C, V = backend_globals, gateway_module, chats_module, vault_module
    original_start = B["start_turn"]

    def start_turn(sid, text, runner):
        lower = (text or "").lower()
        if any(k in lower for k in ("sign in to vercel", "sign in to github", "sign in to linear", "reorder", "wrong site")):
            return original_start(sid, text, web_turn)
        return original_start(sid, text, runner)

    B["start_turn"] = start_turn


def helpers(sid):
    runtime = B["RUNTIME"][sid]
    if runtime.get("kind") == "chat":
        def tool(stored, name, args, result, seconds=0.6):
            C.tool(sid, stored, name, args, seconds, context=args.get("url") or "", result=json.dumps(result))
        return tool, lambda text: C.stream(sid, text), lambda stored, text: C.finish(sid, stored, text)

    def tool(stored, name, args, result, seconds=0.6):
        B["tool"](sid, stored, name, args, json.dumps(result), seconds, args.get("url") or "")
    return tool, lambda text: B["stream"](sid, text), lambda stored, text: B["finish"](sid, stored, text)


def web_turn(sid, text):
    runtime = B["RUNTIME"][sid]
    if runtime.get("kind") == "chat":
        stored = runtime["stored"]
        G.add_message(stored, "user", text)
    else:
        stored = B["ensure_row"](sid)
        B["add_message"](stored, "user", text)
    B["emit"](sid, "session.info", {"running": True})
    B["emit"](sid, "message.start", {})
    tool, stream, finish = helpers(sid)
    ask = B["server_request"]
    lower = text.lower()
    time.sleep(0.3)

    def navigate(url, title):
        tool(stored, "browser_navigate", {"url": url}, {"success": True, "url": url, "title": title})

    def listing():
        items = V.method_list({"profile": runtime.get("profile")})["items"]
        logins = [{"handle": i["id"], "label": i["label"], "origin": i["origin"], "identifier": i.get("identifier")}
                  for i in items if i["kind"] == "login"]
        payments = [{"handle": i["id"], "label": i["label"], "origin": i["origin"]} for i in items if i["kind"] == "payment"]
        tool(stored, "browser_vault", {"action": "list"}, {"success": True, "logins": logins, "payments": payments,
                                                          "addresses": [], "locked": []}, seconds=0.3)

    if "wrong site" in lower:
        navigate("https://gist.github.com/login", "Sign in to GitHub · Gist")
        tool(stored, "browser_vault", {"action": "fill", "handle": "op:k3v9github"}, {
            "success": False, "error_type": "origin_mismatch",
            "error": "Refused: current page origin (https://gist.github.com) does not match the vault item's bound "
                     "origin(s) (https://github.com). Vault fills only run on the exact origin(s) the credential was saved for."})
        answer = "Your GitHub login is saved for github.com only, so I didn't fill it on gist.github.com."
    elif "reorder" in lower:
        navigate("https://www.amazon.com/gp/cart/view.html", "Amazon.com Shopping Cart")
        stream("Your usual order is in the cart: Purina Pro Plan, 16 lb, $38.20. Paying needs your OK.")
        listing()
        choice = (ask(sid, "approval", {
            "request_id": uuid.uuid4().hex, "command": "Fill payment card 'Personal Visa' on https://www.amazon.com",
            "description": "The agent wants to enter your saved card details into this checkout page. The card number and "
                           "CVC never enter the conversation. Approve only if you intend to pay here.",
            "pattern_key": "mcp_elicitation", "pattern_keys": ["mcp_elicitation"]}) or {}).get("choice")
        if choice in ("once", "session", "always"):
            tool(stored, "browser_vault", {"action": "fill", "handle": "vault_9f2b4d6e8a0c"}, {
                "success": True, "filled_fields": 4, "backend": "local", "kind": "payment", "origin": "https://www.amazon.com",
                "fields": ["cc-csc", "cc-exp-month", "cc-exp-year", "cc-number"]})
            answer = "The card is filled in on the checkout page. I stopped before Place your order: that last tap is yours."
        else:
            tool(stored, "browser_vault", {"action": "fill", "handle": "vault_9f2b4d6e8a0c"}, {
                "success": False, "error_type": "payment_declined",
                "error": "The user did not confirm filling this payment card. Do not retry; ask them instead."}, seconds=0.2)
            answer = "Okay, I didn't fill the card. The cart is still there when you want it."
    elif "sign in to github" in lower:
        navigate("https://github.com/login", "Sign in to GitHub")
        _, managers = V.state({"profile": runtime.get("profile")})
        if not V.live(managers["onepassword"], touch=False):
            password = (ask(sid, "vault.unlock_prompt", {"backend": "onepassword", "display_name": "1Password"}, timeout=120) or {}).get("value") or ""
            if not password:
                tool(stored, "browser_vault", {"action": "fill", "handle": "op:k3v9github"}, {
                    "success": False, "error_type": "unlock_cancelled", "error": "The user declined to unlock 1Password."}, seconds=0.2)
                stream("1Password is still locked, so I didn't sign in.")
                return finish(stored, "1Password is still locked, so I didn't sign in.")
            managers["onepassword"]["token_at"] = time.monotonic()
            del password
        tool(stored, "browser_vault", {"action": "fill", "handle": "op:k3v9github"}, {
            "success": True, "filled_fields": 1, "backend": "onepassword", "kind": "login", "origin": "https://github.com",
            "next": "Submit. If the site then asks for a verification code, call browser_vault action=enter_code with this handle (a code will be generated automatically)."})
        code = (ask(sid, "vault.code", {"site": "github.com", "hint": "GitHub sent a code to your authenticator app."}, timeout=180) or {}).get("value") or ""
        if code:
            tool(stored, "browser_vault", {"action": "enter_code", "handle": "op:k3v9github"}, {
                "success": True, "filled_fields": 1, "origin": "https://github.com", "source": "user"})
            answer = "Signed in to GitHub. Your notifications page shows 3 unread reviews."
        else:
            tool(stored, "browser_vault", {"action": "enter_code", "handle": "op:k3v9github"}, {
                "success": False, "error_type": "code_declined", "error": "The user did not enter a code. Do not ask again this turn."}, seconds=0.2)
            answer = "GitHub wants a code to finish signing in. Send it when you have it."
        del code
    elif "sign in to linear" in lower:
        navigate("https://linear.app/login", "Log in · Linear")
        raw = (ask(sid, "vault.save_login", {"origin": "https://linear.app", "site": "linear.app"}, timeout=180) or {}).get("value") or ""
        try:
            login = json.loads(raw) if raw else None
        except ValueError:
            login = None
        del raw
        if not isinstance(login, dict) or not login.get("password"):
            tool(stored, "browser_vault", {"action": "save_login", "label": "linear.app"}, {
                "success": False, "error_type": "save_declined",
                "error": "The user chose not to save a login for this site. Do not ask again this turn."}, seconds=0.2)
            answer = "Okay, I won't sign in to Linear."
        else:
            identifier = str(login.get("identifier") or "")
            V.method_add({"profile": runtime.get("profile"), "kind": "login", "label": "linear.app", "origin": "https://linear.app",
                          "secret": {"identifier_type": "email" if "@" in identifier else "username", "identifier": identifier,
                                     "password": login["password"]}})
            del login
            tool(stored, "browser_vault", {"action": "save_login", "label": "linear.app"}, {
                "success": True, "saved": True, "filled_fields": 1, "origin": "https://linear.app", "backend": "local", "kind": "login"})
            answer = "Saved your Linear login in Hermes's vault and signed in."
    else:
        navigate("https://vercel.com/login", "Log in to Vercel")
        listing()
        tool(stored, "browser_vault", {"action": "fill", "handle": "vault_7c1e0a9b2d4f"}, {
            "success": True, "filled_fields": 1, "backend": "local", "kind": "login", "origin": "https://vercel.com",
            "next": "Submit. If the site then asks for a verification code, call browser_vault action=enter_code with this handle."})
        tool(stored, "browser_vault", {"action": "enter_code", "handle": "vault_3e5a7c9d1b2f"}, {
            "success": True, "filled_fields": 1, "origin": "https://vercel.com", "source": "local"}, seconds=0.4)
        answer = "Signed in to Vercel. Yesterday's deploy failed on the build step: `next build` ran out of memory."
    stream(answer)
    return finish(stored, answer)
