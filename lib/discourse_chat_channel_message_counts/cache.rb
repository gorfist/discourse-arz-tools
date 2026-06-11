# frozen_string_literal: true

module ::DiscourseChatChannelMessageCounts
  class Cache
    CACHE_VERSION = "v1"
    FRESH_CACHE_KEY = "discourse_chat_channel_message_counts:#{CACHE_VERSION}:fresh"
    STALE_CACHE_KEY = "discourse_chat_channel_message_counts:#{CACHE_VERSION}:stale"
    LOCK_KEY = "discourse_chat_channel_message_counts:#{CACHE_VERSION}:refresh"

    class << self
      def counts_for(guardian)
        payload = read_payload
        return empty_response if payload[:cached_at].blank?

        counts = payload[:counts]

        {
          counts:
            visible_public_channel_ids(guardian).each_with_object({}) do |channel_id, result|
              key = channel_id.to_s
              result[key] = counts.fetch(key, 0).to_i
            end,
          cached_at: payload[:cached_at],
          cache_ttl_seconds: cache_ttl_seconds,
        }
      end

      def refresh_if_needed!
        DistributedMutex.synchronize(LOCK_KEY, validity: 30.minutes) do
          return read_payload if fresh_payload.present?

          refresh!
        end
      end

      def refresh!
        payload = build_payload
        Discourse.cache.write(FRESH_CACHE_KEY, payload, expires_in: cache_ttl_seconds.seconds)
        Discourse.cache.write(STALE_CACHE_KEY, payload, expires_in: stale_ttl_seconds.seconds)
        payload
      rescue StandardError => error
        Rails.logger.error(
          "[discourse-chat-channel-message-counts] failed to refresh counts: " \
            "#{error.class}: #{error.message}",
        )
        read_payload
      end

      def clear!
        Discourse.cache.delete(FRESH_CACHE_KEY)
        Discourse.cache.delete(STALE_CACHE_KEY)
      end

      def recommended_index_exists?
        DB.query_single(<<~SQL).any?
          SELECT 1
          FROM pg_indexes
          WHERE schemaname = ANY(current_schemas(false))
            AND tablename = 'chat_messages'
            AND indexdef ILIKE '%chat_channel_id%'
            AND indexdef ILIKE '%deleted_at IS NULL%'
        SQL
      end

      def create_recommended_index!
        DB.exec(<<~SQL)
          CREATE INDEX CONCURRENTLY IF NOT EXISTS index_chat_messages_channel_id_not_deleted
          ON chat_messages (chat_channel_id)
          WHERE deleted_at IS NULL
        SQL
      end

      private

      def build_payload
        rows = DB.query(<<~SQL)
          SELECT chat_channel_id, COUNT(*)::bigint AS message_count
          FROM chat_messages
          WHERE deleted_at IS NULL
          GROUP BY chat_channel_id
        SQL

        {
          counts:
            rows.each_with_object({}) do |row, result|
              result[row.chat_channel_id.to_s] = row.message_count.to_i
            end,
          cached_at: Time.zone.now.iso8601,
        }
      end

      def read_payload
        fresh_payload || stale_payload || empty_payload
      end

      def fresh_payload
        normalize_payload(Discourse.cache.read(FRESH_CACHE_KEY))
      end

      def stale_payload
        normalize_payload(Discourse.cache.read(STALE_CACHE_KEY))
      end

      def empty_payload
        { counts: {}, cached_at: nil }
      end

      def empty_response
        empty_payload.merge(cache_ttl_seconds: cache_ttl_seconds)
      end

      def normalize_payload(payload)
        return if payload.blank?

        counts = payload[:counts] || payload["counts"] || {}
        cached_at = payload[:cached_at] || payload["cached_at"]

        { counts: counts.transform_keys(&:to_s), cached_at: cached_at }
      end

      def visible_public_channel_ids(guardian)
        return [] if !SiteSetting.enable_public_channels

        allowed_channel_ids_sql =
          ::Chat::ChannelFetcher.generate_allowed_channel_ids_sql(
            guardian,
            exclude_dm_channels: true,
          )

        ::Chat::Channel
          .public_channels
          .where("chat_channels.id IN (#{allowed_channel_ids_sql})")
          .where("chat_channels.deleted_at IS NULL")
          .pluck(:id)
      end

      def cache_ttl_seconds
        SiteSetting.chat_channel_message_counts_cache_ttl_seconds.to_i
      end

      def stale_ttl_seconds
        [
          SiteSetting.chat_channel_message_counts_stale_ttl_seconds.to_i,
          cache_ttl_seconds,
        ].max
      end
    end
  end
end
