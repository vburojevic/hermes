/// <reference types="vite/client" />
// Convex modules for convex-test. The multi-dot file names (this file and the
// *.test.ts files) keep them out of the Convex deploy bundle; the negative
// patterns keep them out of the module map.
export const modules = import.meta.glob(["./**/*.ts", "./**/*.js", "!./**/*.test.ts", "!./**/*.setup.ts", "!./**/*.d.ts"]);
