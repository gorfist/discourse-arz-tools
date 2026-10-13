# discourse-arz-tools

Backend-only Discourse plugin with Arzdigital API utilities:

- cached message counts for public chat channels
- performance-tuned API topic view tracking for selected `/t/...json` topic requests

Repository: https://github.com/gorfist/discourse-arz-tools

## Installation

Add this plugin to your Discourse `app.yml`:

```yaml
hooks:
  after_code:
    - exec:
        cd: $home/plugins
        cmd:
          - git clone https://github.com/gorfist/discourse-arz-tools.git
```

Then rebuild Discourse:

```sh
cd /var/discourse
./launcher rebuild app
```

## Chat Channel Message Counts

```http
GET /chat/api/channel-message-counts.json
```

The endpoint requires a logged-in Discourse user. Browser sessions work, and external clients can use normal Discourse API headers:

```sh
curl \
  -H "Api-Key: YOUR_KEY" \
  -H "Api-Username: USERNAME" \
  https://forum.example.com/chat/api/channel-message-counts.json
```

Example response:

```json
{
  "counts": {
    "12": 345,
    "18": 0
  },
  "cached_at": "2026-06-11T08:00:00Z",
  "cache_ttl_seconds": 43200
}
```

### Chat Count Load Safety

- API requests only read cache and resolve visible public chat channels.
- The grouped `COUNT(*)` query runs only from `Jobs::RefreshDiscourseArzToolsChatChannelMessageCounts`.
- Counts are cached under a fresh key for at least 12 hours.
- A stale fallback key is retained for 7 days by default.
- A distributed mutex prevents concurrent refresh jobs from running the count query together.
- Per-user rate limiting is enabled for the endpoint.
- Direct messages and group direct messages are never returned.

Until the first scheduled refresh completes, the endpoint returns an empty `counts` map with `cached_at: null`.

To prefill the cache during a quiet window:

```sh
RAILS_ENV=production bundle exec rails runner 'Jobs::RefreshDiscourseArzToolsChatChannelMessageCounts.new.execute'
```

### Troubleshooting `not_found`

If the API returns Discourse's `not_found` response for `/chat/api/channel-message-counts.json`, the endpoint route was not registered during boot. Deploy the current plugin version and rebuild or restart Discourse so `plugin.rb` can register the route against `Chat::Engine`.

After boot, verify the route from the Discourse container:

```sh
RAILS_ENV=production bundle exec rails routes | grep channel-message-counts
```

Then verify the API with a real API key and username:

```sh
curl \
  -H "Api-Key: YOUR_KEY" \
  -H "Api-Username: USERNAME" \
  https://forum.example.com/chat/api/channel-message-counts.json
```

### Recommended Chat Message Index

For large `chat_messages` tables, check the recommended partial index before enabling the scheduled job:

```sh
rake discourse_arz_tools:chat_channel_message_counts:check_index
```

If it is missing, create it during a quiet maintenance window:

```sh
rake discourse_arz_tools:chat_channel_message_counts:create_index
```

The task uses:

```sql
CREATE INDEX CONCURRENTLY IF NOT EXISTS index_chat_messages_channel_id_not_deleted
ON chat_messages (chat_channel_id)
WHERE deleted_at IS NULL;
```

## API Topic Views

This feature counts eligible API topic responses as topic views. It is based on the behavior from `gorfist/api-topic-views`, merged into `discourse-arz-tools` with request-side load controls.

It hooks into `TopicsController#show` and enqueues `Jobs::DiscourseArzToolsTrackApiTopicView` only when:

- `discourse_arz_tools_enabled` is true
- `discourse_arz_tools_api_topic_views_enabled` is true
- the response status is `200`
- the request uses Discourse API or User API authentication
- a topic id can be resolved from `@topic`, `params[:topic_id]`, or `params[:id]`
- the optional required header is present, when configured
- the request is not over the per-IP/per-topic rate limit, when configured

The increment itself is a single atomic SQL update against non-deleted topics. User visits are tracked only after a view increment succeeds and only for non-bot users.

Example:

```sh
curl \
  -H "Api-Key: YOUR_KEY" \
  -H "Api-Username: USERNAME" \
  https://forum.example.com/t/topic-slug/123.json
```

### API Topic View Load Safety

- Non-API requests are ignored before any job is enqueued.
- Non-200 responses are ignored.
- Bot users are ignored.
- Optional header gating lets you limit counting to trusted API clients.
- Optional per-IP/per-topic rate limiting runs before Sidekiq enqueue, so bursts do not create avoidable background jobs.
- The background job increments `topics.views` with one `UPDATE`, without loading and saving the full topic record.
- Success logging is debug-only via `DISCOURSE_ARZ_TOOLS_DEBUG=true`.

