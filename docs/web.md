# Hermes on the web: passwords and its browser

Hermes can browse the web for the person. It signs in with their logins and fills a card only with
their OK. This doc covers:

- **Passwords** (§3): where Hermes finds logins, and what it can fill.
- **In a chat** (§4): signing in, a card that needs the person's OK, and what goes wrong in words.
- **Browser** (§5): where Hermes browses.
- **Browsing in this app** (§6): Hermes driving a web view in the Inspector, with the person's turn
  at a sign-in page.

**The promise the app keeps:** Hermes never sees a password. The gateway fills a login only on its
exact site, and a card fill needs the person's OK every time. Everything here is built so that no
password, card number, security code or one-time code is ever shown, logged, cached, stored or put
in a notification by the app (§8).

Design: `blocks/web.elyx` (`sourceRow`, `loginRow`, `cardRow`, `addressRow`, `neverSees`,
`browserOption`, `approvalPayment`, `signInStep`, `signInYourselfBar`), `screens/iphone/web.elyx`
(`passwordsPage`, `passwordsPageMore`, `passwordDetail`, `passwordAdd`, `passwordsUnlock`,
`browserPage`, `browserPageMore`, `browserProfileConsent`, `webSignIn`, `webPayment`, `webInApp`,
`webInAppYourTurn`), `screens/ipad/web.elyx` (`ipadPasswords`, `ipadWebInApp`) and
`screens/mac/web.elyx` (`macSettingsPasswords`, `macSettingsBrowser`, `macWebInApp`,
`macWebInAppYourTurn`, `macWebPayment`).

Hermes Agent sources (checked against 0.22.2): `tui_gateway/methods_vault.py`,
`agent/vault_store.py`, `agent/vault_backends/` (`base.py`, `local.py`, `onepassword.py`,
`bitwarden.py`, `unlock.py`), `tools/browser_vault_tool.py`, `tui_gateway/agent_callbacks.py` and
`contracts/server_requests.py` (the in-chat requests), `tui_gateway/methods_tools.py`
(`browser.manage`), `methods_browser.py`, `methods_browser_control.py`,
`gateway/browser_control_broker.py`, `gateway/platforms/api_server.py` (the controller's register
and socket), `tools/browser_extension_router.py`, and the desktop app's `vault-settings.tsx` and
`browser-real-profile-panel.tsx`.

## 1. Calls

