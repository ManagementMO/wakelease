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
const ai = await import(pathToFileURL(join(sdkRoot, "node_modules/@earendil-works/pi-ai/dist/index.js")).href);
const runtime = await sdk.ModelRuntime.create({ credentials: new ai.InMemoryCredentialStore(), modelsPath: null, allowModelNetwork: false });
await runtime.setRuntimeApiKey("openai", "offline-fixture-not-a-credential", { allowNetwork: false });
const model = runtime.getModels("openai")[0];
assert.ok(model, "The pinned SDK must expose a built-in model for its mocked stream");
const plugin = join(home, ".pi/agent/extensions/wakelease.ts");
const errors = [];
const sessions = [];

function snapshot() {
  return JSON.parse(execFileSync(cli, ["status", "--json"], { env: process.env, timeout: 5000, encoding: "utf8" })).snapshot;
}

async function waitForCount(count) {
  const deadline = Date.now() + 5000;
  while (Date.now() < deadline) {
    const state = snapshot();
    if (state.effectiveCount === count) return state;
    await new Promise(resolve => setTimeout(resolve, 20));
  }
  assert.fail(`Expected ${count} leases; observed ${JSON.stringify(snapshot())}`);
}

async function makeSession() {
  const settings = sdk.SettingsManager.inMemory({ compaction: { enabled: false }, retry: { enabled: false } });
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
  let release;
  let entered;
  const started = new Promise(resolve => { entered = resolve; });
  const gate = new Promise(resolve => { release = resolve; });
  session.agent.streamFunction = (selectedModel, _context, options) => {
    const message = { role: "assistant", content: [{ type: "text", text: "Offline fixture complete" }], api: selectedModel.api,
      provider: selectedModel.provider, model: selectedModel.id, usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0,
        totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } }, stopReason: "stop", timestamp: Date.now() };
    options?.signal?.addEventListener("abort", release, { once: true });
    return {
      async *[Symbol.asyncIterator]() {
        entered();
        yield { type: "start", partial: message };
        await gate;
        yield { type: "done", reason: "stop", message };
      },
      async result() { await gate; return message; }
    };
  };
  return { session, started, release: () => release() };
}

try {
  const first = await makeSession();
  const second = await makeSession();
  assert.notEqual(first.session.sessionId, second.session.sessionId);
  const firstTurn = first.session.prompt("Exercise the first local lifecycle");
  await first.started;
  await waitForCount(1);
  const secondTurn = second.session.prompt("Exercise an independent overlapping lifecycle");
  await second.started;
  const active = await waitForCount(2);
  assert.equal(new Set(active.leases.map(lease => lease.sessionID)).size, 2);
  assert.ok(active.leases.every(lease => lease.owner?.pid === process.pid));
  first.release();
  await firstTurn;
  await waitForCount(1);
  second.release();
  await secondTurn;
  await waitForCount(0);
  await first.session.prompt("Exercise a second turn on the same session");
  await waitForCount(0);
  assert.deepEqual(errors, []);
  assert.equal(networkAttempts, 0);
  console.log(JSON.stringify({ host: "Pi SDK", version: "0.83.0", model: "mock stream only", networkAttempts,
    verified: ["real generated extension loading", "agent_start acquisition", "independent overlapping sessions", "PID ownership", "agent_settled release", "second turn cleanup"] }));
} finally {
  for (const session of sessions) { await session.abort(); session.dispose(); }
}
