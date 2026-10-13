import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const source = readFileSync(new URL("../assets/javascripts/discourse/lib/arz-browser-logout.js", import.meta.url), "utf8");
const { createBrowserLogoutCoordinator } = await import(`data:text/javascript;base64,${Buffer.from(source).toString("base64")}`);

function fixture() {
  const timers = new Map(), listeners = new Map(), frames = [], events = [];
  let nextTimer = 0;
  const hostWindow = {
    crypto: { getRandomValues: array => array.fill(7) },
    setTimeout: (callback, milliseconds) => { timers.set(++nextTimer, { callback, milliseconds }); return nextTimer; },
    clearTimeout: id => timers.delete(id),
    addEventListener: (name, callback) => listeners.set(name, callback),
    removeEventListener: (name, callback) => { if (listeners.get(name) === callback) listeners.delete(name); },
  };
  const hostDocument = {
    createElement: tag => {
      assert.equal(tag, "iframe");
      const frame = {
        contentWindow: { postMessage: (data, origin) => events.push(["init", data, origin]) },
        addEventListener: (name, callback) => { frame[name] = callback; },
        setAttribute: () => {},
      };
      frames.push(frame);
      return frame;
    },
    body: { appendChild: frame => events.push(["frame", frame.src]) },
  };
  const coordinator = createBrowserLogoutCoordinator({
    hostWindow, hostDocument,
    showOverlay: () => { events.push("overlay"); return text => events.push(["text", text]); },
    reload: () => events.push("reload"),
  });
  const message = (data = {}, overrides = {}) => listeners.get("message")?.({
    origin: "https://accounts.arzdigital.com", source: frames[0].contentWindow,
    data: { namespace: "arz-accounts", version: 1, requestId: "07".repeat(16), action: "accounts:logout", data: { success: true }, ...data },
    ...overrides,
  });
  return { coordinator, hostWindow, hostDocument, timers, frames, events, listeners, message };
}
const flush = () => new Promise(resolve => setImmediate(resolve));

test("deadline starts immediately, includes unloaded iframe and always reloads", async () => {
  const f = fixture();
  const pending = f.coordinator.start({ logoutHub: () => new Promise(() => {}) });
  assert.equal(f.events[0], "overlay");
  assert.equal(f.timers.get(1).milliseconds, 30000);
  assert.equal(f.frames[0].src, "https://accounts.arzdigital.com/background.html?f=logout");
  f.timers.get(1).callback();
  assert.equal(await pending, "timeout");
  assert.equal(f.events.filter(e => e === "reload").length, 1);
  assert.equal(f.listeners.size, 0);
});

test("admin timeout is snapshotted and bounded; invalid values use thirty seconds", () => {
  for (const [input, expected] of [[1, 1000], [35, 35000], [120, 120000], [0, 30000], [121, 30000], [NaN, 30000]]) {
    const f = fixture();
    f.coordinator.start({ timeoutSeconds: input, logoutHub: async () => {} });
    assert.equal(f.timers.get(1).milliseconds, expected);
    f.timers.get(1).callback();
  }
});

test("reloads early only after both branches succeed in either completion order", async () => {
  for (const accountsFirst of [true, false]) {
    const f = fixture();
    let finishHub;
    const pending = f.coordinator.start({ logoutHub: () => new Promise(resolve => { finishHub = resolve; }) });
    await flush();
    if (accountsFirst) f.message(); else finishHub();
    await flush();
    assert.equal(f.events.includes("reload"), false);
    if (accountsFirst) finishHub(); else f.message();
    assert.equal(await pending, "success");
    assert.equal(f.events.filter(e => e === "reload").length, 1);
    assert.equal(f.timers.size, 0);
  }
});

test("load authenticates the iframe without restarting the deadline", () => {
  const f = fixture();
  f.coordinator.start({ logoutHub: async () => {} });
  f.frames[0].load();
  f.frames[0].load();
  assert.equal(f.timers.size, 1);
  assert.equal(f.events.filter(e => Array.isArray(e) && e[0] === "init").length, 2);
  const init = f.events.find(e => Array.isArray(e) && e[0] === "init");
  assert.equal(init[1].action, "accounts:init");
  assert.equal(init[2], "https://accounts.arzdigital.com");
  f.timers.get(1).callback();
});

test("wrong origin, window, ID, protocol, malformed messages and readiness cannot complete logout", async () => {
  const f = fixture();
  const pending = f.coordinator.start({ logoutHub: async () => {} });
  await flush();
  f.message({}, { origin: "https://evil.example" });
  f.message({}, { source: {} });
  f.message({ requestId: "other-request-id" });
  f.message({ namespace: "other" });
  f.message({ version: 2 });
  f.message({ action: "accounts:ready" });
  f.message({ data: null });
  f.message({ data: { success: "true" } });
  f.message({}, { data: null });
  assert.equal(f.events.includes("reload"), false);
  f.message();
  assert.equal(await pending, "success");
});

test("failed branches reload as soon as both settle in either completion order", async () => {
  for (const [hubFails, accountsFails, accountsFirst] of [
    [false, true, true], [false, true, false],
    [true, false, true], [true, false, false],
    [true, true, true], [true, true, false],
  ]) {
    const f = fixture();
    let finishHub;
    const pending = f.coordinator.start({ logoutHub: () => new Promise((resolve, reject) => {
      finishHub = () => hubFails ? reject(Error("offline")) : resolve();
    }) });
    const timeoutCallback = f.timers.get(1).callback;
    await flush();
    const finishAccounts = () => f.message({ data: { success: !accountsFails } });
    if (accountsFirst) finishAccounts(); else finishHub();
    await flush();
    assert.equal(f.events.includes("reload"), false);
    assert.equal(f.timers.size, 1);
    if (accountsFirst) finishHub(); else finishAccounts();
    assert.equal(await pending, "failed");
    assert.equal(f.timers.size, 0);
    assert.equal(f.listeners.size, 0);
    timeoutCallback();
    f.message();
    assert.equal(f.events.filter(e => e === "reload").length, 1);
  }
});

test("a failed Hub branch still waits for missing Accounts completion until the deadline", async () => {
  const f = fixture();
  const pending = f.coordinator.start({ logoutHub: async () => { throw Error("offline"); } });
  await flush();
  assert.equal(f.events.includes("reload"), false);
  assert.equal(f.timers.size, 1);
  f.timers.get(1).callback();
  assert.equal(await pending, "timeout");
});

test("iframe setup failure still attempts Hub logout and retains the deadline", async () => {
  const f = fixture();
  f.hostDocument.createElement = () => { throw Error("blocked"); };
  let attempts = 0;
  const pending = f.coordinator.start({ logoutHub: async () => { attempts++; } });
  await flush();
  assert.equal(attempts, 1);
  f.timers.get(1).callback();
  assert.equal(await pending, "timeout");
});

test("repeated clicks share the operation and late callbacks cannot reload twice", async () => {
  const f = fixture();
  let attempts = 0;
  const options = { logoutHub: async () => { attempts++; } };
  const pending = f.coordinator.start(options);
  const timeoutCallback = f.timers.get(1).callback;
  assert.equal(f.coordinator.start(options), pending);
  await flush();
  f.message();
  assert.equal(await pending, "success");
  timeoutCallback();
  f.message();
  assert.equal(attempts, 1);
  assert.equal(f.frames.length, 1);
  assert.equal(f.events.filter(e => e === "reload").length, 1);
});