| Need | Call | Notes |
|---|---|---|
| Where logins come from | `vault.sources {profile}` | `{sources: [{name, display_name, enabled, needs_unlock, unlocked, installed}]}`. `local` (Hermes vault) is always listed, enabled and unlocked; then `onepassword` (`op`) and `bitwarden` (`bw`). Hermes counts a manager as enabled only when its CLI is installed |
| Logins, cards, addresses | `vault.list {profile}` | `{items: [{id, kind (login / payment / address), label, origin, created_at, identifier?, identifier_type?, has_otp?, allowed_origins?, backend}]}`: metadata only. A locked manager adds nothing |
| Turn a manager on or off | `vault.source.set {name, enabled}` | Writes `vault.<name>.enabled`; turning one off also locks it. Unknown names: 5095 "unknown vault source: <name>" |
| Unlock | `vault.unlock {name, password}` | The master password goes to the manager's CLI on stdin (`op`) or in the child's environment (`bw`); only a session token stays, in memory. 5095 with the manager's words when it fails |
| Lock | `vault.lock {name?}` | No `name` locks every manager. A token also expires after 30 minutes idle, when the session that unlocked it ends, or at shutdown |
| Add (Hermes's vault only) | `vault.add {kind, label, origin, secret}` → `{id}` | §3.3. Errors are 5095 with Hermes's `VaultError` words, scrubbed of the secret |
| Remove (Hermes's vault only) | `vault.remove {id}` → `{removed}` | Manager items can't be removed here |

All of them are JSON-RPC on Bot Mode's socket (`hermes serve`), so Passwords needs Bot Mode. A Hermes
from before Passwords answers -32601 (`HermesVersionGap`).

Code: `VaultSource`, `VaultItem`, `VaultOrigin`, `VaultDraft`, `VaultClient`, `VaultCopy` (HermesKit,
`Web/`, tested in `VaultTests`), `PasswordsModel` (app), the views in `App/Views/Web/`.

## 2. Where it lives

- **iPhone and iPad:** Settings → Hermes on <gateway> → **Passwords**, after Memory ("Hermes vault
  and 1Password · 50 logins"). The page has two columns when it's at least 760 points wide (an iPad
  in landscape, `ipadPasswords`); otherwise a login pushes its own page.
- **Mac:** a **Passwords** tab in Settings, between Apps & Tools and Memory
  (`macSettingsPasswords`): search, sources, logins, then cards and addresses on the left, the chosen
  item on the right. Add (+) and Lock All sit under the list, since a Settings tab has no toolbar of
  its own.
- **Settings → Setup** lists Passwords ([setup.md](setup.md) §4.19).
- **Needs Bot Mode.** Without it, or while it can't connect, the page is `BotModeSetupMessage`
  with Link Bot Mode… or Sign In…. An older Hermes shows "Needs a newer Hermes Agent" with
  `hermes update`.

## 3. Passwords

### 3.1 Sources

Sources come first, in the gateway's order: Hermes vault, then each manager (`sourceRow`).

| State | Row | Action |
|---|---|---|
| Hermes vault | ink key tile, "Encrypted on Studio Mac · 4 items" | – |
| Unlocked | "Unlocked · locks after 30 min idle · 3 logins" | **Lock** (`vault.lock {name}`) |
| Locked | "Locked · Hermes asks when it needs a login" | **Unlock** → `passwordsUnlock` |
| Off | "Off · Hermes doesn't use it" | a switch → `vault.source.set {enabled: true}` |
| Not on the gateway | dimmed: "Not on Studio Mac · install the Bitwarden CLI (bw)" | – (Setup gives the command) |

An unlocked or locked manager has **Turn Off <manager>** in its context menu. A row with a call on
its way shows a `Spinner` where its button was. The footer: "When Hermes needs a login from a
locked manager, it asks for the master password in the chat. That goes straight to the manager;
only a session token stays, for 30 minutes idle at most."

**Unlock** (`passwordsUnlock`) is the chat's unlock card as a sheet (a partial sheet on iPhone):
"Unlock 1Password", "Hermes · Studio Mac", what it means, the master password in a `MaskedField`
(Show, no paste button), "Goes straight to 1Password on Studio Mac. Only a session token stays
there, until it locks.", **Keep Locked** / **Unlock**. The field is emptied the moment Unlock is
pressed; the typed value passes into one `vault.unlock` call and nothing keeps it. A failure says
why in words (`VaultCopy.unlockFailure`): "That password didn't unlock 1Password.", "Bitwarden
isn't signed in on Studio Mac yet…", a time-out, or a lock that raced it.

**Lock All Password Managers** (`vault.lock` without a name) shows when there's a manager, enabled
while one is unlocked: "Hermes asks for a master password again the next time it needs a login."

A manager that locks (Lock, Lock All, 30 minutes idle, turning it off) drops its logins from the
list the next time the page reads (on appear, pull to refresh, every action, and when Bot Mode
reconnects).

### 3.2 The lists

- **Logins · N** (`loginRow`): the site's first letter on a white tile, the name, **2FA** when
  `has_otp`, "username · site", the source as a tag. VoiceOver reads "GitHub, sam-k, in 1Password,
  2FA". A search field on top goes over names and sites only (`VaultItem.matches`).
- **Payment cards** (`cardRow`): a card tile, the name, "For www.amazon.com", the source. Footer:
  "Filling a card is always a request in the chat: the card, the page, and Fill Card or Don't Fill.
  Every time."
- **Addresses** (`addressRow`): a house tile, the name, the site.
- Then **Add Login…**, **Add Card…**, **Add Address…**, Lock All, and the promise (`neverSees`):
  "Hermes never sees a password. The gateway fills it into the site it belongs to, and only there."

`vault.list` carries no card brand, last digits, expiry or address line (they're all in the
encrypted part), so the rows show the name the person gave and the site: never more than Hermes
itself sees.

**A login** (`passwordDetail`): the tile, name and site; Username, Password ("Hermes can't show
it"), One-time codes ("From 1Password", "From your authenticator key", or "Hermes asks you for
them"), Fills on ("github.com only", or every site a manager item lists); Where it lives: Source and
Added. A card shows Card ("Hermes can't show it") and Filling ("Asks you every time"); an address,
Address ("Hermes can't show it").
- **Hermes vault items:** a red **Remove from Hermes's Vault**, confirmed ("Hermes can't sign in to
  github.com with it anymore.") → `vault.remove`.
- **Manager items:** "Edit or delete it in 1Password. Changes show up here the next time Hermes
  reads it." On the Mac, **Open 1Password** opens the app when it's installed (the gateway's item
  ids don't say which account or vault, so the app opens, not the item).

### 3.3 Adding

`passwordAdd`: a sheet with Login / Card / Address (segmented), Cancel and ✓ Save. The desktop
app's fields, Hermes's names (`PAYMENT_FIELDS`, `ADDRESS_FIELDS`):

| Kind | Fields | Sent as `secret` |
|---|---|---|
| Login | Website, Username, Password, Name (optional: the site stands in), Authenticator key (optional: Base32 or `otpauth://totp/…`) | `identifier_type` (email when it has @, phone when it's digits, else username), `identifier`, `password`, `otp_secret?` |
| Card | Website, Name (required, "Personal Visa"), Card number, Name on card, Expiry (MM / YYYY), Security code, Postal code | `card_number` (spaces dropped), `exp_month` (two digits), `exp_year` (four), `cvc`, `cardholder_name?`, `billing_postal_code?` |
| Address | Website, Name ("Home"), Address, Line 2, City, State, Postal code, Country | `address_line1`, `address_line2?`, `city`, `state?`, `postal_code`, `country` |

- **Website** is required for every kind, as on the desktop: an item without a site can't be
  filled. A bare name gets https; the origin sent is `scheme://host[:port]` (`VaultOrigin`), the
  same normalization Hermes applies, so the footer can say exactly where it fills.
- `VaultDraft.problem` runs Hermes's own checks before anything is sent (site, username, password,
  authenticator key, card number length, expiry, security code, address lines), and Save stays off
  until they pass.
- **Secrets:** Save copies the draft into the one `vault.add` call and empties the password,
  authenticator key, card number and security code fields at once; if the call fails, the person
  types them again. The fields are `privacySensitive`, have no AutoFill content type (what's typed
  belongs in Hermes's vault, not iCloud Keychain), and nothing about them is logged.
- The footer says what happens: "Saved encrypted in Hermes's vault on Studio Mac. Hermes fills it
  only on github.com and never sees it. With an authenticator key, it enters 2FA codes by itself."
  A card's: "Hermes sees the name, never the number, and asks you every time before it fills the
  card on www.amazon.com."

### 3.4 What's true underneath, and stays true in the copy

- The model never sees a password or card number: the gateway types them into the page and redacts
  them from output. The identifier (username or email) is visible to Hermes on purpose: it types it.
- A fill happens only on the item's exact origin, checked again at fill time; no subdomains.
- Logins and addresses fill without asking. Cards always ask (§4).
- Hermes's vault is encrypted in the profile's folder on the gateway, with a key stored beside it:
  "Encrypted on Studio Mac", never "end to end".

## 4. In a chat

Not built yet (the next piece): `signInStep`, the corrected `vaultUnlock` / `vaultSaveLogin` copy,
`approvalPayment` with Face ID, and errors in words.

## 5. Browser

Not built yet.

## 6. Browsing in this app

Not built yet.

## 7. Words

- "Passwords", "logins", "Hermes's vault", "Hermes vault" (a source's name, as Hermes says it).
- Never "credentials", "secrets" or "vault backend".
- "Fill", "sign in", "your turn", "Take Over", "Hand Back".
- A card is never "paid" by Hermes. It fills the card; the person decides.

## 8. Checks

- Passwords on iPhone, iPad (both orientations) and Mac, against the mock (§10): the three source
  states, Lock, Unlock (a wrong master password says so; one with "slow" times out in words), Off
  and its switch, Lock All, Add Login / Card / Address (each refusal from §3.3 keeps Save off),
  Remove with its confirmation, and a manager whose idle time runs out losing its logins.
- No master password, password, card number, security code or code appears on screen after it's
  sent, in the app's logs, or in any request but the one call that carries it.
- Light, dark and Increase Contrast; VoiceOver reads a login row as "GitHub, sam-k, in 1Password,
  2FA" and each source row's state.

## 9. Open points

- **No card or address details in `vault.list`.** The design shows "Visa •• 4242 · expires 08/28"
  and an address's first line; Hermes keeps all of those encrypted, so the rows show the name and
  the site. A gateway field for display-safe card facts (brand, last four, expiry) would allow
  more.
- **`vault.list` has no "last used".** The detail shows Added only.
- **No account or vault in a manager item's id**, so the Mac opens 1Password rather than the item.
- **Hermes's vault has no master password** (its key is a file beside it). Worth a gateway option
  to protect it with the macOS Keychain or a passphrase.

## 10. Mocks and flags

`Tools/mock-hermes/vault.py` (in the combined backend) answers every `vault.*` call like Hermes,
refusals included. Demo data is Sam's: Hermes's vault holds Vercel, Example Cloud (with an
authenticator key), Personal Visa (the 4242 test number) and Home; 1Password (locked) holds GitHub,
Linear and Amazon; Bitwarden isn't installed. A master password containing "wrong" fails with
1Password's words; one containing "slow" times out after 20 s; any other unlocks.

`POST /api/mock/vault` switches it: `{"idle": 60}` makes an unlock expire after a minute idle,
`{"onepassword": "missing"|"off"|"locked"|"unlocked"}` (and `"bitwarden"`) sets a manager's state,
`{"older": true}` answers every `vault.*` with -32601, `{"reset": true}` puts the demo data back.

`-HERMES_PASSWORDS YES` opens Passwords (iPhone and iPad: with `-HERMES_OPEN settings`; the Mac
opens its Settings window on the tab); `add:login|payment|address`, `unlock:<source>` and
`item:<id>` open a sheet or an item there.