If `discourse_arz_tools_api_topic_views_require_header` is set to `X-Count-As-View`, clients must include it:

```sh
curl \
  -H "Api-Key: YOUR_KEY" \
  -H "Api-Username: USERNAME" \
  -H "X-Count-As-View: true" \
  https://forum.example.com/t/topic-slug/123.json
```

## Batched Topic View Beacon

This private endpoint lets Nexus report a real Arzdigital idea-page view without fetching the topic JSON:

```http
POST /discourse-arz-tools/topic-view.json
```

Nexus must use an admin Discourse API key. For an authenticated visitor, send the external identity derived from the trusted Nexus session:

```sh
curl -X POST \
  -H "Api-Key: ADMIN_API_KEY" \
  -H "Api-Username: system" \
  -H "Content-Type: application/json" \
  -d '{"topic_id":202277,"external_user_id":"11222"}' \
  https://hub.arzdigital.com/discourse-arz-tools/topic-view.json
```

For a guest, send the original client IP derived from Nexus's trusted proxy chain:

```json
{
  "topic_id": 202277,
  "ip": "203.0.113.42"
}
```

Never accept `external_user_id` or `ip` directly from an untrusted browser body. The browser calls Nexus; Nexus validates its session and proxy headers before calling Discourse.

The first visitor/topic event within the configured eight-hour window returns:

```json
{
  "counted": true,
  "buffered": true
}
```

A duplicate returns HTTP 200 without adding another pending view:

```json
{
  "counted": false,
  "reason": "duplicate"
}
```

Accepted views are HMAC-deduplicated and aggregated in Redis. Raw external user IDs and IP addresses are not stored in Redis or logs. An hourly scheduled job updates topic view counts with bounded, set-based SQL, so a view can take up to one hour to appear. This endpoint does not update `TopicUser` read state.

Other responses:

- `403`: the plugin/beacon is disabled, the request is not API-authenticated, or the API user is not an administrator.
- `422`: invalid topic or visitor identity input.
- `429`: the global safety limit was reached; `Retry-After: 60` is included. Dropping analytics events is safer than creating a retry storm.
- `503`: Redis intake is unavailable. Nexus may retry with bounded backoff.

To flush buffered views manually:

```sh
RAILS_ENV=production bundle exec rake discourse_arz_tools:topic_views:flush
```

After Nexus switches to this explicit beacon, disable `discourse_arz_tools_api_topic_views_enabled` to prevent an upstream topic JSON cache refresh and an explicit browser view from both contributing views.

## Settings

See [Hub WebView Authentication](docs/superpowers/specs/2026-08-16-hub-webview-auth-design.md)
for the direct app WebView login flow and its IDP contract.

- `discourse_arz_tools_enabled`: master switch for the plugin.
- `discourse_arz_tools_chat_channel_message_counts_enabled`: enable or disable the cached chat channel message counts API.
- `discourse_arz_tools_chat_channel_message_counts_cache_ttl_seconds`: fresh chat count cache TTL. Default `43200`, minimum `43200`.
- `discourse_arz_tools_chat_channel_message_counts_stale_ttl_seconds`: stale chat count fallback cache TTL. Default `604800`.
- `discourse_arz_tools_chat_channel_message_counts_rate_limit_per_minute`: per-user chat count endpoint limit. Default `30`.
- `discourse_arz_tools_api_topic_views_enabled`: enable API topic view tracking.
- `discourse_arz_tools_api_topic_views_require_header`: optional header required before API topic views are counted.
- `discourse_arz_tools_api_topic_views_max_per_minute_per_ip`: maximum API topic views per minute for one IP and topic. Default `0`, disabled.
- `discourse_arz_tools_topic_view_beacon_enabled`: enable the private topic view beacon. Default `false`.
- `discourse_arz_tools_topic_view_beacon_dedupe_seconds`: visitor/topic deduplication window. Default `28800` (8 hours).
- `discourse_arz_tools_topic_view_beacon_max_requests_per_minute`: global intake safety limit. Default `6000`.
- `discourse_arz_tools_topic_view_beacon_sql_batch_size`: maximum topics per SQL update statement. Default `500`.

## Local Testing

This standalone plugin repo can be syntax-checked locally, but request specs need to run from a full Discourse checkout with this plugin installed.

From the Discourse root:

```sh
LOAD_PLUGINS=1 bundle exec rspec plugins/discourse-arz-tools/spec
```

## Accounts browser login synchronization

