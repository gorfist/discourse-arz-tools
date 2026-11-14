# frozen_string_literal: true

# ChannelUnreadsQuery counts standalone messages after each channel's read marker.
# Index channel + message ID together, rather than intersecting a channel index
# with a thread index for every channel in the user's membership list.
class AddArzChatUnreadMessagesIndex < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  INDEX_NAME = "arz_idx_chat_messages_channel_id_id_unthreaded"

  def up
    return unless table_exists?(:chat_messages)

    # Interrupted concurrent builds can leave an invalid index. IF NOT EXISTS
    # alone would keep that index, so remove it before retrying the build.
    invalid = DB.query_single(<<~SQL, name: INDEX_NAME).first
      SELECT 1
      FROM pg_index i
      JOIN pg_class c ON c.oid = i.indexrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'public' AND c.relname = :name AND NOT i.indisvalid
    SQL
    execute "DROP INDEX CONCURRENTLY IF EXISTS #{INDEX_NAME}" if invalid

    execute <<~SQL
      CREATE INDEX CONCURRENTLY IF NOT EXISTS #{INDEX_NAME}
      ON chat_messages USING btree (chat_channel_id, id)
      WHERE deleted_at IS NULL AND thread_id IS NULL
    SQL
  end

  def down
    execute "DROP INDEX CONCURRENTLY IF EXISTS #{INDEX_NAME}"
  end
end
