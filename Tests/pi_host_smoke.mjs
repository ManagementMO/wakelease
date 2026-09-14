import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import http from "node:http";
import https from "node:https";
import http2 from "node:http2";
import net from "node:net";
import tls from "node:tls";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const [sdkRoot, home, cli] = process.argv.slice(2);
assert.equal(JSON.parse(readFileSync(join(sdkRoot, "package.json"), "utf8")).version, "0.83.0");
let networkAttempts = 0;
const denyNetwork = () => { networkAttempts++; throw new Error("Network is forbidden in the offline host fixture"); };
globalThis.fetch = denyNetwork;
http.request = http.get = https.request = https.get = denyNetwork;
http2.connect = net.connect = net.createConnection = tls.connect = denyNetwork;
net.Socket.prototype.connect = denyNetwork;

const sdk = await import(pathToFileURL(join(sdkRoot, "dist/index.js")).href);
const runtime = await sdk.ModelRuntime.create({ authPath: join(home, ".pi/agent/auth.json"), modelsPath: null, allowModelNetwork: false });
await runtime.setRuntimeApiKey("openai", "offline-fixture-not-a-credential", { allowNetwork: false });
const model = runtime.getModels("openai")[0];
assert.ok(model, "The pinned SDK must expose a built-in model for its mocked stream");
const plugin = join(home, ".pi/agent/extensions/wakelease.ts");
const errors = [];
const sessions = [];

function snapshot() {
  return JSON.parse(execFileSync(cli, ["status", "--json"], { env: process.env, timeout: 5000, encoding: "utf8" })).snapshot;
}

async function waitFor(probe, description) {
  const deadline = Date.now() + 5000;
  while (Date.now() < deadline) {
    const result = probe();
    if (result) return result;
    await new Promise(resolve => setTimeout(resolve, 20));
  }
  assert.fail(`Timed out waiting for ${description}`);
}

const waitForCount = count => waitFor(() => {
  const state = snapshot();
  return state.effectiveCount === count ? state : undefined;
}, `${count} effective leases`);
const leaseFor = session => snapshot().leases.find(lease => lease.sessionID === session.sessionId);
const settledCount = fixture => fixture.events.filter(event => event.type === "agent_settled").length;

async function makeSession(retry = { enabled: false }) {
  const settings = sdk.SettingsManager.inMemory({ compaction: { enabled: false }, retry });
  const loader = new sdk.DefaultResourceLoader({ cwd: process.cwd(), agentDir: join(home, ".pi/agent"), settingsManager: settings,
    noExtensions: true, noSkills: true, noPromptTemplates: true, noThemes: true, noContextFiles: true,
    additionalExtensionPaths: [plugin], systemPrompt: "Offline lifecycle fixture. No tools or network." });
  await loader.reload();
  assert.deepEqual(loader.getExtensions().errors, []);
  assert.equal(loader.getExtensions().extensions.length, 1, "Only the generated WakeLease extension is loaded");
  const { session } = await sdk.createAgentSession({ cwd: process.cwd(), agentDir: join(home, ".pi/agent"), modelRuntime: runtime,
    model, tools: [], thinkingLevel: "off", resourceLoader: loader, settingsManager: settings, sessionManager: sdk.SessionManager.inMemory(process.cwd()) });
  await session.bindExtensions({ onError: error => errors.push(String(error)) });
  sessions.push(session);
  const calls = [];
  const events = [];
  session.subscribe(event => events.push(event));
  session.agent.streamFunction = (selectedModel, _context, options) => {
    const partial = { role: "assistant", content: [{ type: "text", text: "Offline fixture complete" }], api: selectedModel.api,
      provider: selectedModel.provider, model: selectedModel.id, usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0,
        totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } }, stopReason: "stop", timestamp: Date.now() };
    let resolve;
    const result = new Promise(done => { resolve = done; });
    const finish = (stopReason = "stop", errorMessage) => resolve({ ...partial, stopReason, errorMessage });
    const aborted = () => finish("aborted", "Offline fixture cancelled");
    const message = result.finally(() => options?.signal?.removeEventListener("abort", aborted));
    calls.push({ finish, signal: options?.signal });
    if (options?.signal?.aborted) aborted();
    else options?.signal?.addEventListener("abort", aborted, { once: true });
    return {
      async *[Symbol.asyncIterator]() {
        yield { type: "start", partial };
        const final = await message;
        if (["error", "aborted"].includes(final.stopReason)) yield { type: "error", reason: final.stopReason, error: final };
        else yield { type: "done", reason: "stop", message: final };
      },
      result: () => message
    };
  };
  return { session, calls, events, call: index => waitFor(() => calls[index], `model call ${index}`) };
}

const verified = [];
async function check(name, body) {
  await body();
  await waitForCount(0);
  assert.deepEqual(errors, []);
  assert.equal(networkAttempts, 0);
  verified.push(name);
}

