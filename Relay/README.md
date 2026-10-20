# Hermes push relay

One relay between every person's Hermes gateway (the `hermes-app-push` plugin) and Apple's push
service. It holds the APNs key, takes no content and needs no accounts: a gateway registers itself on
first use and gets a secret. Nobody sets anything up here; the official relay at
`https://push.hermesapp.dev` is run by Caffeinated Code for the App Store builds.

```
gateway plugin ──HTTPS──▶ push.hermesapp.dev ──▶ Convex HTTP action ──▶ Node action ──HTTP/2──▶ APNs
```

It's a [Convex](https://convex.dev) app (`convex/`). `hermes-push-relay/` is a Vercel project that
proxies the relay's paths to the Convex deployment's site URL, to give it a custom domain.

## Configuration

The deployment's environment holds everything secret; none of it is in this repository.

| Variable | What it is |
|---|---|
| `APNS_KEY_P8`, `APNS_KEY_ID`, `APNS_TEAM_ID` | The team's APNs authentication key |
| `ALLOWED_TOPICS` | The bundle ids it pushes to (the app's, and `.push-type.liveactivity` for Live Activities) |
| `RELAY_SALT` | Salt for hashing callers' addresses in the rate limit |
| `RELAY_PROXY_SECRET` | A random value shared with the Vercel project (the same variable there). Vercel sends it as `x-relay-proxy`, and only then does the relay trust the address Vercel wrote (`x-vercel-proxied-for`, else `Forwarded`) |

## API

- `POST /v1/installations {client, name}` → `201 {installation_id, secret}`. The secret is stored only as
  a SHA-256 hash. 20 registrations an hour per address (hashed with `RELAY_SALT`). The address is
  the one Vercel wrote into `x-vercel-proxied-for` (else `Forwarded`), trusted only with the matching
  `x-relay-proxy`; a caller's own `X-Forwarded-For` passes through Vercel, so it never counts. Calls
  straight to the Convex site URL write every header themselves, so they all share one bucket, as
  does every call to a relay without `RELAY_PROXY_SECRET`.
- `POST /v1/push` with `X-Hermes-Installation` and `Authorization: Bearer <secret>` →
  `200 {status, reason?, apns_id?}` (APNs's answer), `400` invalid, `401` unknown, `429` limited, `502` APNs unreachable.
- `GET /health`.

## What it refuses (so no content can pass)

- Topics other than `co.caffeinatedcode.hermes` and `co.caffeinatedcode.hermes.dev` (+ `.push-type.liveactivity`).
- Alerts whose title isn't one of the kind-only titles ("Hermes needs your OK", …) or body isn't
  "Open Hermes to see it." / "Open Hermes to answer.", any `aps` field it doesn't forward, and any
  payload without a sealed `hermes` envelope `{v: 1, epk, box}`.
- Live Activity states other than `{phase, sealed}`; background pushes other than `{content-available: 1}`.
- Payloads over 4 KB.

Limits per gateway: 120 pushes a minute, 5,000 a day. Logs say only push type, environment and APNs status.

## Work on it

```sh
cd Relay
npm ci
npx vitest run                                  # validator + HTTP tests (convex-test)
CONVEX_AGENT_MODE=anonymous npx convex dev      # a local backend, no account needed
```

End to end with a fake APNs (plain HTTP/2): run `node scripts/fake-apns.mjs 8443 /tmp/fake-apns.jsonl`, set
`APNS_HOST_OVERRIDE=http://127.0.0.1:8443` plus a throwaway P-256 key on the local deployment, then run
`Tools/hermes-app-push/tests/test_relay_e2e.py` (see its docstring).

Never list environment values: `npx convex env list` prints multi-line PEMs, and filtering its
output with `cut` leaks them.

Maintainers deploy the official relay with `scripts/sync-convex-env.sh` (secrets from the studio's
secret store into the deployment's environment) and `scripts/deploy-prod.py` (`npx convex deploy`
needs a terminal). `RELAY_PROXY_SECRET` has to be on both sides before the Convex code that reads it
goes out: set it in the Vercel project and deploy that first (the old relay ignores the header), then
sync the Convex environment and deploy the relay. Deployed the other way round, every registration
shares one bucket until the proxy catches up.
