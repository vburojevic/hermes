import { cronJobs } from "convex/server";
import { internal } from "./_generated/api";

const crons = cronJobs();
crons.interval("sweep rate-limit counters", { hours: 1 }, internal.gateways.sweep, {});
export default crons;
