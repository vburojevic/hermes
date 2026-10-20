import { httpRouter } from "convex/server";
import { internal } from "./_generated/api";
import { httpAction } from "./_generated/server";
import { DEFAULT_TOPICS, validatePush } from "./validate";

// The Hermes push relay. Gateways register themselves (no accounts), then send sealed pushes; the
// relay checks them, rate-limits per gateway and forwards to APNs. It keeps no content and logs none.

const http = httpRouter();

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

const hex = (bytes: ArrayBuffer) => [...new Uint8Array(bytes)].map((b) => b.toString(16).padStart(2, "0")).join("");

async function sha256(text: string): Promise<string> {
  return hex(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text)));
}

function randomToken(bytes: number): string {
  const data = crypto.getRandomValues(new Uint8Array(bytes));
  return btoa(String.fromCharCode(...data)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** Constant-time comparison of two hex digests. */
function same(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

function allowedTopics(): string[] {
  const configured = (process.env.ALLOWED_TOPICS ?? "").split(",").map((t) => t.trim()).filter(Boolean);
  return configured.length ? configured : DEFAULT_TOPICS;
}

/**
 * Whose address a registration counts against. Only the Vercel proxy in front of the relay
 * (`hermes-push-relay/vercel.json`) can say: it adds `x-relay-proxy` carrying RELAY_PROXY_SECRET and
 * writes the visitor's address into `x-vercel-proxied-for` and `Forwarded`, over whatever the caller
 * sent. Not into X-Forwarded-For: a `routes` proxy passes the caller's own through. A call straight
 * to the Convex site URL writes every header itself, so all such calls share one bucket.
 */
async function callerAddress(request: Request): Promise<string> {
  const expected = process.env.RELAY_PROXY_SECRET ?? "";
  const vouched = request.headers.get("x-relay-proxy") ?? "";
  if (!expected || !vouched || !same(await sha256(vouched), await sha256(expected))) return "unproxied";
  const proxied = request.headers.get("x-vercel-proxied-for")?.split(",")[0]?.trim();
  const forwarded = /(?:^|[;,\s])for="?\[?([^";,\]\s]+)/i.exec(request.headers.get("forwarded") ?? "")?.[1];
  return proxied || forwarded || "unproxied";
}

async function readJson(request: Request): Promise<unknown> {
  const text = await request.text();
  if (text.length > 8192) throw new Error("too large");
  return JSON.parse(text);
}

http.route({
  path: "/health",
  method: "GET",
  handler: httpAction(async () => json(200, { ok: true, service: "hermes-push-relay" })),
});

http.route({
  path: "/v1/installations",
  method: "POST",
  handler: httpAction(async (ctx, request) => {
    let body: Record<string, unknown> = {};
    try {
      body = ((await readJson(request)) as Record<string, unknown>) ?? {};
    } catch {
      body = {};
    }
    const ipHash = await sha256(`${process.env.RELAY_SALT ?? "hermes-push"}:${await callerAddress(request)}`);
    const installationId = `inst_${randomToken(16)}`;
    const secret = randomToken(32);
    const registered = await ctx.runMutation(internal.gateways.register, {
      installationId,
      secretHash: await sha256(secret),
      client: String(body.client ?? "unknown"),
      ipHash,
    });
    if (!registered.ok) return json(429, { error: "too many registrations from this address; try again later" });
    return json(201, { installation_id: installationId, secret });
  }),
});

http.route({
  path: "/v1/push",
  method: "POST",
  handler: httpAction(async (ctx, request) => {
    const installationId = request.headers.get("x-hermes-installation") ?? "";
    const secret = (request.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
    if (!installationId || !secret) return json(401, { error: "missing credentials" });
    const installation = await ctx.runQuery(internal.gateways.lookup, { installationId });
    if (!installation || installation.disabled || !same(installation.secretHash, await sha256(secret)))
      return json(401, { error: "unknown installation" });

    let body: unknown;
    try {
      body = await readJson(request);
    } catch {
      return json(400, { error: "body must be JSON of at most 8 KB" });
    }
    const checked = validatePush(body, allowedTopics());
    if (!checked.ok) return json(400, { error: checked.error });

    const charge = await ctx.runMutation(internal.gateways.charge, { installationId });
    if (charge === "unknown") return json(401, { error: "unknown installation" });
    if (charge !== "ok") {
      return new Response(JSON.stringify({ error: `rate limit (${charge})` }), {
        status: 429,
        headers: { "content-type": "application/json", "retry-after": charge === "minute" ? "60" : "3600" },
      });
    }
    try {
      const result = await ctx.runAction(internal.apns.send, checked.push);
      return json(200, result);
    } catch (error) {
      console.log(`apns send failed: ${error instanceof Error ? error.message : "unknown"}`);
      return json(502, { error: "couldn't reach APNs" });
    }
  }),
});

export default http;
