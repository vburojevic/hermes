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
- **Browser:** Settings → Hermes on <gateway> → **Browser**, after Passwords ("A clean browser on
  Studio Mac"); Apps and Tools → Built-in shows the same row under the Browser toolset. On the Mac
  it's an item of its own in Apps & Tools, under Built-in (`macSettingsBrowser`), with "And
  Passwords" under it, which opens the Passwords tab.
- **Settings → Setup** lists Passwords and Browser ([setup.md](setup.md) §4.19, §4.20).
- **Needs Bot Mode.** Without it, or while it can't connect, each page is `BotModeSetupMessage`
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

### 4.1 Steps

Browser and Passwords steps read as what happened, from the call's arguments and Hermes's JSON
result (`WebStep`, HermesKit; `ToolStepLine` in the transcript). Never a username, password or code:
`browser_type` shows no text, and `browser_vault`'s arguments and results never carry a secret.

| Call | Running | Done | Second line |
|---|---|---|---|
| `browser_navigate {url}` | Opening vercel.com | Opened vercel.com | `vercel.com/login` (no query), monospaced |
| `browser_type {ref, text}` | Typing into the page | Typed into the page | – |
| `browser_exec {code}` (Browser Use) | the script's first `# comment`, capitalized | the same | – |
| `browser_vault list` | Looking up your logins | Looked up your logins | – |
| `browser_vault fill` (a login, `signInStep`) | Signing in | Signed in to vercel.com | "Your login from 1Password · Hermes never saw the password" (`backend`: Hermes's vault, 1Password, Bitwarden) |
| `browser_vault fill` (a card) | Signing in | Filled your card on amazon.com | "Hermes never saw the number" |
| `browser_vault fill` (an address) | Signing in | Filled your address on amazon.com | "From Hermes's vault" |
| `browser_vault enter_code` | Entering the 2FA code | Entered the 2FA code | From 1Password / From your authenticator key / From you (`source`) |
| `browser_vault save_login` | Asking you to save a login | Saved a login for linear.app | "In Hermes's vault · Hermes never saw the password" |
| `browser_vault unlock {backend}` | Unlocking 1Password | Unlocked 1Password | – |

**Errors, in words** (`error_type` in the result):

| `error_type` | Words |
|---|---|
| `origin_mismatch` | "Your login is for github.com, not this page." (the item's origins from Hermes's refusal; the step's title becomes "Didn't sign in") |
| `unlock_required`, `unlock_cancelled`, `unlock_failed` | "1Password is locked." |
| `no_code_field` (passkey, security key, app approval) | "Finish signing in on your device." |
| `save_declined`, `payment_declined` | a quiet note: "Not filled." (`code_declined`: "No code entered.") |
| `human_has_control` | "You're in control of the browser; Hermes is waiting." |
| `supervisor_required` (the app's browser) | "Passwords can't fill a page in this app's browser. It's your turn to sign in." |
| `origin_changed` | "The page changed before Hermes could fill it. Nothing was written." |
| `no_origin` | "It has no site saved with it, so Hermes can't fill it anywhere." |

### 4.2 Requests

The docked glass cards ([quick-actions.md](quick-actions.md)), from the backend socket's server
requests (`tui_gateway/agent_callbacks.py`, `contracts/server_requests.py`). The API server installs
no prompt callbacks (headless), so these come only in chats that run over Bot Mode's socket.

| Request | Card | Answer |
|---|---|---|
| `vault.unlock_prompt {backend, display_name}` | `vaultUnlock`: "Unlock 1Password", the master password (`MaskedField`, no paste), "Goes straight to 1Password on Studio Mac. Only a session token stays, and it locks after 30 minutes idle." **Keep Locked** / **Unlock** | `{value}`; Keep Locked answers `""`. 120 s |
| `vault.save_login {origin, site}` | `vaultSaveLogin`: "Save a login for linear.app", the origin, username, password. "Saved encrypted in Hermes's vault on Studio Mac. Hermes fills it in and never sees it." **Not Now** / **Save & Sign In** | `{value: "{\"identifier\":…,\"password\":…}"}`; Not Now answers `""`. 180 s |
| `vault.code {site, hint}` | `codeAsk`: six boxes, Paste Code, one-time-code AutoFill | `{value}`. 180 s |
| `approval` whose command is "Fill payment card '<label>' on <origin>" | `approvalPayment` (`PaymentApprovalCard`): "Fill your card on amazon.com?", the card's name and the page, "The number and CVC never enter the chat. Approve only if you mean to pay here. Hermes asks every time." **Don't Fill** / **Fill Card** | Fill Card asks for Face ID, Touch ID or the passcode (`OwnerCheck`, `.deviceOwnerAuthentication`; a device with none can't answer), then `once`; Don't Fill answers `deny`. No Always, no … menu |

A card fill is recognized by its command (`PaymentFill`, HermesPush): Hermes sends it as a generic
approval with `pattern_key: mcp_elicitation`, and its `vault-payment` surface reaches only plugins'
hooks (§9). Anything that starts the same way gets the card fill's stricter card, which costs
nothing; a real card fill never gets less. It's never answered from the dock's quick buttons, a
batch ("Allow all"), Talk, a notification or the Lock Screen.

What the person types into these cards goes into the one answer and is cleared from the card at
once. A password or code is never kept for later (unlike approvals and questions, which wait in
`AnswerLedger` for a reconnect): with no socket to take it at that moment, the card comes back to be
answered again.

### 4.3 Notifications

- A card fill (`NoticePresentation`; `PushNotice.isPaymentFill`: the notice's `surface` is
  `vault-payment`, which the push plugin hears, or its command reads as one): "Fill your card on
  amazon.com?" · "Open the chat to decide. Fill Card asks for Face ID.", Time Sensitive, category
  `OPEN` with no actions: it only opens the chat. `answersInBanner` is false for it on every
  platform; Allow from an older notification opens the chat instead (`PushResponder`,
  `MacNotifier`); the Live Activity and the Dynamic Island show no Allow for it.
- Unlock and code requests read "Hermes needs a password", without the site when details are
  hidden (`kind: password`).

## 5. Browser

Calls (`BrowserSettings`, `BrowserConnection`, `BrowserPlace` in HermesKit, `BrowserSettingsModel`
in the app):

| Need | Call | Notes |
|---|---|---|
| What's set | `GET /api/config?profile=` | `browser.cloud_provider` (absent until chosen: Hermes then picks a cloud provider it has a key for), `use_real_profile`, `engine`, `auto_local_for_private_urls`, `record_sessions`, `extension_control.enabled`, `security.website_blocklist {enabled, domains}` |
| Change it | `PUT /api/config {config, profile}` | Deep-merged; a list (the blocked domains) replaces the one in config, so the whole list goes. `config.set` has no browser keys |
| A window, the engine | `browser.manage {action: status \| connect \| disconnect \| use, enabled?, profile}` | `status` → `{connected, url, browser_use}`, no network. `connect` launches or attaches a visible Chromium (default `http://127.0.0.1:9222`) and answers `{connected, url, messages}`; 5031 when the address can't be reached. `use {enabled}` writes `browser.backend` (`browser-use` / `off`) |
| A cloud provider | `GET /api/tools/toolsets/browser/config`, `PUT …/env`, `PUT …/provider` | The Apps and Tools key sheet (`ToolsetKeySheet`, [setup.md](setup.md) §4.5); the provider write sets `browser.cloud_provider` |

The page (`browserPage`, `browserPageMore`): "Where Hermes browses", four places, each a
`browserOption` row with its glyph, what it means for the person's logins, tags, and a check on the
one in use. Hermes's own order decides which is in use: an attached window, then a cloud provider,
then the copied profile, else a clean browser (`BrowserPlace.current`).

| Place | Means | Sets |
|---|---|---|
| **A clean browser on Studio Mac** (Default · Free · Not visible) | Starts fresh every time; signs in with the logins in Passwords | `cloud_provider: local`, `use_real_profile: false` (written, so Hermes doesn't pick a cloud provider by itself) |
| **With your logins on Studio Mac** (Your logins · Chrome, Edge or Brave) | A copy of the person's Chrome, Edge or Brave profile, cookies and logins; their own profile is never opened | `cloud_provider: local`, `use_real_profile: true`, after the consent |
| **A window on Studio Mac** (Visible on Studio Mac) | A Chrome window the person can watch on that Mac; what they sign in to there stays | `browser.manage connect`. Hermes keeps it in its process, so it lasts until Hermes restarts; the status says so |
| **In the cloud** (Needs a plan or key) | For sites that block automation | The provider sheet; once a provider is saved, `use_real_profile: false` (Hermes deletes the copy) and a window is let go. With a provider set up already, picking it uses that one at once; while it's in use, the row opens the sheet to change provider. Cancel changes nothing |

Choosing a clean browser or your logins lets go of an attached window first (`disconnect`). A row
being changed shows a `Spinner` in place of its check; the others wait. The footer: "Applies to new
chats. The chats you have open keep the browser they started with." After a change the Now section
says it again.

**The consent** (`browserProfileConsent`), the first time "With your logins" is picked on this
device for this gateway, as a partial sheet: "Stay signed in to your sites.", "Your cookies and
logins are copied into a snapshot on Studio Mac.", "Your own Chrome profile is never opened.",
"Nothing leaves Studio Mac. Turning this off deletes the copy.", and that it needs Chrome, Edge,
Brave or Chromium as the default browser there (Firefox and beta versions are refused). **Not Now**
/ **Use My Profile**. The answer is kept in UserDefaults per gateway (it holds no secret).

**Now:** Using (the place, "In the cloud · Browserbase"), Engine (Browser Use or Built-in tools, a
menu → `browser.manage use`), Status ("Ready", or "Attached to the window at 127.0.0.1:9222 until
Hermes restarts"). The footer, unless it's the window: "Hermes browses out of sight; you'll see
each step in the chat."

**Advanced:** Fast text-only browser (`engine: lightpanda`, else `auto`; "Lightpanda: quicker, but
no screenshots"), Local browser for private addresses (`auto_local_for_private_urls`), Record
browser sessions (`record_sessions`, videos on the gateway), Blocked sites (the count, or Off) →
a page with Block these sites (`enabled`), the domains (remove with ⊖) and Add a site; a site is
kept as Hermes matches it (`BrowserSettings.blockedDomain`: the host, lowercased, without `www.`;
`*.` wildcards as typed). Footer: "Hermes never opens a blocked site, and always refuses addresses
that would expose a key or a cloud server's metadata."

A change that fails says so in an alert, in words; a failed connect adds what Hermes said while it
looked for a browser. Every change reads the page again, so what's shown is the gateway's.

Not built yet: **In this app** (§6) and Clear Browsing Data, which come with the in-app browser.

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

- **The card fill is a generic approval** (command "Fill payment card '…' on …", pattern key
  `mcp_elicitation`); its `vault-payment` surface reaches only plugins' hooks, so the app reads the
  command (and the push notice's surface). A dedicated request kind would be safer.
- **The push plugin's fallback notification** (shown only when the app's extension can't run) still
  carries the approval category, and its Live Activity update carries the request id: the app opens
  the chat for either instead of answering, but the next push plugin version should send `OPEN` and
  no request id for `vault-payment`, as it does for flagged commands.

- **No card or address details in `vault.list`.** The design shows "Visa •• 4242 · expires 08/28"
  and an address's first line; Hermes keeps all of those encrypted, so the rows show the name and
  the site. A gateway field for display-safe card facts (brand, last four, expiry) would allow
  more.
- **`vault.list` has no "last used".** The detail shows Added only.
- **No account or vault in a manager item's id**, so the Mac opens 1Password rather than the item.
- **Hermes's vault has no master password** (its key is a file beside it). Worth a gateway option
  to protect it with the macOS Keychain or a passphrase.

## 10. Mocks and flags

`Tools/mock-hermes/browser.py` answers `browser.manage` and adds the `browser` and
`security.website_blocklist` sections to `GET`/`PUT /api/config`; saving Browserbase's keys in the
cloud sheet sets `cloud_provider: browserbase`. Connect takes about 2 s. `POST /api/mock/browser`
`{"connect": "fails"}` answers like a gateway without Chrome (connected false, Hermes's hint
lines), `{"connect": "unreachable"}` with 5031, `{"older": true}` with -32601, `{"reset": true}`
puts the defaults back. `-HERMES_BROWSER YES` opens Browser (iPhone and iPad with `-HERMES_OPEN
settings`; the Mac opens Settings → Apps & Tools on Browser); `-HERMES_BROWSER consent` shows the
profile consent.

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
