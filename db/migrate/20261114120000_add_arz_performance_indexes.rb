# frozen_string_literal: true

# Indexes that Discourse core does not ship but our data volume needs.
#
# - user_chat_channel_memberships: every existing index starts with user_id, so
#   chat notifier lookups by chat_channel_id seq-scan ~4M rows on each message.
# - topic_embeds: core looks up topic_embeds by topic_id on every topic/post
#   view, but only embed_url is indexed.
#
# Names use an "arz_" prefix so they can never clash with a future core index.
class AddArzPerformanceIndexes < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  INDEXES = [
    {
      name: "arz_idx_uccm_on_chat_channel_id",
      table: "user_chat_channel_memberships",
      column: "chat_channel_id",
    },
    { name: "arz_idx_topic_embeds_on_topic_id", table: "topic_embeds", column: "topic_id" },
  ].freeze

  def up
    INDEXES.each do |index|
      next unless table_exists?(index[:table])

      # A failed CONCURRENTLY build leaves an INVALID index that IF NOT EXISTS
      # would silently keep, so drop it first and rebuild.
      invalid = DB.query_single(<<~SQL, name: index[:name]).first
        SELECT 1
        FROM pg_index i
        JOIN pg_class c ON c.oid = i.indexrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public' AND c.relname = :name AND NOT i.indisvalid
      SQL
      execute "DROP INDEX CONCURRENTLY IF EXISTS #{index[:name]}" if invalid

      execute <<~SQL
        CREATE INDEX CONCURRENTLY IF NOT EXISTS #{index[:name]}
        ON #{index[:table]} USING btree (#{index[:column]})
      SQL
    end
  end

  def down
    INDEXES.each { |index| execute "DROP INDEX CONCURRENTLY IF EXISTS #{index[:name]}" }
  end
end
