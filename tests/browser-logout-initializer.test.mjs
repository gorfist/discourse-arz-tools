import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";

const helperSource = readFileSync(new URL("../assets/javascripts/discourse/lib/arz-browser-logout.js", import.meta.url), "utf8");
const { createBrowserLogoutCoordinator } = await import(`data:text/javascript;base64,${Buffer.from(helperSource).toString("base64")}`);
// Exercise the actual initializer logic with module boundaries mocked. Ember's
// action decorator and resolver still require the full Discourse browser runtime.
const source = readFileSync(new URL("../assets/javascripts/discourse/initializers/arz-browser-logout.js", import.meta.url), "utf8")
  .replace(/^import .*;\r?\n/gm, "")
  .replace(/@action\s+/g, "")
  .replace("export default", "globalThis.initializer =");

function fixture({ enabled = true, readOnly = false, staffWritesOnly = false, guest = false, storageError = false,
  sessionStorage = new Map(), blockedStorage = false } = {}) {
  const events = [], timers = new Map(), listeners = new Map();
  const frame = { contentWindow: { postMessage() {} }, setAttribute() {}, addEventListener() {} };
  const hostWindow = {
    sessionStorage: {
      getItem: key => { if (blockedStorage) throw Error('storage blocked'); return sessionStorage.get(key) ?? null; },
      setItem: (key, value) => { if (blockedStorage) throw Error('storage blocked'); sessionStorage.set(key, value); },
      removeItem: key => { if (blockedStorage) throw Error('storage blocked'); sessionStorage.delete(key); },
    },
    crypto: { getRandomValues: bytes => bytes.fill(8) },
    location: { reload: () => events.push("reload") },
    setTimeout: (callback, ms) => { timers.set(1, { callback, ms }); return 1; },
    clearTimeout: id => timers.delete(id),
    addEventListener: (name, callback) => listeners.set(name, callback),
    removeEventListener: name => listeners.delete(name),
  };
  class NativeRoute {
    logout() { events.push("native-fallback"); return "native"; }
  }
  let Route = NativeRoute;
  const settings = { discourse_arz_tools_enabled: enabled, discourse_arz_tools_browser_logout_timeout_seconds: 30 };
  const context = vm.createContext({
    window: hostWindow,
    createBrowserLogoutCoordinator: options => createBrowserLogoutCoordinator({
      ...options, hostWindow,
      hostDocument: { createElement: () => frame, body: { appendChild() {} } },
      showOverlay: () => { events.push("overlay"); return () => {}; },
    }),
    withPluginApi: (version, callback) => callback({ modifyClass: (name, extend) => {
      assert.equal(name, "route:application");
      Route = extend(NativeRoute);
    } }),
    getCurrentPushSubscription: async () => { events.push("push"); return { endpoint: "browser-push" }; },
    schedule: (queue, callback) => { assert.equal(queue, 'afterRender'); callback(); },
    i18n: key => key,
  });
  vm.runInContext(source, context);
  context.initializer.initialize({ lookup: name => {
    if (name === "service:site-settings") return settings;
    if (name === "service:dialog") return { alert: options => events.push(['alert', options.message]) };
    if (name === "service:key-value-store") return { abandonLocal: () => {
      events.push("abandonLocal");
      if (storageError) throw Error("storage unavailable");
    } };
    throw Error(`Unexpected service ${name}`);
  } });
  const route = new Route();
  route.site = { isReadOnly: readOnly, isStaffWritesOnly: staffWritesOnly };
  route.currentUser = guest ? null : { destroySession: async subscription => {
    events.push("delete");
    assert.equal(subscription.endpoint, "browser-push");
    return { redirect_url: "https://accounts.arzdigital.com/old-redirect" };
  } };
  return { route, events, timers, listeners, frame, settings, sessionStorage };
}

test("native DELETE and push cleanup run while redirect is deferred until Accounts completion", async () => {
  const f = fixture();
  const pending = f.route.logout();
  assert.equal(f.events[0], "overlay");
  assert.equal(f.timers.get(1).ms, 30000);
  f.settings.discourse_arz_tools_browser_logout_timeout_seconds = 1;
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(f.events, ["overlay", "push", "delete"]);
  f.listeners.get("message")({
    origin: "https://accounts.arzdigital.com", source: f.frame.contentWindow,
    data: { namespace: "arz-accounts", version: 1, requestId: "08".repeat(16), action: "accounts:logout", data: { success: true } },
  });
  assert.equal(await pending, "success");
  assert.deepEqual(f.events, ["overlay", "push", "delete", "abandonLocal", "reload"]);
});

