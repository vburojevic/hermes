# Apps and Tools (connectors, MCP servers, plugins, built-in toolsets)

What Hermes on a gateway can reach, and the place to manage it. There are four kinds:

- **Apps:** managed connectors such as GitHub, Gmail, Linear and Slack. They are hosted accounts
  signed in through the browser, via the person's Nous account. One app can have several accounts,
  and each brings tools marked Reads, Writes or Destructive.
- **MCP servers:** MCP servers on the gateway, from the Hermes catalog or added by hand (a command
  or a URL). They use API keys or OAuth.
- **Plugins:** packages from the Hermes catalog (official or community) or a git link. A plugin can
  bring MCP tools, skills, commands and hooks.
- **Built-in:** Hermes's own toolsets (terminal, files, web, browser, vision, image generation,
  memory, helpers, and more).

This doc covers the gateway calls behind Apps and Tools, where the page lives on each platform,
each tab, and the offline and sign-in states. It needs Bot Mode: every call goes over the
backend's JSON-RPC socket, plus two REST routes. When a chat needs a connection mid-turn, the
request cards handle it (`docs/quick-actions.md`: `connectSignIn`, `connectWaiting`,
`connectDone`, `connectCredentials`, `installAsk`); this doc covers managing connections outside a
chat.

The code lives in `Packages/HermesKit/Sources/HermesKit/Connections/` (`ConnectionsClient`,
`ConnectorModels`, `ToolModels`), `App/Model/AppsAndToolsModel.swift` (one per gateway, owned by
`BotWorkspace`), `App/Model/BrowserSignIn.swift` and `App/Views/Connections/`. The mock is
`Tools/mock-hermes/connections.py`; its demo data, switches and debug flags are in
[development.md](development.md).

Design component names: `appLogo`, `appRow*`, `catalogRow`, `accountRow*`, `accountMenu`,
`toolRow*`, `serverRow*`, `pluginRow*`, `capabilityLine`, `toolsetRow`, `kindPicker`; screens
`appsTab`, `appDetail`, `appExpired`, `serversTab`, `serverFailed`, `addServer`, `pluginsTab`,
`pluginDetail`, `pluginUpdate`, `builtInTab`, `ipadAppsTools`, `macSettingsConnections`.

## 1. Data

Hermes names come from the gateway source: `tui_gateway/contracts/connectors.py`,
`connectors_operation.py` and `tools_mcp_plugins.py`. Every call is scoped to the gateway's
Hermes profile (`profile` param) except `reload.mcp`, `tools.list` and `toolsets.list`, which
reject it (their params have no `profile`; unknown keys answer 4000) and act on the gateway's own
profile.

