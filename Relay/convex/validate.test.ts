import { describe, expect, test } from "vitest";
import { isEnvelope, validatePush } from "./validate";

const envelope = { v: 1, epk: btoa("e".repeat(32)), box: btoa("b".repeat(40)) };
const token = "ab".repeat(32);
const alert = {
  token, environment: "development", topic: "co.caffeinatedcode.hermes.dev", push_type: "alert", priority: 10,
  collapse_id: "req-1", expiration: 1_800_000_000,
  payload: {
    aps: { alert: { title: "Hermes needs your OK", body: "Open Hermes to see it." }, "mutable-content": 1,
           category: "APPROVAL", "interruption-level": "time-sensitive", "relevance-score": 1, sound: "default" },
    hermes: envelope,
  },
};

describe("validatePush", () => {
  test("accepts a sealed alert, a withdraw and a Live Activity update", () => {
    expect(validatePush(alert).ok).toBe(true);
    expect(validatePush({ token, environment: "production", topic: "co.caffeinatedcode.hermes", push_type: "background",
      priority: 5, payload: { aps: { "content-available": 1 }, hermes: envelope } }).ok).toBe(true);
    expect(validatePush({ token, environment: "production", topic: "co.caffeinatedcode.hermes.push-type.liveactivity",
      push_type: "liveactivity", priority: 10, payload: { aps: { timestamp: 1, event: "update",
        "content-state": { phase: "needsYou", sealed: envelope }, alert: { title: "Hermes needs your OK",
        body: "Open Hermes to answer." }, sound: "default" } } }).ok).toBe(true);
  });

  test("refuses readable content", () => {
    const leak = structuredClone(alert);
    leak.payload.aps.alert.title = "Run rm -rf ./build on Home Server?";
    expect(validatePush(leak)).toEqual({ ok: false, error: "aps.alert.title must be a kind-only title" });
    const subtitle = structuredClone(alert) as any;
    subtitle.payload.aps.alert.subtitle = "Disk cleanup";
    expect(validatePush(subtitle).ok).toBe(false);
    const plain = structuredClone(alert) as any;
    plain.payload.hermes = { v: 1, epk: "x", box: "y", text: "hello" };
    expect(validatePush(plain).ok).toBe(false);
    const extra = structuredClone(alert) as any;
    extra.payload.note = "secret";
    expect(validatePush(extra).ok).toBe(false);
    const live = { token, environment: "production", topic: "co.caffeinatedcode.hermes.push-type.liveactivity",
      push_type: "liveactivity", payload: { aps: { timestamp: 1, event: "update",
        "content-state": { phase: "working", step: "Running rm -rf", sealed: envelope } } } };
    expect(validatePush(live).ok).toBe(false);
  });

  test("refuses other apps, bad tokens, oversized payloads", () => {
    expect(validatePush({ ...alert, topic: "com.example.app" }).ok).toBe(false);
    expect(validatePush({ ...alert, topic: "co.caffeinatedcode.hermes.push-type.liveactivity" }).ok).toBe(false);
    expect(validatePush({ ...alert, token: "zz" }).ok).toBe(false);
    expect(validatePush({ ...alert, collapse_id: "x".repeat(65) }).ok).toBe(false);
    const big = structuredClone(alert) as any;
    big.payload.hermes.box = btoa("b".repeat(4000));
    expect(validatePush(big)).toMatchObject({ ok: false });
    expect(validatePush({ ...alert, push_type: "background", priority: 10 }).ok).toBe(false);
    expect(validatePush({ ...alert, environment: "staging" }).ok).toBe(false);
  });

  test("envelopes", () => {
    expect(isEnvelope(envelope)).toBe(true);
    expect(isEnvelope({ ...envelope, v: 2 })).toBe(false);
    expect(isEnvelope({ v: 1, epk: btoa("short"), box: envelope.box })).toBe(false);
  });
});
