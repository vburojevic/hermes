import { v } from "convex/values";
import { internalMutation, internalQuery, type MutationCtx } from "./_generated/server";

// Standard limits (owner's choice, 2026-10-14).
export const LIMITS = {
  pushesPerMinute: 120,
  pushesPerDay: 5000,
  registrationsPerHourPerIp: 20,
};

const MINUTE = 60_000;
const HOUR = 3_600_000;
const DAY = 86_400_000;

/** Count one event in a fixed window; false when it would go over `limit`. */
async function take(ctx: MutationCtx, key: string, limit: number, window: number, now: number): Promise<boolean> {
  const windowKey = `${key}:${Math.floor(now / window)}`;
  const counter = await ctx.db
    .query("counters")
    .withIndex("by_key", (q) => q.eq("key", windowKey))
    .unique();
  if (counter && counter.count >= limit) return false;
  if (counter) await ctx.db.patch(counter._id, { count: counter.count + 1 });
  else await ctx.db.insert("counters", { key: windowKey, count: 1, expiresAt: now + window * 2 });
  return true;
}

export const register = internalMutation({
  args: { installationId: v.string(), secretHash: v.string(), client: v.string(), ipHash: v.string() },
  handler: async (ctx, args): Promise<{ ok: boolean }> => {
    const now = Date.now();
    if (!(await take(ctx, `register-hour:${args.ipHash}`, LIMITS.registrationsPerHourPerIp, HOUR, now))) {
      return { ok: false };
    }
    await ctx.db.insert("installations", {
      installationId: args.installationId,
      secretHash: args.secretHash,
      client: args.client.slice(0, 64),
      createdAt: now,
      lastSeenAt: now,
      pushes: 0,
    });
    return { ok: true };
  },
});

export const lookup = internalQuery({
  args: { installationId: v.string() },
  handler: async (ctx, { installationId }) => {
    const row = await ctx.db
      .query("installations")
      .withIndex("by_installation", (q) => q.eq("installationId", installationId))
      .unique();
    return row ? { secretHash: row.secretHash, disabled: row.disabled ?? false } : null;
  },
});

/** Charge one push to an installation: "ok", or "minute" / "day" when a limit is reached. */
export const charge = internalMutation({
  args: { installationId: v.string() },
  handler: async (ctx, { installationId }): Promise<"ok" | "minute" | "day" | "unknown"> => {
    const row = await ctx.db
      .query("installations")
      .withIndex("by_installation", (q) => q.eq("installationId", installationId))
      .unique();
    if (!row || row.disabled) return "unknown";
    const now = Date.now();
    if (!(await take(ctx, `push-minute:${installationId}`, LIMITS.pushesPerMinute, MINUTE, now))) return "minute";
    if (!(await take(ctx, `push-day:${installationId}`, LIMITS.pushesPerDay, DAY, now))) return "day";
    await ctx.db.patch(row._id, { lastSeenAt: now, pushes: row.pushes + 1 });
    return "ok";
  },
});

/** Drop expired counters (cron). */
export const sweep = internalMutation({
  args: {},
  handler: async (ctx) => {
    const now = Date.now();
    const stale = await ctx.db
      .query("counters")
      .withIndex("by_expiry", (q) => q.lt("expiresAt", now))
      .take(500);
    for (const counter of stale) await ctx.db.delete(counter._id);
    return stale.length;
  },
});
