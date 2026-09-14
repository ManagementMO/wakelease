import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { pathToFileURL } from "node:url";

const [pluginPath, cli] = process.argv.slice(2);
const { WakeLease } = await import(pathToFileURL(pluginPath).href);
const plugin = await WakeLease({});
const snapshot = () => JSON.parse(execFileSync(cli, ["status", "--json"], { env: process.env, timeout: 5000, encoding: "utf8" })).snapshot;
const emit = (type, properties) => plugin.event({ event: { type, properties } });

await emit("session.created", { info: { id: "first" } });
assert.equal(snapshot().effectiveCount, 0);
await emit("session.status", { sessionID: "first", status: { type: "busy" } });
await emit("session.status", { sessionID: "second", status: { type: "retry" } });
await emit("session.status", { sessionID: "first", status: { type: "busy" } });
assert.equal(snapshot().effectiveCount, 2);
assert.ok(snapshot().leases.every(lease => lease.owner?.pid === process.pid));
await emit("permission.asked", { sessionID: "first" });
assert.equal(snapshot().leases.find(lease => lease.sessionID === "first").state, "waitingForUser");
await emit("permission.replied", { sessionID: "first" });
assert.equal(snapshot().leases.find(lease => lease.sessionID === "first").state, "active");
await plugin["tool.execute.after"]({ sessionID: "first" });
await emit("session.status", { sessionID: "first", status: { type: "idle" } });
assert.equal(snapshot().effectiveCount, 1);
await emit("session.deleted", { sessionID: "second" });
assert.equal(snapshot().effectiveCount, 0);
await emit("session.status", { status: { type: "busy" } });
assert.equal(snapshot().effectiveCount, 0);
console.log("Generated OpenCode plugin executed against local event fixtures; no live host/provider certification.");
