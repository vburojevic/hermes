// What the relay accepts. The relay must never carry readable content: every alert is one of the
// kind-only titles below, everything else rides in the sealed `hermes` envelope (or the sealed Live
// Activity state), and only the Hermes app's topics are allowed. Pure functions, unit-tested.

export const ALERT_TITLES = new Set([
  "Hermes needs your OK",
  "Hermes has a question",
  "Hermes needs a password",
  "Hermes replied",
  "A scheduled task finished",
  "A scheduled task failed",
  "New message",
  "Background work finished",
  "Push notifications are on",
  // "Save to memory?" (docs/memory.md)
  "Hermes wants to remember something",
  // The Board's cards (docs/board.md §5): never "task", which is a scheduled job in the app.
  "A card needs you",
  "A card is ready for review",
  "A card stopped",
  "A card is done",
  // What Hermes Learned (docs/learned.md): a tidy that changed something.
  "Hermes tidied its skills",
]);
export const ALERT_BODIES = new Set(["Open Hermes to see it.", "Open Hermes to answer."]);
export const CATEGORIES = new Set(["APPROVAL", "QUESTION", "REPLY", "MESSAGE", "TASK", "OPEN", "MEMORY", "CARD", "BOARD"]);
export const LEVELS = new Set(["passive", "active", "time-sensitive"]);
export const PHASES = new Set(["working", "needsYou", "done"]);
export const DEFAULT_TOPICS = ["co.caffeinatedcode.hermes", "co.caffeinatedcode.hermes.dev"];
export const MAX_PAYLOAD_BYTES = 4096;

export type PushType = "alert" | "background" | "liveactivity";

export interface Push {
  token: string;
  environment: "development" | "production";
  topic: string;
  push_type: PushType;
  priority: 5 | 10;
  collapse_id?: string;
  expiration?: number;
  payload: Record<string, unknown>;
}

export type Checked = { ok: true; push: Push } | { ok: false; error: string };

const isObject = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value);

const onlyKeys = (value: Record<string, unknown>, allowed: string[]) =>
  Object.keys(value).every((key) => allowed.includes(key));

function base64Length(value: unknown): number {
  if (typeof value !== "string" || !/^[A-Za-z0-9+/]+={0,2}$/.test(value) || value.length % 4 !== 0) return -1;
  return (value.length / 4) * 3 - (value.endsWith("==") ? 2 : value.endsWith("=") ? 1 : 0);
}

/** `{v: 1, epk: <32 bytes>, box: <nonce 12 + tag 16 + ciphertext>}` and nothing else. */
export function isEnvelope(value: unknown): boolean {
  return (
    isObject(value) &&
    onlyKeys(value, ["v", "epk", "box"]) &&
    value.v === 1 &&
    base64Length(value.epk) === 32 &&
    base64Length(value.box) >= 28
  );
}

function checkAlert(alert: unknown): string | null {
  if (!isObject(alert) || !onlyKeys(alert, ["title", "body"])) return "aps.alert must be {title, body}";
  if (!ALERT_TITLES.has(String(alert.title))) return "aps.alert.title must be a kind-only title";
  if (!ALERT_BODIES.has(String(alert.body))) return "aps.alert.body must be a kind-only line";
  return null;
}

