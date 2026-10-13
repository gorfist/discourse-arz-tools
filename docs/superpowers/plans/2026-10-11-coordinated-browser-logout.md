# Coordinated Browser Logout Implementation Plan

> **For agentic workers:** Execute this approved plan inline with the executing-plans skill. Repository Git restrictions take precedence over worktree, branch and commit steps.

**Goal:** Coordinate current-browser logout between Hub and Accounts with an administrator-configurable unconditional reload deadline.

**Architecture:** Extend the native application route logout action, retaining `currentUser.destroySession(pushSubscription)` and Discourse local-store cleanup. A standalone browser coordinator manages the overlay, iframe protocol and deadline. Accounts authenticates its parent before logout, skips redundant Hub logout for Hub callers, and otherwise POSTs the new exact-Origin Hub logout endpoint.

**Tech Stack:** Discourse Ruby/RSpec, Ember plugin API, browser JavaScript, Vue, Node test runner.

## Global Constraints

- Default deadline 10 seconds, adjustable from 1 to 120 seconds in Hub admin; start at the click, never reset, reload unconditionally at expiry.
- Background opacity 50%; only both successful branches permit an earlier reload.
- Exact coordinator parents: `https://hub.arzdigital.com`, `https://arzdigital.com`.
- Authenticate parent before credential clearing or server requests; deny top-level coordinator visits without logging out.
- No global logout API, iframe removal requirement, redirect fallback, or Git state mutation.

### Task 1: Hub browser logout endpoint

**Files:** `app/controllers/discourse_arz_tools_browser_logout_controller.rb`, `plugin.rb`, `spec/requests/browser_logout_controller_spec.rb`.

**Interfaces:** POST/OPTIONS `/discourse-arz-tools/browser-logout`; POST JSON `{}` with Accounts Origin and browser credentials; result `{success: true}`.

- [x] Add request specs for current-session revocation with a second surviving user token, guests, disabled plugin, invalid Origins and content types, and permitted/rejected preflights.
- [x] Implement the endpoint with the existing controller conventions and exact Accounts Origin protection before mutations:

```ruby
raise Discourse::InvalidAccess unless request.headers["Origin"] == "https://accounts.arzdigital.com"
reset_session
log_off_user
render json: { success: true }
```

- [x] Register POST and OPTIONS routes, JSON-only content handling and credentialed CORS/no-store.
- [x] Run request specs from a full Discourse root if available; otherwise report the runtime limitation and validate Ruby syntax with an available runtime/parser.

### Task 2: Accounts authorized coordinator

**Files:** `src/core/browser-logout.js`, `src/pages/f/index.vue`, `tests/browser-logout.test.mjs` in Accounts.

**Interfaces:** `coordinateIframeLogout({channel, logoutAccounts, clearCredentials, navigateToProfile, logoutHub})` waits for `channel.waitForParentOrigin()`; sends `channel.send("accounts:logout", {success, accounts, hub})`. `logoutHubBrowser` makes a bounded credentialed JSON POST.

- [x] Add behavioral tests: hold the handshake unresolved and assert no requests/cleanup; test both allowed parents, refused/top-level access, partial failure, cleanup before message and Hub HTTP/JSON/timeout failures.
- [x] Implement exact parent check, concurrent logout for Arzdigital, local cleanup after the Accounts request settles, and success only when required branches succeed:

```js
const origin = await channel.waitForParentOrigin();
if (!["https://hub.arzdigital.com", "https://arzdigital.com"].includes(origin)) {
  navigateToProfile();
  return;
}
```

- [x] Replace only the logout branch of the existing `/f` page with the coordinator; keep token handoff behavior. Normalize absent/non-string commands safely.
- [x] Run `node --test tests/browser-logout.test.mjs`, the full Accounts suite and `npm.cmd run build`.

### Task 3: Hub overlay, iframe and integration

**Files:** `assets/javascripts/discourse/lib/arz-browser-logout.js`, `assets/javascripts/discourse/initializers/arz-browser-logout.js`, `assets/stylesheets/common/arz-browser-logout.scss`, `config/settings.yml`, server/client locale files, `plugin.rb`, `tests/browser-logout.test.mjs`.

**Interfaces:** `createBrowserLogoutCoordinator({hostWindow, hostDocument, reload, showOverlay})` provides `start({timeoutSeconds, logoutHub})`; repeated calls share a promise. Overlay shows localized neutral loading text; reload callback abandons Discourse local-store data then calls `window.location.reload()`.

- [x] Add fake-clock/message tests for unloaded iframes, deadline bounds, both completion orders, failure, spoofed source/origin/request ID, readiness without completion, repeated clicks and one reload.
- [x] Implement a single timer created before server/iframe work, secure random request IDs, listener registration before iframe navigation and exact Accounts protocol verification.

```js
if (event.origin !== "https://accounts.arzdigital.com" || event.source !== iframe.contentWindow) return;
if (message.requestId !== requestId || message.namespace !== "arz-accounts" || message.version !== 1) return;
```

- [x] Extend `route:application` through `withPluginApi` and class-based `modifyClass`, overriding its `logout` action. Preserve native readonly/guest behavior with `super.logout()`; coordinate authenticated writable logout using `getCurrentPushSubscription()` and `currentUser.destroySession()`.
- [x] Add and localize `discourse_arz_tools_browser_logout_timeout_seconds` (integer, client true, default 10, min 1, max 120); register stylesheet.
- [x] Run Hub Node tests and verify the initializer against the inspected upstream route/plugin API. Add an integration test with mocked native route and plugin API so the actual initializer, superclass fallback and local-store/reload callback are exercised.

### Task 4: Review and deployment notes

**Files:** Hub `README.md`, approved spec and this checklist.

- [x] Document settings, endpoint, exact embedding origins, deploy Hub before Accounts, native Discourse runtime requirements, and incomplete-logout possibility at deadline.
- [x] Confirm Arzdigital already settles unsuccessful/missing completion via its bounded wait; do not change its existing logout code unnecessarily.
- [x] Review all diffs and run whitespace checks. Fix security/race issues, repeat only affected checks, and report test results with the real-browser/full-Discourse limitation.

## Validation results

- Hub Node coordinator and initializer tests: 12 passed.
- Accounts focused logout and real router-guard tests: 14 passed.
- Accounts full suite: 98 passed, 1 existing palette test failed because its Windows backslash path does not match the slash-based palette exclusion; palette files were not changed.
- Accounts production build succeeded. Hub initializer JavaScript syntax and all modified/new Hub YAML files parsed successfully. Read-only diff whitespace checks passed.
- Ruby request specs were added but could not be executed: no full Discourse checkout/runtime, no Ruby executable, Docker engine unavailable. Real-browser cookie and iframe validation remains a deployment check.
- No Git state-changing operations or deployment performed.
