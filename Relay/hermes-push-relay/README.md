# push.hermesapp.dev

A Vercel project in front of the Hermes push relay. Convex's Starter plan has no custom domains, so
this project only proxies the relay's paths (`/health`, `/v1/…`) to the Convex deployment's site URL
(`vercel.json`). Deploy it with `vercel deploy --prod` from this folder.

Each proxied request carries `x-relay-proxy` with the project's `RELAY_PROXY_SECRET` environment
variable, which must equal the Convex deployment's. That header is how the relay knows Vercel wrote
the caller's address into `x-vercel-proxied-for` and `Forwarded` (it overwrites both); without it
every registration shares one rate-limit bucket. `X-Forwarded-For` is no use here: a `routes` proxy
passes the caller's own value through.
