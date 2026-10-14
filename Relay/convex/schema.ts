import { defineSchema, defineTable } from "convex/server";
import { v } from "convex/values";

// The relay stores no content: gateway installations (a hashed secret) and rate-limit counters.
export default defineSchema({
  installations: defineTable({
    installationId: v.string(),
    secretHash: v.string(), // SHA-256 of the secret, hex
    client: v.string(),
    createdAt: v.number(),
    lastSeenAt: v.number(),
    pushes: v.number(),
    disabled: v.optional(v.boolean()),
  }).index("by_installation", ["installationId"]),

  counters: defineTable({
    key: v.string(), // e.g. "push-minute:<installation>:<window>", "register-hour:<ip hash>:<window>"
    count: v.number(),
    expiresAt: v.number(),
  })
    .index("by_key", ["key"])
    .index("by_expiry", ["expiresAt"]),
});
