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

## Settings

- `discourse_arz_tools_enabled`: master switch for the plugin.
- `discourse_arz_tools_chat_channel_message_counts_enabled`: enable or disable the cached chat channel message counts API.
- `discourse_arz_tools_chat_channel_message_counts_cache_ttl_seconds`: fresh chat count cache TTL. Default `43200`, minimum `43200`.
- `discourse_arz_tools_chat_channel_message_counts_stale_ttl_seconds`: stale chat count fallback cache TTL. Default `604800`.
- `discourse_arz_tools_chat_channel_message_counts_rate_limit_per_minute`: per-user chat count endpoint limit. Default `30`.
- `discourse_arz_tools_api_topic_views_enabled`: enable API topic view tracking.
- `discourse_arz_tools_api_topic_views_require_header`: optional header required before API topic views are counted.
- `discourse_arz_tools_api_topic_views_max_per_minute_per_ip`: maximum API topic views per minute for one IP and topic. Default `0`, disabled.

## Local Testing

This standalone plugin repo can be syntax-checked locally, but request specs need to run from a full Discourse checkout with this plugin installed.

From the Discourse root:

```sh
LOAD_PLUGINS=1 bundle exec rspec plugins/discourse-arz-tools/spec
```
