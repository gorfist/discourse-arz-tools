# Batched Topic View Beacon Design

## Goal

Add a private, low-load endpoint to `discourse-arz-tools` that lets Nexus report real views of Arzdigital idea pages even when the topic JSON is served from CDN or application caches. Count at most one view per topic and visitor in a rolling eight-hour window, and apply accepted counts to Discourse topics no more frequently than once per hour.

The feature must not create one Sidekiq job, topic fetch, model load, or PostgreSQL write per browser view.

## System Boundary and Request Flow

The browser does not call Discourse directly:

```text
arzdigital.com browser
  -> lake.arzdigital.com / Nexus
  -> hub.arzdigital.com / discourse-arz-tools
  -> Redis deduplication and aggregation
  -> hourly bounded PostgreSQL flush
```

1. Arzdigital JavaScript reports a visible idea page to Nexus.
2. Nexus determines the visitor identity from its trusted request context.
3. Nexus calls the plugin endpoint using its existing Discourse admin API key.
4. The plugin atomically deduplicates the visitor/topic pair and, for a new view, increments a pending Redis counter for the topic.
5. An hourly scheduled job aggregates and applies pending counts to PostgreSQL in bounded batches.

There is no browser-to-Discourse CORS flow and no Discourse credential is exposed to JavaScript.

## Endpoint Contract

Add this global Discourse route:

```http
POST /discourse-arz-tools/topic-view.json
Api-Key: <admin-api-key>
Api-Username: <admin-username>
Content-Type: application/json
```

Authenticated visitor body:

```json
{
  "topic_id": 202277,
  "external_user_id": "11222"
}
```

Guest visitor body:

```json
{
  "topic_id": 202277,
  "ip": "203.0.113.42"
}
```

Rules:

- The current Discourse API user must be an administrator.
- `topic_id` must be a positive integer.
- Exactly one of `external_user_id` and `ip` must be present.
- `external_user_id` is treated as an opaque, non-empty string of at most 255 bytes derived by Nexus from the authenticated session.
- Guest IP input must parse as IPv4 or IPv6 and is canonicalized with Ruby's `IPAddr` before hashing.
- The endpoint does not query PostgreSQL to validate topic existence. The hourly update naturally ignores nonexistent and deleted topics. This deliberate choice keeps the request path independent of PostgreSQL.
- Invalid authentication returns `403`; invalid input returns `422`; the configured safety limit returns `429`.

For a newly accepted view, return HTTP 200:

```json
{
  "counted": true,
  "buffered": true
}
```

For a duplicate in the eight-hour window, return HTTP 200:

```json
{
  "counted": false,
  "reason": "duplicate"
}
```

`counted: true` means accepted into the Redis aggregate. The visible Discourse topic count may update up to one hour later.

## Identity and Privacy

Authenticated visitors use the namespace `user:<external_user_id>`. Guests use `ip:<canonical_ip>`.

The plugin derives the Redis identity digest with HMAC-SHA256 and a server-side Discourse secret. Redis keys never contain the raw external ID or IP address. The HMAC is scoped to this feature and its key format version.

The identity is used only for deduplication. The feature does not resolve SSO records and does not call `TopicUser.track_visit!`. Those per-user database operations are outside the requirement to increase the visible topic view count and would undermine the load-safety design.

One person can count once as a guest and once after authenticating because the two trusted identities cannot be reliably linked without adding user-tracking behavior. This is an accepted analytics approximation.

## Atomic Redis Intake

Use a small Lua script so acceptance is atomic across every Discourse web process:

1. Increment a short-lived global request-volume counter for the endpoint.
2. Reject with a safety-limit result when the configured per-minute maximum is exceeded.
3. Attempt `SET <dedupe-key> 1 NX EX <dedupe-seconds>`.
4. If the key was created, `HINCRBY` the active pending hash by `topic_id`.
5. Return one of: accepted, duplicate, or rate limited.

Default policies:

- Explicit endpoint: disabled until an administrator enables it after deployment.
- Deduplication window: 28,800 seconds (eight hours).
- Flush interval: one hour.
- Intake safety limit: 6,000 requests per minute globally, configurable and documented for tuning to observed Nexus traffic.
- SQL update batch size: 500 topics, configurable.

The Lua script prevents a failure between dedupe creation and counter increment from silently losing an accepted view. Duplicate requests perform no queue or database work.

## Hourly Flush and Bounded Database Work

The scheduled flush job acquires a distributed mutex. If another flush owns it, the new run exits without waiting.

Under the mutex, the job:

1. Retries any existing processing batch before starting a new one.
2. Atomically renames the active Redis hash to a uniquely identified processing hash.
3. Reads topic/count pairs from that immutable processing hash.
4. Applies increments with set-based SQL in bounded groups. Each statement updates existing, non-deleted topics only.
5. Records the processing batch ID in PostgreSQL in the same transaction as the topic updates.
6. Deletes the Redis processing hash only after PostgreSQL confirms the batch was already applied or the new transaction commits.

