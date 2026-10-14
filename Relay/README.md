# Hermes push relay

One self-service relay between every user's Hermes gateway (the `hermes-app-push` plugin) and Apple's
push service. It holds the team APNs key, takes no content, and needs no accounts: a gateway registers
itself on first use and gets a secret. Users never set anything up here.

```
gateway plugin ──HTTPS──▶ push.hermesapp.dev (Vercel rewrite) ──▶ Convex HTTP action ──▶ Node action ──HTTP/2──▶ APNs
```

| | |
|---|---|
| Address | `https://push.hermesapp.dev` (Vercel project `hermes-push-relay`, team "Projects"; `hermes-push-relay/vercel.json`) |
| Convex | team `vedran-burojevic`, project `hermes-push`; prod `acrobatic-goat-299`, dev `outstanding-pony-986` (eu-west-1) |
| Secrets | Infisical prod `/hermes/convex`: `APNS_KEY_P8`, `APNS_KEY_ID`, `APNS_TEAM_ID` (mirrors of `/shared/apple`, team key `L2U9BXR47D`), `ALLOWED_TOPICS`, `RELAY_SALT` |

Convex's Starter plan has no custom domains, so the domain is a Vercel rewrite of every path to
`https://acrobatic-goat-299.eu-west-1.convex.site`.

## API

- `POST /v1/installations {client, name}` → `201 {installation_id, secret}`. The secret is stored only as
  a SHA-256 hash. 20 registrations an hour per address (hashed with `RELAY_SALT`).
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
CONVEX_AGENT_MODE=anonymous npx convex dev      # local backend, no account
scripts/sync-convex-env.sh <dev|prod> --apply   # Infisical /hermes/convex → Convex env
python3 scripts/deploy-prod.py .                # `npx convex deploy` needs a TTY (see caffeinated-convex)
```

End to end with a fake APNs (plain HTTP/2): run `node scripts/fake-apns.mjs 8443 /tmp/fake-apns.jsonl`, set
`APNS_HOST_OVERRIDE=http://127.0.0.1:8443` plus a throwaway P-256 key on the local deployment, then run
`Tools/hermes-app-push/tests/test_relay_e2e.py` (see its docstring).

Never list env values: `npx convex env list` prints multi-line PEMs, and filtering with `cut` leaks them.