Enable `discourse_arz_tools_sync_login_enabled` and DiscourseConnect with a secret matching IDP's `DISCOURSE_SSO_SECRET`.

The Hub admin setting `discourse_arz_tools_sync_login_replace_existing_user` controls automatic synchronization. It defaults to disabled: an existing Hub user is preserved. Enable it to replace the browser's current Hub user with the user in a valid Accounts ticket. It does not enable synchronization by itself or change explicit nonce-bound Hub login. The policy is server-only and is reevaluated on the login POST. When the signed-in Hub user already has the ticket's `external_id`, automatic synchronization returns `session_preserved` without resolving the user or creating another auth token, even with replacement enabled.

Accounts sends `POST /discourse-arz-tools/browser-login` with JSON `{"ticket":"<signed ticket>"}` and browser credentials. OPTIONS supports the exact `https://accounts.arzdigital.com` origin, POST and Content-Type. No Hub iframe or IDP HTTP exchange is required. Accounts CSP must permit the Hub in connect-src; proxies must preserve CORS and Set-Cookie headers.

The verifier checks the purpose-derived HS256 signature, issuer, Hub audience, 60-second expiry, identity binding and a random 128-bit `jti` (32 lowercase hexadecimal characters). After validation it atomically consumes the ID with `Discourse.redis.set(key, "1", nx: true, ex: remaining_seconds)`. The key is `discourse-arz-tools:browser-login:used:<jti>`; only the ID and marker are stored until the ticket's remaining expiry, with no database record or full ticket. Replays and tickets without valid IDs are rejected with HTTP 401. Redis errors fail closed. The reservation is retained even if downstream nonce validation, identity resolution or login fails; retry requires a fresh ticket. Consumption also applies to successful session preservation and explicit nonce-bound JSON tickets. If the browser already has an authenticated Hub user and automatic replacement is disabled, the endpoint preserves that session and returns {"success":true,"session_preserved":true} after consuming a ticket without `hub_nonce`, without switching users. For guests or enabled replacement, successful verification uses the existing identity resolver and normal Discourse `log_on_user`, returning `{"success":true}` and the Hub session cookie. Credential values are filtered from logs. Invalid, inactive, unapproved or suspended users and expired tickets cannot replace an existing session.

Deploy IDP's `jti` issuance before Hub replay protection and allow 60 seconds for older tickets to drain. Updated Hub rejects ID-less tickets from older IDP versions. Native browser-session nonce validation and consumption remain mandatory for explicit login. Redis must retain consumed-ID keys until expiry: eviction, flushing or loss of Redis data can remove replay protection for outstanding tickets. An unused ticket can still be accepted until expiry after its source IDP session ends; `jti` prevents reuse, not theft before first use or source-session revocation.

The login endpoint substitutes exact Origin plus signed short-lived credentials for a Hub CSRF token. The browser logout endpoint described below uses exact Origin protection. Other endpoints retain normal CSRF. Offline verification means source IDP logout cannot invalidate an outstanding ticket before its short expiry; the device UUID stored in the server session is only an association.

Ruby request and ticket-verifier specs require a full Discourse test runtime. Confirm real cross-origin cookie storage in the supported browsers before rollout.

### Hub-initiated background login

With `discourse_connect_url=https://accounts.arzdigital.com/auth/login`, Accounts receives the original native signed SSO context. IDP returns a browser-login ticket containing the signed original `hub_nonce`. Accounts sends that ticket in the body of a credentialed background JSON POST to `/discourse-arz-tools/browser-login` (no `.json` suffix). The endpoint validates the native browser-session nonce, reads the saved return path, consumes the nonce and signs in the Accounts user. It returns the safe Hub destination in `redirect_url`; Accounts navigates only after success. An unsafe destination falls back to the Hub root. A valid nonce-bound ticket can switch an existing Hub identity through the JSON endpoint, independently of the automatic replacement setting. Background synchronization without `hub_nonce` follows that setting.

The endpoint accepts only application/json and returns JSON for both success and failure. Other media types return HTTP 415 without verifying or consuming a ticket. Explicit nonce-bound login returns {"success":true,"redirect_url":"https://hub.arzdigital.com/<saved path>"} with the session cookie and no HTTP redirect. Accounts waits for success before navigating to redirect_url. A missing or unsafe saved destination falls back to the Hub root. Invalid browser nonces return HTTP 409; already-consumed tickets return HTTP 401. Send the ticket in the JSON body to the extensionless endpoint; URL credentials are rejected. Accounts CSP must permit Hub in connect-src. Tickets are signed, not encrypted, and must not be logged in request bodies. No user identity is included in the navigation URL.

