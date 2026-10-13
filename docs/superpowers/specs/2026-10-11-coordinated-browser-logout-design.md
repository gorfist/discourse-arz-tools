# Coordinated browser logout

## Accepted behavior

Hub logout shows a full-screen loading overlay with a 50% opaque background, starts its normal DELETE session request, and opens a hidden Accounts logout iframe. The page reloads immediately once both operations complete successfully, or unconditionally when the overall deadline expires. The deadline starts at the logout click, includes iframe loading and handshake, and never restarts. Failures do not cancel the deadline. No top-level Accounts redirect fallback is used.

Add the integer Hub administrator setting `discourse_arz_tools_browser_logout_timeout_seconds`, exposed to the client, default 10 seconds, minimum 1, maximum 120. Provide Persian and English descriptions stating that this is the maximum total wait before an unconditional reload. Snapshot the setting when logout begins.

## Hub initiation

Integrate with the installed Discourse client's native logout operation so its normal DELETE, session cleanup and error handling are preserved while its navigation/reload is deferred. Verify the supported integration point against the target Discourse source before implementation. Repeated clicks share one operation. Show a Persian loading message, block interaction, and start the deadline before asynchronous work.

Create the message listener before assigning the hidden iframe URL `https://accounts.arzdigital.com/f?f=logout`. On iframe load, initialize the existing Accounts message protocol using a fresh random request ID and the exact Accounts target origin. Accept completion only with the expected protocol namespace/version, exact Accounts origin, exact iframe window source and matching request ID. A success message completes the Accounts branch; readiness and iframe load alone do not.

Reload the current page when both the Hub DELETE and Accounts branch succeed. Otherwise retain the overlay until the deadline and reload regardless of pending requests or failures. The timeout text must not claim that every service successfully logged out. No iframe removal is necessary before reload. Reload must execute at most once.

## Accounts authorization

The `/f?f=logout` coordinator must authenticate its iframe parent through the existing postMessage handshake before sending any logout request or clearing any credential. Permit only the exact production origins `https://hub.arzdigital.com` and `https://arzdigital.com` for this operation, even if the generic iframe channel permits additional origins.

URL parameters, referrers and caller-provided origin strings are not authorization. An unsupported parent, absent handshake, or a top-level visit to this coordinator navigates the Accounts frame/page to its own profile without logging out any service. The profile's normal authentication guard may show login when already unauthenticated. Do not navigate the parent window.

The IDP POST logout API and legitimate Accounts profile logout remain usable; the coordinator's caller restriction does not replace credential-based API authorization.

## Accounts completion

For a Hub parent, logout Accounts only: Hub is already handling its native logout. For an Arzdigital parent, run Accounts logout and the new Hub browser logout POST concurrently. Arzdigital retains responsibility for its existing local/site-session logout branch.

Accounts logout uses the existing credentialed IDP POST to terminate the current device family and clear the refresh cookie. An unauthorized/expired refresh response counts as an already-ended session. Clear local access and refresh tokens without calling the helper that immediately navigates. Send the completion message only after local cleanup and all required server branches succeed. A real network/server failure must produce an explicit unsuccessful result rather than the current unconditional success. Keep bounded requests and preserve the parent message envelope. Avoid navigating the iframe on successful completion.

## Hub browser logout endpoint

Add `POST /discourse-arz-tools/browser-logout` and its OPTIONS preflight. Accept only the exact Accounts Origin; permit credentialed CORS for that Origin only, emit Vary: Origin and no-store, restrict preflight to the supported method and headers, and reject unsupported content types. The endpoint uses strict Origin validation as its CSRF protection; exempt only this endpoint and its preflight from Discourse token-based CSRF checks.

Accounts calls it with credentials included and no Hub credential in the URL/body. Use Discourse's shared browser logoff/session-reset behavior so the browser's current Hub authentication is invalidated and cookies expire. Guests receive idempotent success. Do not use the global administrator logout API. Keep the native `log_out_strict` setting disabled for current-browser-only logout; if administrators enable it, native Discourse logoff deliberately revokes all Hub sessions. Return JSON without redirects and do not trigger coordinated iframe logout, preventing a loop. Gate the feature on the plugin being enabled; keep it independent of the browser-login setting.

## Validation and rollout

Test the overall deadline including stalled iframe loading, early completion, one-branch failure, repeated clicks and exactly one reload. Test parent authentication before side effects, rejected origins, request IDs/sources, top-level coordinator visits, cleanup before success, expired sessions and Arzdigital's concurrent Hub logout.

Add meaningful Hub request specs for credentialed CORS, rejected/missing Origins, malformed preflights, guest idempotency and termination of only the current browser session. Run Accounts tests/build and available Hub checks. Report if the full Discourse runtime is unavailable.

Deploy the Hub endpoint before Accounts begins calling it. Verify real browser cookies, embedding policies and native logout integration in the deployed Discourse version. Confirm the existing Arzdigital logout listener handles unsuccessful completion within its own bounded wait. The existing IDP logout endpoint needs no behavior change.

## Limits

The mandatory reload deadline bounds user waiting, not successful cross-service termination. A stalled or failed branch may leave that service authenticated after reload; do not report guaranteed completion in that case. Cross-service logout is not atomic. The requested scope is Hub, Accounts and the existing Arzdigital-initiated logout flow, not logout of unrelated applications or every device.