function checkPayload(type: PushType, payload: Record<string, unknown>): string | null {
  const aps = payload.aps;
  if (!isObject(aps)) return "payload.aps is required";
  if (type === "alert") {
    if (!onlyKeys(payload, ["aps", "hermes"])) return "payload may only hold aps and hermes";
    if (!isEnvelope(payload.hermes)) return "payload.hermes must be a sealed envelope";
    if (!onlyKeys(aps, ["alert", "mutable-content", "category", "interruption-level", "relevance-score", "sound"]))
      return "aps holds a field the relay doesn't forward";
    const problem = checkAlert(aps.alert);
    if (problem) return problem;
    if (aps["mutable-content"] !== 1) return "alerts must be mutable-content";
    if (!CATEGORIES.has(String(aps.category))) return "unknown category";
    if (!LEVELS.has(String(aps["interruption-level"]))) return "unknown interruption level";
    if (aps.sound !== undefined && aps.sound !== "default") return "sound must be default";
    if (aps["relevance-score"] !== undefined && typeof aps["relevance-score"] !== "number") return "bad relevance";
    return null;
  }
  if (type === "background") {
    if (!onlyKeys(payload, ["aps", "hermes"])) return "payload may only hold aps and hermes";
    if (!isEnvelope(payload.hermes)) return "payload.hermes must be a sealed envelope";
    if (Object.keys(aps).length !== 1 || aps["content-available"] !== 1) return "background aps must be {content-available: 1}";
    return null;
  }
  // Live Activity: only the phase is in the clear; the widget opens `sealed`.
  if (!onlyKeys(payload, ["aps"])) return "Live Activity payload may only hold aps";
  if (!onlyKeys(aps, ["timestamp", "event", "content-state", "stale-date", "relevance-score", "alert", "sound", "dismissal-date"]))
    return "aps holds a field the relay doesn't forward";
  if (aps.event !== "update" && aps.event !== "end") return "event must be update or end";
  if (typeof aps.timestamp !== "number") return "timestamp is required";
  const state = aps["content-state"];
  if (!isObject(state) || !onlyKeys(state, ["phase", "sealed"]) || !PHASES.has(String(state.phase)) || !isEnvelope(state.sealed))
    return "content-state must be {phase, sealed}";
  if (aps.alert !== undefined) {
    const problem = checkAlert(aps.alert);
    if (problem) return problem;
  }
  if (aps.sound !== undefined && aps.sound !== "default") return "sound must be default";
  return null;
}

export function validatePush(body: unknown, allowedTopics: string[] = DEFAULT_TOPICS): Checked {
  if (!isObject(body)) return { ok: false, error: "body must be a JSON object" };
  if (!onlyKeys(body, ["token", "environment", "topic", "push_type", "priority", "collapse_id", "expiration", "payload"]))
    return { ok: false, error: "unknown field" };
  const token = String(body.token ?? "").toLowerCase();
  if (!/^[0-9a-f]{64,400}$/.test(token)) return { ok: false, error: "token must be hex" };
  const environment = body.environment;
  if (environment !== "development" && environment !== "production")
    return { ok: false, error: "environment must be development or production" };
  const type = body.push_type;
  if (type !== "alert" && type !== "background" && type !== "liveactivity")
    return { ok: false, error: "push_type must be alert, background or liveactivity" };
  const topic = String(body.topic ?? "");
  const base = type === "liveactivity" ? topic.replace(/\.push-type\.liveactivity$/, "") : topic;
  if (!allowedTopics.includes(base) || (type === "liveactivity") !== topic.endsWith(".push-type.liveactivity"))
    return { ok: false, error: "topic is not a Hermes app" };
  const priority = body.priority ?? (type === "background" ? 5 : 10);
  if (priority !== 5 && priority !== 10) return { ok: false, error: "priority must be 5 or 10" };
  if (type === "background" && priority !== 5) return { ok: false, error: "background pushes use priority 5" };
  const collapse = body.collapse_id;
  if (collapse !== undefined && (typeof collapse !== "string" || new TextEncoder().encode(collapse).length > 64))
    return { ok: false, error: "collapse_id must be a string of at most 64 bytes" };
  const expiration = body.expiration;
  if (expiration !== undefined && (!Number.isInteger(expiration) || (expiration as number) < 0))
    return { ok: false, error: "expiration must be unix seconds" };
  if (!isObject(body.payload)) return { ok: false, error: "payload must be an object" };
  const size = new TextEncoder().encode(JSON.stringify(body.payload)).length;
  if (size > MAX_PAYLOAD_BYTES) return { ok: false, error: `payload is ${size} bytes; APNs takes ${MAX_PAYLOAD_BYTES}` };
  const problem = checkPayload(type, body.payload);
  if (problem) return { ok: false, error: problem };
  return {
    ok: true,
    push: {
      token, environment, topic, push_type: type, priority: priority as 5 | 10,
      ...(collapse !== undefined ? { collapse_id: collapse as string } : {}),
      ...(expiration !== undefined ? { expiration: expiration as number } : {}),
      payload: body.payload,
    },
  };
}