test('timeout persists an incomplete logout notice that is shown once after refresh, even for a guest', async () => {
  const f = fixture();
  const pending = f.route.logout();
  await new Promise(resolve => setImmediate(resolve));
  f.timers.get(1).callback();
  assert.equal(await pending, 'timeout');
  assert.equal(JSON.parse(f.sessionStorage.get('arz-browser-logout-notice')).reason, 'timeout');
  assert.equal(f.events.at(-1), 'reload');
  const refreshed = fixture({ sessionStorage: f.sessionStorage, guest: true });
  assert.deepEqual(refreshed.events, [['alert', 'discourse_arz_tools.browser_logout_incomplete']]);
  assert.equal(refreshed.sessionStorage.size, 0);
  assert.deepEqual(fixture({ sessionStorage: f.sessionStorage }).events, []);
});

test('a failed Accounts result preserves failure through refresh instead of claiming completed sign-out', async () => {
  const f = fixture();
  const pending = f.route.logout();
  await new Promise(resolve => setImmediate(resolve));
  f.listeners.get('message')({
    origin: 'https://accounts.arzdigital.com', source: f.frame.contentWindow,
    data: { namespace: 'arz-accounts', version: 1, requestId: '08'.repeat(16), action: 'accounts:logout', data: { success: false } },
  });
  assert.equal(await pending, 'failed');
  assert.equal(JSON.parse(f.sessionStorage.get('arz-browser-logout-notice')).reason, 'failed');
});

test('stale and malformed notices are discarded and successful logout produces no notice', async () => {
  for (const value of ['invalid', JSON.stringify({ reason: 'success', at: Date.now() }),
    JSON.stringify({ reason: 'timeout', at: Date.now() - 61000 }), JSON.stringify({ reason: 'timeout', at: Date.now() + 60000 })]) {
    const sessionStorage = new Map([['arz-browser-logout-notice', value]]);
    const f = fixture({ sessionStorage });
    assert.deepEqual(f.events, []);
    assert.equal(sessionStorage.size, 0);
  }
  const f = fixture();
  const pending = f.route.logout();
  await new Promise(resolve => setImmediate(resolve));
  f.listeners.get('message')({
    origin: 'https://accounts.arzdigital.com', source: f.frame.contentWindow,
    data: { namespace: 'arz-accounts', version: 1, requestId: '08'.repeat(16), action: 'accounts:logout', data: { success: true } },
  });
  assert.equal(await pending, 'success');
  assert.equal(f.sessionStorage.size, 0);
});

test('blocked session storage cannot prevent timeout reload', async () => {
  const f = fixture({ blockedStorage: true });
  const pending = f.route.logout();
  await new Promise(resolve => setImmediate(resolve));
  f.timers.get(1).callback();
  assert.equal(await pending, 'timeout');
  assert.equal(f.events.at(-1), 'reload');
});

test("disabled plugin, guests and readonly mode retain native behavior", () => {
  for (const options of [{ enabled: false }, { guest: true }, { readOnly: true }]) {
    const f = fixture(options);
    assert.equal(f.route.logout(), "native");
    assert.deepEqual(f.events, ["native-fallback"]);
    assert.equal(f.timers.size, 0);
  }
  const f = fixture({ readOnly: true, staffWritesOnly: true });
  f.route.logout();
  assert.equal(f.events[0], "overlay");
  f.timers.get(1).callback();
});

test("a disabled master switch is respected on an already-initialized page", () => {
  const f = fixture();
  f.settings.discourse_arz_tools_enabled = false;
  assert.equal(f.route.logout(), "native");
  assert.deepEqual(f.events, ["native-fallback"]);
});

test("local-store errors cannot prevent the mandatory page reload", async () => {
  const f = fixture({ storageError: true });
  const pending = f.route.logout();
  await new Promise(resolve => setImmediate(resolve));
  assert.throws(() => f.timers.get(1).callback(), /storage unavailable/);
  assert.equal(await pending, "timeout");
  assert.deepEqual(f.events.slice(-2), ["abandonLocal", "reload"]);
});
