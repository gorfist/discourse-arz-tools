# Discourse Chat Channel Message Counts

Backend-only Discourse plugin that exposes cached message counts for public chat channels.

The endpoint is designed for overloaded Discourse instances: regular API requests never run the grouped `COUNT(*)` query. A scheduled job refreshes a global cache every 12 hours, and requests only filter the cached map down to public chat channels visible to the authenticated user.

## Endpoint

```http
GET /chat/api/channel-message-counts.json
```

The endpoint requires a logged-in Discourse user. Browser sessions work, and external clients can use the normal Discourse API headers:

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

## Load Safety

- API requests only read cache and resolve visible public chat channels.
- The heavy grouped count query runs only from `Jobs::RefreshChatChannelMessageCounts`.
- Counts are cached under a fresh key for at least 12 hours.
- A stale fallback key is retained for 7 days by default.
- A distributed mutex prevents concurrent refresh jobs from running the count query together.
- Per-user rate limiting is enabled for the endpoint.
- Direct messages and group direct messages are never returned.

Until the first scheduled refresh completes, the endpoint returns an empty `counts` map with `cached_at: null` rather than pretending every channel has zero messages. To prefill the cache deliberately during a quiet window, run this from the Discourse root:

```sh
RAILS_ENV=production bundle exec rails runner 'Jobs::RefreshChatChannelMessageCounts.new.execute'
```

## Settings

- `chat_channel_message_counts_enabled`: enable or disable the plugin.
- `chat_channel_message_counts_cache_ttl_seconds`: fresh cache TTL. Default `43200`, minimum `43200`.
- `chat_channel_message_counts_stale_ttl_seconds`: stale fallback cache TTL. Default `604800`.
- `chat_channel_message_counts_rate_limit_per_minute`: per-user endpoint limit. Default `30`.

## Recommended Index

For large `chat_messages` tables, check the recommended partial index before enabling the scheduled job:

```sh
rake chat_channel_message_counts:check_index
```

If it is missing, create it during a quiet maintenance window:

```sh
rake chat_channel_message_counts:create_index
```

The task uses:

```sql
CREATE INDEX CONCURRENTLY IF NOT EXISTS index_chat_messages_channel_id_not_deleted
ON chat_messages (chat_channel_id)
WHERE deleted_at IS NULL;
```

## Local Testing

This standalone plugin repo can be syntax-checked locally, but request specs need to run from a full Discourse checkout with this plugin installed.

From the Discourse root:

```sh
LOAD_PLUGINS=1 bundle exec rspec plugins/discourse-chat-channel-message-counts/spec
```