try {
  await check("overlapping sessions, PID ownership and independent completion", async () => {
    const first = await makeSession();
    const second = await makeSession();
    assert.notEqual(first.session.sessionId, second.session.sessionId);
    assert.equal(snapshot().effectiveCount, 0);
    const firstTurn = first.session.prompt("Exercise the first local lifecycle");
    const firstCall = await first.call(0);
    await waitForCount(1);
    const secondTurn = second.session.prompt("Exercise an independent overlapping lifecycle");
    const secondCall = await second.call(0);
    const active = await waitForCount(2);
    assert.equal(new Set(active.leases.map(lease => lease.sessionID)).size, 2);
    assert.ok(active.leases.every(lease => lease.owner?.pid === process.pid));
    firstCall.finish();
    await firstTurn;
    await waitForCount(1);
    secondCall.finish();
    await secondTurn;
    const nextTurn = first.session.prompt("Exercise a second turn on the same session");
    (await first.call(1)).finish();
    await nextTurn;
    assert.equal(settledCount(first), 2);
  });

  await check("active cancellation preserves another session", async () => {
    const first = await makeSession();
    const second = await makeSession();
    const firstTurn = first.session.prompt("Cancel this local turn");
    const firstCall = await first.call(0);
    const secondTurn = second.session.prompt("Keep this local turn active");
    const secondCall = await second.call(0);
    await waitForCount(2);
    const otherID = leaseFor(second.session).id;
    await first.session.abort();
    await firstTurn;
    assert.equal(firstCall.signal.aborted, true);
    await waitForCount(1);
    assert.equal(leaseFor(second.session).id, otherID);
    assert.equal(leaseFor(first.session), undefined);
    secondCall.finish();
    await secondTurn;
  });

  await check("terminal model failure releases the lease", async () => {
    const fixture = await makeSession();
    const turn = fixture.session.prompt("Fail this local turn");
    (await fixture.call(0)).finish("error", "Offline fixture invalid request");
    await turn;
    assert.equal(fixture.session.messages.at(-1).stopReason, "error");
    assert.equal(settledCount(fixture), 1);
  });

  await check("automatic retry retains the original lease until success", async () => {
    const fixture = await makeSession({ enabled: true, maxRetries: 1, baseDelayMs: 10 });
    const turn = fixture.session.prompt("Retry this local turn");
    const first = await fixture.call(0);
    const original = leaseFor(fixture.session).id;
    first.finish("error", "429 rate limit exceeded");
    const second = await fixture.call(1);
    assert.equal(leaseFor(fixture.session).id, original);
    assert.equal(settledCount(fixture), 0);
    second.finish();
    await turn;
    assert.ok(fixture.events.some(event => event.type === "auto_retry_end" && event.success));
    assert.equal(settledCount(fixture), 1);
  });

  await check("retry exhaustion releases exactly at settlement", async () => {
    const fixture = await makeSession({ enabled: true, maxRetries: 1, baseDelayMs: 10 });
    const turn = fixture.session.prompt("Exhaust the local retry budget");
    (await fixture.call(0)).finish("error", "429 rate limit exceeded");
    const last = await fixture.call(1);
    assert.equal(settledCount(fixture), 0);
    last.finish("error", "429 rate limit exceeded");
    await turn;
    assert.equal(fixture.calls.length, 2);
    assert.ok(fixture.events.some(event => event.type === "auto_retry_end" && event.success === false));
    assert.equal(settledCount(fixture), 1);
  });

  await check("cancelling retry backoff does not start another model call", async () => {
    const fixture = await makeSession({ enabled: true, maxRetries: 2, baseDelayMs: 30000 });
    const turn = fixture.session.prompt("Cancel the pending local retry");
    (await fixture.call(0)).finish("error", "429 rate limit exceeded");
    await waitFor(() => fixture.session.isRetrying, "retry backoff");
    assert.equal(fixture.session.isStreaming, true, "Pi's reload guard must continue seeing pending retries as busy");
    assert.equal(fixture.session.isIdle, false);
    assert.ok(leaseFor(fixture.session));
    assert.equal(settledCount(fixture), 0);
    await fixture.session.abort();
    await turn;
    assert.equal(fixture.calls.length, 1);
    assert.equal(settledCount(fixture), 1);
  });

  await check("queued follow-up retains the lease across model calls", async () => {
    const fixture = await makeSession();
    const turn = fixture.session.prompt("Start the local queued-work fixture");
    const first = await fixture.call(0);
    const original = leaseFor(fixture.session).id;
    await fixture.session.followUp("Continue with the queued local turn");
    first.finish();
    const next = await fixture.call(1);
    assert.equal(leaseFor(fixture.session).id, original);
    assert.equal(settledCount(fixture), 0);
    next.finish();
    await turn;
    assert.equal(fixture.calls.length, 2);
    assert.equal(settledCount(fixture), 1);
  });

  await check("idle resource reload preserves the next turn lifecycle", async () => {
    const fixture = await makeSession();
    await fixture.session.reload();
    assert.equal(snapshot().effectiveCount, 0);
    const turn = fixture.session.prompt("Run after an idle extension reload");
    const call = await fixture.call(0);
    assert.ok(leaseFor(fixture.session));
    call.finish();
    await turn;
    assert.equal(settledCount(fixture), 1);
  });

  console.log(JSON.stringify({ host: "Pi SDK", version: "0.83.0", model: "mock stream only", networkAttempts, verified }));
} finally {
  for (const session of sessions) { await session.abort(); session.dispose(); }
}