| Need | Call | Notes |
|---|---|---|
| Apps and their state | `connectors.list {owner: {type: "account"}}` | `ConnectorRow`: `connector`, `enabled`, `connected`, `connection_status` (pending / active / failed / expired / revoked / inactive), `status_reason`, `gateway_disabled_tools`. `available: false` → the Nous sign-in state (§7) |
| Catalog to add from | `connectors.catalog` | slug, name, description, category, `logo_url` |
| Connect / reconnect | `connectors.connect {owner, connectors: [slug], reconnect?, alias?, connection_id?}` | Returns an operation with a `connect_url`; the browser opens; the app catches `hermes://connections/done?op=…` and calls `connectors.operation.wake`, then follows `connectors.operation.status` until it settles |
| Accounts | `connectors.accounts {connector?}`, `connectors.accounts.rename {connection_id, alias}`, `connectors.accounts.remove {connection_id}` | `active` marks the one Hermes uses; `disabled` accounts (replaced by a reconnect) are hidden. Alias = the short name ("personal", "work"); `ALIAS_TAKEN` error |
| Tools of an app | `connectors.tools {slug, refresh?}` | name, description, `facet` (read / write / destructive / unclassified) |
| Allow / block tools | `connectors.policy.get`, `connectors.policy.set {change, expected_revision}` | Layers from organization to role to member. The app writes only the member layer: `change` is the full list of an app's tools the member blocks. Send the member layer's revision; on `POLICY_CONFLICT`, re-read and retry once |
| MCP servers | `mcp.servers.list` joined with `mcp.servers.status` | Config with secrets shown as env-key names; status connected / connecting / failed / lazy / disabled; tool count; `source` config or plugin |
| Add an MCP server | `mcp.catalog`; `mcp.servers.add {name, preset?, config?, bearer_token?}`; `mcp.servers.set_api_key {name, value, env_var?}` | Presets list the env keys they `require`. `set_api_key` answers with the env name only |
| Test / sign in / remove | `mcp.servers.test {name}`, `mcp.servers.oauth.start/poll/cancel {name, session_id}`, `mcp.servers.remove {name}` | Test connects, lists tools, disconnects. OAuth returns to the gateway, so the app polls every second |
| MCP server on / off | `profiles.configure {enabled_mcp_servers}` | Replace semantics: every server that should be on. Then `reload.mcp` |
| Built-in toolsets on / off | `tools.configure {action: enable / disable, names}` | `tools.configure` can't turn a whole MCP server off; it only excludes single `server:tool` targets |
| Apply MCP changes to open chats | `reload.mcp {confirm: true}` | Invalidates the prompt cache; sent after add, remove, key change, sign-in, on/off and plugin install or remove. `confirm` skips Hermes's "are you sure" |
| Plugins | `plugins.manage {action: list / onboarding / toggle / install / update / remove / settings}`, `plugins.catalog.lookup {name}` | §5 |
| What a plugin adds | `tools.list` (each toolset's tools), `skills.manage {action: list}` | A plugin's tools are in the toolset named after its key (or its MCP servers' toolsets); its skills are named `<plugin>:<skill>` |
| Built-in toolsets | `toolsets.list` | Names, descriptions, tool counts, enabled |
| Plugin secrets | `PUT /api/env {key, value, profile}` (REST) | Write-only |
| Nous sign-in | `POST /api/providers/oauth/nous/start`, `GET /api/providers/oauth/nous/poll/<session_id>` (REST) | Device code: the browser opens the verification URL, the app polls at the given interval |

Secrets go one way: keys and tokens are written once and never read back, and the app never
keeps them.

### 1.1 What the real gateway does

- There is no "set active account" call. Hermes uses the account signed in to last (`active`).
  "Use This Account" is therefore a reconnect of that account (`reconnect: true` with its
  `connection_id`), the gateway's own documented way to switch.
- `mcp.servers.status` carries no failure reason; a failed server says why only when tested, so
  its detail runs `mcp.servers.test` when it opens.
- `mcp.catalog` may send a preset's transport as a Python repr (`TransportSpec(type='http', …)`);
  `McpPreset` reads both forms.
- `toolsets.list` returns every toolset the gateway knows (platform bundles, MCP servers, plugins)
  with no built-in flag. The app treats the configurable keys of `hermes_cli/tools_config.py` as
  built-in (`BuiltInToolsetInfo`).
- There is no plugin catalog list call: `plugins.manage {action: onboarding}` gives the curated
  plugins this OS runs, and `plugins.catalog.lookup` resolves one name.

## 2. Where it lives

- **iPhone and iPad:** Settings → "Hermes on <gateway>" → **Apps and Tools**. The row's subtitle
  is a count ("4 apps · 4 MCP servers"), plus "1 needs you" when an app's sign-in expired or an
  MCP server that's on couldn't connect. The page pushes inside the Settings sheet and has a
  segmented picker: Apps, MCP, Plugins, Built-in. The tab is "MCP"; headings, rows and buttons say
  "MCP server", never "Servers" alone (gateways are servers too). A line at the top says which
  gateway it applies to. Pull to refresh.
- **Mac:** Settings window → **Apps & Tools** tab: the list on the left (Apps, MCP Servers,
  Plugins, Built-in, and "Add App, MCP Server or Plugin…"), the selected item on the right, as a
  macOS grouped form. Orange dots mark items that need attention. Same data and calls as iPhone.
- **Skills:** the Skills page's "Tools and Apps" row ("7 built-in tools on · 4 apps · 4 MCP
  servers") opens the same page.
- **A plugin link:** `hermesapp://plugin/install?catalog=<name>` opens Settings → Apps and Tools
  and asks before installing (§5).
- Not built yet: a "Manage…" link from a chat's request card (when Hermes says an app is missing)
  to this page.

## 3. Apps

- **List (`appsTab`):** "Connected · N", then "Add an App" (catalog rows with Connect, then "Browse
  All Apps…", searchable by name and grouped by category).
  - A connected row shows the account names and the tool count.
  - Expired, revoked or failed apps get an orange "Sign-in expired" tag.
  - Footer: "Signed in through your Nous account. Your passwords stay with each app; Hermes only
    gets the tools you allow."
- **Detail (`appDetail`):**
  - Logo, name and description.
  - **Accounts:** each with its alias or label and its state (Active, Expired, Failed, Pending,
    Inactive); with several, the one Hermes uses says so. "Add Another Account" asks for an alias
    (lower case letters, digits and dashes, up to 32), then calls `connectors.connect` with it.
  - **Tools:** "Tools · 31 of 38 allowed", each with its kind tag and a switch. Show 5, then "Show
    All 38 Tools". Footer: "Hermes still asks before anything that writes, as set in Chat
    Permissions."
  - **Destructive tools start off:** after a new app connects, and only when the member layer has
    no rule for it yet, the app blocks its destructive tools in the member policy.
  - A tool turned off by an organization or role layer, or by the gateway's own config
    (`gateway_disabled_tools`), shows locked: "Turned off by your organization".
  - **Disconnect <App>:** destructive, confirmed by an alert ("Hermes loses its <App> tools on
    <gateway>. Your <App> account stays as it is."). It removes every account of the app.
- **Account … (`accountMenu`):** Use This Account (checked on the active one; choosing another
  explains that Hermes uses the account signed in to last, then signs in to it again), Rename…
  (alias), Sign In Again (`reconnect: true`), Remove Account….
- **Needs attention (`appExpired`):** a warning card saying what stopped and when ("On 12 October.
  Hermes can't use GitHub's 38 tools until you sign in again; chats that need it will ask."), with
  Sign In Again (ink). Then the normal browser flow.
- **Browser sign-in** (`BrowserSignIn`): an `ASWebAuthenticationSession` that keeps the person's
  existing browser logins and catches the `hermes://connections/done` return link without the app
  registering that scheme. If the person closes the browser early, the app still follows the
  operation for a few seconds, in case it finished.
- Logos: `logo_url` on a white tile. Until it loads, or if there is none, the first letter
  (`appLogo`). Logos are never tinted.

## 4. MCP servers

- **List (`serversTab`):** "MCP Servers · N", each server with a status dot, its name in mono, a
  line ("Connected · command · 14 tools", "Starts when needed · URL", "Couldn't connect · tap to
  fix", "Off · command") and a switch. Then "Add MCP Server…". The footer says servers run on the
  gateway, and that turning one off removes its tools from new chats while open chats reload theirs.
  Plugin-provided servers say "plugin".
- **Detail (`serverFailed` when it couldn't connect):**
  - A red card "Couldn't connect" with the error in plain words and the raw reason in mono (from a
    test run when the detail opens), then Update API Key / Test Again, or Test Again / Sign In for
    an OAuth server.
  - Setup rows: how it connects (Command or URL), the command or address in mono, the API key by
    env name only ("BRAVE_API_KEY ••••"), the OAuth sign-in state, and On.
  - Remove MCP Server, confirmed. A plugin's server can't be removed here: "This MCP server comes
    with the <plugin> plugin. Turn it off here, or remove the plugin."
- **Add (`addServer`, "Add MCP Server", a full-height sheet):**
  - Search the catalog.
  - Suggested presets with what they need ("needs BRAVE_API_KEY", or "no key") and Add.
  - Custom MCP Server: Command / URL, Name, the command or URL in mono, a key name, then one secure
    field per env key, then the test result row ("Connected · 22 tools · Tested on Studio Mac just
    now").
  - OAuth servers: Sign In instead of a key field (`oauth.start`, open `auth_url`, poll; the browser
    closes when Hermes has the tokens).
  - Testing adds the server first (`mcp.servers.add`), writes its keys, then tests it. **Add** (✓)
    is enabled only after a passing test; it closes the sheet at once and sends `reload.mcp`, and
    the list reads the new server. Cancel after a test
    removes the server again.
- Secrets are written once (`set_api_key`) and never read back. The field starts empty, shows dots
  and the env name, and says the key is stored in the gateway's `.env`. Saving a new key tests the
  server again and reloads open chats.

## 5. Plugins

The Plugins tab is the plugin hub ([plugins.md](plugins.md) §9): Suggested (the app's own plugins
and Hermes's curated ones), Updates, Installed, New in the Catalog and Browse All, Hidden
Suggestions. Every plugin that isn't installed opens one review, and Install there is the consent.
What stays here:

- **Installed rows (`pluginRow*`):** name and a tier tag (Official with a seal, Community with
  people, For This App), version and what it adds, a switch (`toggle {key, enable}`), and a line
  for what needs the person: "Needs 2 keys · tap to add them" (secret fields without a value),
  Hermes's own sentence for a problem in orange ("DaVinci Resolve isn't running on Studio Mac":
  `app_not_running`, `missing_app`, `version_too_old`…), or "Pulled from the catalog · tap for why"
  in red with the switch locked. Then "Install from a Git Link…" (`install {repo, ref, enable:
  true}`) and "Built into Hermes · N" for bundled plugins, which can be turned off but not removed.
- **Detail (`pluginDetail`)** for an installed catalog or git plugin:
  - What it adds: tool and skill names as tags. Its MCP tools and skills work in open chats from
    the next turn (`activation.live_now`); Python tools and prompt changes from the next chat
    (`deferred`). The page says which.
  - Settings, built from the manifest schema (`settings_schema`: string / number / boolean / enum /
    secret / json). Secret fields show only "Set" or "Not set", with the env name. Non-secret
    values save with `settings {key, values}`; secrets go to `PUT /api/env`.
  - Source (repo, pinned version, how it was installed), Update to vN when one is available, then
    Remove Plugin. Only user installs can be removed.
  - Pulled from the catalog: why and when (the feed's `removed` list), Remove, and no Turn On.
- **The app's own plugins** open their per-Bot page instead ([plugins.md](plugins.md) §2.1).
- **Updating (`pluginUpdate`):** `update {name}`. If the result has `consent_required`, the card
  "This update asks for more access" lists one `capabilityLine` per `delta_lines` entry, then Keep
  vX / Allow and Update (retried with `accept_capabilities: true`). Nothing changes until the
  person allows it. The app's own plugins use the same card when a new pin adds access.
- After a toggle or update, a sheet shows what Hermes said: Ready (works now, or from the next
  chat), It still needs (`missing_env`, as fields to fill), Warnings, Known issues, and when
  `restart_required` is true, "Restart the gateway to finish" with `hermes gateway restart`.
- `hermesapp://plugin/install?catalog=<name>` links resolve with `plugins.catalog.lookup` and open
  that plugin's review; nothing installs from a link. A name the catalog doesn't know says so.
- **The Mac:** Suggested heads the Plugins list (`macPluginsSuggested`); a suggestion's review opens
  in the pane with Install on <gateway> as its default button (`macPluginReview`). Add… offers
  Browse the Plugin Catalog… and Install from a Git Link….
- **The Settings row** reads "4 apps · 4 MCP servers · 2 suggested": plain text, never a badge.

## 6. Built-in

- `builtInTab`: "Built-in · 8", one row per main toolset (Terminal, Files, Web search, Browser,
  Vision, Image generation, Memory, Helpers): an ink tile with its symbol, name, what it allows on
  this gateway, tool count, and a switch. The other configurable toolsets sit under "More · N". The
  footer says changes apply to new chats and open chats reload their tools.
- Turning off Terminal or Files asks first: "Hermes won't be able to run commands on Studio Mac." /
  "…edit files on Studio Mac."

## 6a. iPad

Apps and Tools stays inside the Settings sheet. When the sheet is at least 900 pt wide (iPad
landscape, `ipadAppsTools`) it shows two columns: the tabs and list on the left (440 pt), and the
selected app, MCP server or plugin on the right (accounts, tools with Reads / Writes / Destructive),
the tab's first item until one is picked. Narrower, it falls back to the iPhone push navigation.

## 7. States

- **Gateway offline:** the page shows the last known lists, dimmed, with "<gateway> is offline.
  Showing what it had last. Changes wait until it's back.", and every switch is disabled.
- **No Bot Mode:** "Turn on Bot Mode for <gateway>. Apps and Tools are managed over Bot Mode's
  connection."
- **`connectors.list` answers `available: false`, or a `NEEDS_NOUS_AUTH` error:** the Apps tab
  shows "Sign in to Nous to connect apps" with one ink button, Sign In to Nous (§1). MCP, Plugins
  and Built-in still work.
- **Loading:** the first read shows `SkeletonRows` where the lists will be (on the Mac, in the
  sidebar's Apps and MCP Servers), never empty sections counting 0.
- **Changes** ([chat.md](chat.md) §4a, `PendingChanges`): a switch (a tool, an MCP server, a
  plugin, a built-in toolset) moves at once and stays there while the gateway takes it; a rename
  shows the new name; a removed account, a disconnected app, a removed server or plugin leaves the
  list as its confirmation closes and its page goes back. A plugin setting keeps its new value. A
  toolset's Add a Key and Add's ✓ close at once. Then the list is read again. A refusal puts the
  change back and says what and why ("Couldn't turn off Linear. … It's back as it was."). Only
  the person's own waits show a `Spinner` or words: sign-ins ("Signing In…"), Connect, Test Again
  and Test Connection, installs and updates.
- **Errors** map from `ConnectorErrorReason` (`data.reason` on the gateway error) to one line each
  (`ORG_REQUIRED`: "Apps need a Nous organization. Ask your admin to add you.", `FORBIDDEN_SCOPE`,
  `ALIAS_TAKEN`: "Another account already has that name.", `POLICY_CONFLICT`…). The raw code is
  never shown alone.

## 8. Acceptance checks

- Every connected app, account, MCP server, plugin and toolset on the gateway appears with the
  state the gateway reports, and updates after connect, reconnect, test, remove and toggle without
  a manual refresh. On a slow gateway (`--starve 5-30`) a toggle, rename or removal shows at once,
  with no spinner and no page or sheet held open.
- A new app's destructive tools are off after it connects.
- Blocking a tool here stops Hermes using it in the next turn. This needs a gateway with Nous
  connectors; check it in a chat.
- No secret value ever appears in the UI, logs or payloads after saving.
- Expired sign-ins surface in the Settings row, the list and the detail.
- Mac and iPhone show the same data and make the same calls.
- Light, dark and Increase Contrast render correctly.

## 9. Setup

Apps and Tools need Bot Mode; without it the page says so with Link Bot Mode ([setup.md](setup.md)
§4.5). A built-in toolset that's on but has no key reads "Needs a key on <gateway>", with Add a
Key… under it (its providers' key fields, saved to the gateway's .env) and `hermes tools` in the
section's footer.