A small plugin migration adds a `discourse_arz_tools_topic_view_batches` table with a unique batch identifier and timestamp, plus a focused Active Record model. The unique identifier makes the Redis-to-PostgreSQL handoff idempotent: a crash after the database commit but before Redis cleanup cannot apply the same batch twice. Markers are retained because there are at most 8,760 hourly markers per year and deleting a marker while a processing hash survives could permit a double increment.

New views continue accumulating in a fresh active hash while a processing batch is flushed. Fifty thousand views spread across 300 topics therefore create 300 aggregated increments rather than 50,000 Sidekiq jobs and writes.

## Failure Handling

- Redis unavailable: return `503` and do not claim that the event was accepted. Nexus may retry with backoff.
- Duplicate view: return normal HTTP 200; no job or PostgreSQL operation follows.
- Intake safety limit reached: return `429` with a retry hint. Nexus may drop analytics events rather than creating a retry storm.
- Flush mutex unavailable: exit successfully; the next hourly run retries.
- PostgreSQL batch failure: roll back topic updates and the processed-batch marker together; retain the Redis processing hash.
- Crash after PostgreSQL commit: the ledger identifies the batch as applied during retry, allowing safe Redis cleanup without a second increment.
- Nonexistent or deleted topic: the set-based update ignores it without failing the rest of the batch.
- Malformed Redis fields: log and discard only the malformed fields after applying all valid counters in the same processing batch.

Logs contain batch sizes, durations, and failures but never raw IP addresses, external user IDs, or HMAC input material. Routine successful intake requests are not logged individually.

## Settings and Operations

Add server-only settings for:

- enabling the explicit topic-view endpoint;
- the eight-hour deduplication TTL;
- the maximum endpoint requests per minute;
- the maximum topics per SQL update batch.

Add a rake task or Rails-runner-friendly service entry point to flush pending views manually during deployment verification. The README will document the Nexus request contract, responses, expected one-hour delay, settings, manual flush, and operational metrics to watch.

The existing automatic API-topic-response tracker remains independently configurable for backward compatibility. Production should disable `discourse_arz_tools_api_topic_views_enabled` after Nexus begins sending explicit view events; otherwise an upstream topic JSON cache refresh and the explicit browser event can both contribute views.

## Components

- Controller: authenticates the admin API user, validates input, and delegates intake.
- Intake service: canonicalizes identity, creates the HMAC digest, and invokes the atomic Redis script.
- Flush service/job: rotates hashes, performs idempotent bounded SQL updates, and cleans completed batches.
- Migration and focused Active Record model: store processed batch IDs in `discourse_arz_tools_topic_view_batches`.
- Scheduled job: invokes the flush hourly under a distributed mutex.
- Rake task: permits a controlled manual flush.
- Settings and locale files: expose operational controls and descriptions.
- Request, service, and job specs: verify security, identity, atomicity, batching, and recovery.

Each component has one responsibility and can be tested without invoking the full request-to-flush flow.

## Test Strategy

Request coverage:

- permits a Discourse administrator authenticated through API headers;
- rejects anonymous and non-admin users;
- accepts exactly one identity field;
- validates positive topic IDs and canonical IPv4/IPv6 addresses;
- returns distinct accepted, duplicate, rate-limited, and unavailable responses;
- performs no PostgreSQL topic query during intake.

Intake coverage:

- produces stable but non-reversible HMAC identity keys;
- separates authenticated and guest namespaces;
- counts the first identity/topic event and deduplicates the next event for eight hours;
- allows the same identity to count different topics;
- atomically increments the pending hash only for accepted events;
- applies the configured safety limit.

Flush coverage:

- combines many visitors into one increment per topic;
- preserves new intake in the active hash during processing;
- uses the configured SQL batch bound;
- ignores missing and deleted topics;
- prevents overlapping flushes;
- retains a failed processing batch;
- retries an unapplied batch;
- recognizes a committed batch after simulated post-commit failure and does not double count it;
- retains durable batch markers so delayed Redis retries remain idempotent.

Verification will create or use a compatible full Discourse checkout and run the plugin specs there, followed by Ruby syntax checks and repository diff checks.

## Out of Scope

- Browser JavaScript and the Nexus endpoint implementation.
- Direct browser-to-Discourse requests or CORS support.
- Exact unique-person analytics across login-state changes, shared guest IPs, VPNs, or mobile IP changes.
- `TopicUser` visit history and per-user read-state updates.
- Real-time visible view counts.
- Replacing Discourse's native view-count semantics outside this explicit endpoint.

## Success Criteria

- CDN-served Arzdigital idea visits can explicitly contribute to the matching Discourse topic view count.
- The same authenticated external ID or guest IP contributes at most once per topic in eight hours.
- Intake requires Nexus's admin-authenticated server-to-server request.
- Intake performs Redis work only and never enqueues per-view jobs.
- Topic view updates occur no more than hourly and are aggregated by topic.
- Flush retries cannot lose an uncommitted batch or double-apply a committed batch.
- Load is bounded by configurable intake and SQL batch limits.
