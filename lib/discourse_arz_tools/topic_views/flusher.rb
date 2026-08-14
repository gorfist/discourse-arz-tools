# frozen_string_literal: true

require "securerandom"

module ::DiscourseArzTools
  module TopicViews
    class Flusher
      PROCESSING_KEY = "#{Intake::PREFIX}:processing"
      LOCK_KEY = "#{Intake::PREFIX}:flush-lock"
      BATCH_FIELD = "__batch_id"
      LOCK_SECONDS = 1_800
      BATCH_INDEX = "idx_arz_tools_topic_view_batches_on_batch_id"

      ROTATE_SCRIPT = DiscourseRedis::EvalHelper.new <<~LUA
        if redis.call("EXISTS", KEYS[2]) == 1 then
          return redis.call("HGET", KEYS[2], ARGV[1])
        end

        if redis.call("EXISTS", KEYS[1]) == 0 then
          return nil
        end

        redis.call("RENAME", KEYS[1], KEYS[2])
        redis.call("HSET", KEYS[2], ARGV[1], ARGV[2])
        return ARGV[2]
      LUA

      RELEASE_SCRIPT = DiscourseRedis::EvalHelper.new <<~LUA
        if redis.call("GET", KEYS[1]) == ARGV[1] then
          return redis.call("DEL", KEYS[1])
        end

        return 0
      LUA

      class InvalidBatch < StandardError
      end

      class << self
        def flush!
          token = SecureRandom.hex(16)
          return :locked if !acquire_lock(token)

          started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          batch_id = nil
          discarded_count = 0

          begin
            batch_id = rotate_pending!
            return :empty if batch_id.blank?

            pairs, discarded_count = valid_pairs(Discourse.redis.hgetall(PROCESSING_KEY))
            applied = apply_once!(batch_id, pairs)
            delete_processing!
            log_completion(batch_id, pairs.length, discarded_count, started_at, applied)
            :flushed
          rescue StandardError => error
            Rails.logger.error(
              "[discourse-arz-tools] topic view flush failed " \
                "batch_id=#{batch_id || "unassigned"} error=#{error.class}",
            )
            raise
          ensure
            release_lock(token)
          end
        end

        def apply_once!(batch_id, pairs)
          applied = false

          Batch.transaction do
            inserted =
              Batch.insert_all(
                [{ batch_id: batch_id, processed_at: Time.zone.now }],
                unique_by: BATCH_INDEX,
                returning: %w[id],
              )

            if inserted.rows.any?
              apply_pairs!(pairs)
              applied = true
            end
          end

          applied
        end

        def apply_pairs!(pairs)
          pairs.each_slice(sql_batch_size) do |slice|
            values = slice.map { |topic_id, count| "(#{topic_id}, #{count})" }.join(", ")

            DB.exec(<<~SQL)
              UPDATE topics
              SET views = topics.views + increments.view_count
              FROM (VALUES #{values}) AS increments(topic_id, view_count)
              WHERE topics.id = increments.topic_id
                AND topics.deleted_at IS NULL
            SQL
          end
        end

        def delete_processing!
          Discourse.redis.del(PROCESSING_KEY)
        end

        def clear_test_keys!
          raise "test only" if !Rails.env.test?

          Discourse.redis.del(Intake::PENDING_KEY, PROCESSING_KEY, LOCK_KEY)
        end

        def install_processing_batch_for_test!(batch_id, counts)
          raise "test only" if !Rails.env.test?

          Discourse.redis.hset(PROCESSING_KEY, BATCH_FIELD, batch_id)
          counts.each do |topic_id, count|
            Discourse.redis.hset(PROCESSING_KEY, topic_id.to_s, count.to_s)
          end
        end

        private

        def acquire_lock(token)
          Discourse.redis.set(LOCK_KEY, token, nx: true, ex: LOCK_SECONDS).present?
        end

        def release_lock(token)
          RELEASE_SCRIPT.eval(Discourse.redis, namespaced_keys(LOCK_KEY), [token])
        rescue StandardError => error
          Rails.logger.error(
            "[discourse-arz-tools] topic view flush lock release failed: #{error.class}",
          )
        end

        def rotate_pending!
          batch_id =
            ROTATE_SCRIPT.eval(
              Discourse.redis,
              namespaced_keys(Intake::PENDING_KEY, PROCESSING_KEY),
              [BATCH_FIELD, SecureRandom.uuid],
            )

          if batch_id.blank? && Discourse.redis.exists?(PROCESSING_KEY)
            raise InvalidBatch, "processing batch has no identifier"
          end

          batch_id
        end

        def valid_pairs(payload)
          discarded_count = 0
          pairs =
            payload.filter_map do |raw_topic_id, raw_count|
              next if raw_topic_id == BATCH_FIELD

              topic_id = Integer(raw_topic_id, exception: false)
              count = Integer(raw_count, exception: false)

              if !topic_id || topic_id <= 0 || !count || count <= 0
                discarded_count += 1
                next
              end

              [topic_id, count]
            end

          if discarded_count.positive?
            Rails.logger.warn(
              "[discourse-arz-tools] discarded #{discarded_count} malformed topic view counters",
            )
          end

          [pairs, discarded_count]
        end

        def sql_batch_size
          SiteSetting.discourse_arz_tools_topic_view_beacon_sql_batch_size.to_i
        end

        def namespaced_keys(*keys)
          keys.map { |key| Discourse.redis.namespace_key(key) }
        end

        def log_completion(batch_id, topic_count, discarded_count, started_at, applied)
          duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
          Rails.logger.info(
            "[discourse-arz-tools] topic view flush completed " \
              "batch_id=#{batch_id} applied=#{applied} topics=#{topic_count} " \
              "discarded=#{discarded_count} duration_seconds=#{format("%.3f", duration)}",
          )
        end
      end
    end
  end
end