The original IDP `/hub/v1/sso-start` and `/hub/v1/sso-continue` flow remains available. Restore `discourse_connect_url=https://idp.arzdigital.com/hub/v1/sso-start` to use it again. Verify real browser nonce handling, cookie creation and original-page navigation in a full Discourse deployment before rollout.

## Coordinated browser logout

Accounts obtains a Hub login ticket directly from IDP after deciding which client credentials are needed, then sends it in a credentialed JSON POST to `/discourse-arz-tools/browser-login`. When Arzdigital synchronization is needed, the same IDP request returns its one-time code alongside the Hub ticket. Hub applies `discourse_arz_tools_sync_login_replace_existing_user` when accepting the ticket: disabled preserves an existing session; enabled permits replacement. Explicit nonce-bound login retains its existing behavior. A request without a login ticket returns HTTP 400.

Hub's native logout action now shows a full-screen overlay with a 50% opaque background, retains the normal DELETE session request (including the browser push subscription), and loads `https://accounts.arzdigital.com/background.html?f=logout` in a hidden iframe. The native navigation is replaced by reloading the current page when both logout branches finish (including a failed Hub request or an Accounts `success:false` response) or when the total deadline expires. The timer starts at the click, including iframe loading and parent handshake. Repeated clicks reuse one operation.

In Hub admin, search for `discourse_arz_tools_browser_logout_timeout_seconds`: default **30 seconds**, range **1–120 seconds**, exposed to the client. Administrators can customize this maximum wait. The plugin master switch must be enabled; logout does not depend on browser-login synchronization being enabled. On failure the overlay states that complete sign-out could not be confirmed. Failed or timed-out logout stores a one-time notice in this tab and shows the same incomplete-sign-out explanation in a Discourse dialog after reload; notices expire after 60 seconds and successful logout stores no warning. Blocked browser storage does not prevent reload. A deadline reload cannot guarantee every remote session was terminated.

Accounts must authenticate the iframe parent using the existing `arz-accounts` version 1 handshake before logout or credential clearing. Only exact `https://hub.arzdigital.com` and `https://arzdigital.com` parents may use this coordinator. A Hub parent logs out Accounts and the separate Arzdigital session through an authenticated hidden Arzdigital receiver; an Arzdigital parent logs out Accounts and Hub concurrently while the main site retains responsibility for its own session. Untrusted/missing parents and top-level coordinator visits go to the Accounts profile without logout. The iframe reports `accounts:logout` only after cleanup, with the actual result. Hub validates the message Origin, source window and random request ID.

Accounts initiates Hub logout using credentialed JSON `POST /discourse-arz-tools/browser-logout` with `{}`. Exact Accounts Origin is mandatory, guest calls are idempotent, and OPTIONS permits POST and Content-Type only. The endpoint resets the browser session and uses native `log_off_user`, expires cookies and returns JSON without navigation. Normal Discourse policy applies: **keep `log_out_strict` disabled for current-browser-only logout**; enabling it makes native Discourse logoff revoke all the user's Hub sessions. No administrator/global logout API is called.

Deploy the Hub browser-logout endpoint and updated Arzdigital session receiver before updated Accounts. The receiver supports a credentialed IDP logout and local access cleanup, requires an exact Accounts parent handshake, and waits within a 5000ms overall Accounts deadline. Its CSP must allow the complete Hub -> Accounts -> Arzdigital ancestor chain. Direct Accounts profile/logout also coordinates Hub and Arzdigital before navigating to Accounts login. Existing receiver versions without logout capability report an incomplete branch and do not block local Accounts logout. Deploy Hub before Accounts. Accounts' parent-origin allow-list and `frame-ancestors` must allow Hub and Arzdigital; a stricter proxy CSP/X-Frame-Options policy must not block embedding. Hub/proxy frame policy must permit Accounts; Accounts/proxy `connect-src` must permit Hub. Preserve CORS, Origin and Set-Cookie through proxies. Existing Accounts IDP API and profile logout remain credential-authorized; the iframe-only caller restriction applies to `/background.html?f=logout`.

The initializer extends `route:application` via the modern class-based plugin API and retains `currentUser.destroySession()`; verify it on the deployed Discourse version. Run browser coordinator tests locally with `node --test tests/*.test.mjs`. Ruby request specs require the full Discourse runtime described above. Confirm real iframe messages, cross-origin cookies, early completion and stalled/failing requests reaching the configured mandatory reload deadline in supported browsers after deployment.

The hidden Accounts logout document is a standalone HTML/JavaScript entry without Vue UI, fonts or analytics. Deploy Accounts with background.html before updating Hub's caller. The legacy /f logout route remains available for older clients.
