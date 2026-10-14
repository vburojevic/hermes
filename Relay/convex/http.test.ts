import { convexTest } from "convex-test";
import { describe, expect, test } from "vitest";
import schema from "./schema";
import { modules } from "./test.setup";
import { LIMITS } from "./gateways";

const envelope = { v: 1, epk: btoa("e".repeat(32)), box: btoa("b".repeat(40)) };
const push = {
  token: "cd".repeat(32), environment: "development", topic: "co.caffeinatedcode.hermes.dev", push_type: "background",
  priority: 5, payload: { aps: { "content-available": 1 }, hermes: envelope },
};

async function register(t: ReturnType<typeof convexTest>, ip = "203.0.113.7") {
  const response = await t.fetch("/v1/installations", { method: "POST", body: JSON.stringify({ client: "test" }),
                                                          headers: { "x-forwarded-for": ip } });
  return { status: response.status, body: (await response.json()) as { installation_id: string; secret: string } };
}

describe("relay HTTP", () => {
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
