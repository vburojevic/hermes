import { defineConfig } from "vitest/config";

// convex-test runs Convex functions in an edge-runtime VM (closest match to the
// Convex isolate) and must be inlined. See https://docs.convex.dev/testing/convex-test.
export default defineConfig({
  test: {
    include: ["convex/**/*.test.ts"],
    environment: "edge-runtime",
    server: { deps: { inline: ["convex-test"] } },
  },
});
