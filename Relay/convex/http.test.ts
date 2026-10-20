import { convexTest } from "convex-test";
import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";
import schema from "./schema";
import { modules } from "./test.setup";
import { LIMITS } from "./gateways";

const envelope = { v: 1, epk: btoa("e".repeat(32)), box: btoa("b".repeat(40)) };
const push = {
  token: "cd".repeat(32), environment: "development", topic: "co.caffeinatedcode.hermes.dev", push_type: "background",
  priority: 5, payload: { aps: { "content-available": 1 }, hermes: envelope },
};

const proxySecret = "test-proxy-secret";

/**
 * A registration through the Vercel proxy, which adds `x-relay-proxy` (`proxy`) and writes the
 * caller's address into `x-vercel-proxied-for`, or (`proxy` null) straight to Convex. `claimed` is the
 * X-Forwarded-For the caller writes itself, which reaches the relay either way.
 */
async function register(t: ReturnType<typeof convexTest>, ip = "203.0.113.7", proxy: string | null = proxySecret,
                        claimed = "192.0.2.1") {
  const headers: Record<string, string> = { "x-forwarded-for": claimed };
  if (proxy !== null) Object.assign(headers, { "x-relay-proxy": proxy, "x-vercel-proxied-for": ip });
  const response = await t.fetch("/v1/installations", { method: "POST", body: JSON.stringify({ client: "test" }), headers });
  return { status: response.status, body: (await response.json()) as { installation_id: string; secret: string } };
}

describe("relay HTTP", () => {
  beforeEach(() => vi.stubEnv("RELAY_PROXY_SECRET", proxySecret));
  afterEach(() => vi.unstubAllEnvs());

  test("health", async () => {
    const t = convexTest(schema, modules);
    expect((await t.fetch("/health")).status).toBe(200);
  });

  test("registration issues an id and a secret, stored only as a hash", async () => {
    const t = convexTest(schema, modules);
    const { status, body } = await register(t);
    expect(status).toBe(201);
    expect(body.installation_id).toMatch(/^inst_/);
    expect(body.secret.length).toBeGreaterThan(30);
    const rows = await t.run((ctx) => ctx.db.query("installations").collect());
    expect(rows).toHaveLength(1);
    expect(JSON.stringify(rows)).not.toContain(body.secret);
  });

  test("registrations are limited per address", async () => {
    const t = convexTest(schema, modules);
    for (let i = 0; i < LIMITS.registrationsPerHourPerIp; i++) expect((await register(t, "198.51.100.1")).status).toBe(201);
    expect((await register(t, "198.51.100.1")).status).toBe(429);
    expect((await register(t, "198.51.100.2")).status).toBe(201);
  });

  test("calls that skip the proxy can't pick their address", async () => {
    const t = convexTest(schema, modules);
    // Straight to the Convex URL, or with a guessed proxy header: every address header is the
    // caller's own words, so all of these share one bucket whatever they claim.
    for (let i = 0; i < LIMITS.registrationsPerHourPerIp; i++) {
      expect((await register(t, `192.0.2.${i}`, i % 2 ? null : "guess", `192.0.2.${i}`)).status).toBe(201);
    }
    expect((await register(t, "192.0.2.200", null, "192.0.2.200")).status).toBe(429);
    expect((await register(t, "192.0.2.201", "", "192.0.2.201")).status).toBe(429);
    // Through the proxy, the address Vercel wrote still counts on its own.
    expect((await register(t, "192.0.2.200")).status).toBe(201);
  });

  test("through the proxy, a caller's own X-Forwarded-For changes nothing", async () => {
    const t = convexTest(schema, modules);
    for (let i = 0; i < LIMITS.registrationsPerHourPerIp; i++) {
      expect((await register(t, "198.51.100.7", proxySecret, `203.0.113.${i}`)).status).toBe(201);
    }
    expect((await register(t, "198.51.100.7", proxySecret, "203.0.113.250")).status).toBe(429);
  });

  test("Forwarded stands in when Vercel's own header is missing", async () => {
    const t = convexTest(schema, modules);
    const send = (forwarded: string) => t.fetch("/v1/installations", { method: "POST", body: "{}",
      headers: { "x-relay-proxy": proxySecret, forwarded: `${forwarded};host=example.com;proto=https` } });
    for (let i = 0; i < LIMITS.registrationsPerHourPerIp; i++) expect((await send('for="[2001:db8::1]"')).status).toBe(201);
    expect((await send('for="[2001:db8::1]"')).status).toBe(429);
    expect((await send("for=198.51.100.8")).status).toBe(201);
  });

  test("a relay without a proxy secret trusts no address", async () => {
    vi.stubEnv("RELAY_PROXY_SECRET", "");
    const t = convexTest(schema, modules);
    for (let i = 0; i < LIMITS.registrationsPerHourPerIp; i++) expect((await register(t, `198.51.100.${i}`, "")).status).toBe(201);
    expect((await register(t, "198.51.100.250", "")).status).toBe(429);
  });

  test("pushes need the installation's secret and a valid body", async () => {
    const t = convexTest(schema, modules);
    const { body } = await register(t);
    const send = (headers: Record<string, string>, payload: unknown = push) =>
      t.fetch("/v1/push", { method: "POST", body: JSON.stringify(payload), headers });
    expect((await send({})).status).toBe(401);
    expect((await send({ "x-hermes-installation": body.installation_id, authorization: "Bearer wrong" })).status).toBe(401);
    const auth = { "x-hermes-installation": body.installation_id, authorization: `Bearer ${body.secret}` };
    const leak = { ...push, payload: { aps: { alert: { title: "rm -rf /", body: "x" } }, hermes: envelope }, push_type: "alert", priority: 10 };
    const refused = await send(auth, leak);
    expect(refused.status).toBe(400);
    // A valid push reaches the APNs step (which can't run in this test VM: it reports 502 here).
    expect([200, 502]).toContain((await send(auth)).status);
  });

  test("pushes are limited per gateway per minute", async () => {
    const t = convexTest(schema, modules);
    const { body } = await register(t);
    const charge = () => t.mutation(internal.gateways.charge, { installationId: body.installation_id });
    for (let i = 0; i < LIMITS.pushesPerMinute; i++) expect(await charge()).toBe("ok");
    expect(await charge()).toBe("minute");
    expect(await t.mutation(internal.gateways.charge, { installationId: "inst_nobody" })).toBe("unknown");
  });
});

import { internal } from "./_generated/api";
