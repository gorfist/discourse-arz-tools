# frozen_string_literal: true

require "ipaddr"
require "openssl"

module ::DiscourseArzTools
  module TopicViews
    class Intake
      VERSION = "v1"
      PREFIX = "discourse_arz_tools:topic_views:#{VERSION}"
      PENDING_KEY = "#{PREFIX}:pending"

      class InvalidInput < StandardError
      end

      class Unavailable < StandardError
      end

      SCRIPT = DiscourseRedis::EvalHelper.new <<~LUA
        local requests = redis.call("INCR", KEYS[1])
        if requests == 1 then
          redis.call("EXPIRE", KEYS[1], 60)
        end

        if requests > tonumber(ARGV[1]) then
          return -1
        end

        local created = redis.call("SET", KEYS[2], "1", "NX", "EX", ARGV[2])
        if not created then
          return 0
        end

        redis.call("HINCRBY", KEYS[3], ARGV[3], 1)
        return 1
      LUA

      class << self
        def accept!(topic_id:, external_user_id: nil, ip: nil)
          id = positive_integer(topic_id)
          identity = normalized_identity(external_user_id, ip)
          digest = OpenSSL::HMAC.hexdigest("SHA256", hmac_secret, identity)

          result =
            SCRIPT.eval(
              Discourse.redis,
              [rate_key, dedupe_key(id, digest), PENDING_KEY],
              [max_requests_per_minute.to_s, dedupe_seconds.to_s, id.to_s],
            )

          { 1 => :accepted, 0 => :duplicate, -1 => :rate_limited }.fetch(result.to_i)
        rescue InvalidInput
          raise
        rescue StandardError => error
          Rails.logger.error(
            "[discourse-arz-tools] topic view intake unavailable: #{error.class}",
          )
          raise Unavailable, "topic view intake unavailable"
        end

        def clear_test_keys!
          raise "test only" if !Rails.env.test?

          keys = test_keys
          Discourse.redis.del(*keys) if keys.any?
        end

        def test_keys
          raise "test only" if !Rails.env.test?

          Discourse.redis.scan_each(match: "#{PREFIX}:*").to_a
        end

        private

        def positive_integer(value)
          id = Integer(value, exception: false)
          raise InvalidInput, "topic_id must be a positive integer" if !id || id <= 0

          id
        end

        def normalized_identity(external_user_id, ip)
          supplied_identities = [external_user_id.present?, ip.present?]
          if supplied_identities.count(true) != 1
            raise InvalidInput, "supply exactly one visitor identity"
          end

          if external_user_id.present?
            value = external_user_id.to_s
            raise InvalidInput, "external_user_id is too long" if value.bytesize > 255

            "user:#{value}"
          else
            "ip:#{IPAddr.new(ip.to_s)}"
          end
        rescue IPAddr::InvalidAddressError
          raise InvalidInput, "ip is invalid"
        end

        def hmac_secret
          Rails.application.secret_key_base
        end

        def dedupe_key(topic_id, digest)
          "#{PREFIX}:dedupe:#{topic_id}:#{digest}"
        end

        def rate_key
          "#{PREFIX}:rate:#{Time.now.to_i / 60}"
        end

        def dedupe_seconds
          SiteSetting.discourse_arz_tools_topic_view_beacon_dedupe_seconds.to_i
        end

        def max_requests_per_minute
          SiteSetting.discourse_arz_tools_topic_view_beacon_max_requests_per_minute.to_i
        end
      end
    end
  end
end
