# frozen_string_literal: true

require "digest"

module ::DiscourseArzTools
  module ApiTopicViews
    class RequestLogger
      CACHE_VERSION = "v1"

      class << self
        def register!
          return if @registered

          ::TopicsController.class_eval do
            after_action :discourse_arz_tools_track_api_topic_view, only: [:show]

            private

            def discourse_arz_tools_track_api_topic_view
              ::DiscourseArzTools::ApiTopicViews::RequestLogger.track!(self)
            end
          end

          @registered = true
        rescue StandardError => error
          Rails.logger.error(
            "[discourse-arz-tools] failed to register API topic view tracking: " \
              "#{error.class}: #{error.message}",
          )
        end

        def track!(controller)
          return if !SiteSetting.discourse_arz_tools_enabled
          return if !SiteSetting.discourse_arz_tools_api_topic_views_enabled
          return if controller.response.status != 200
          return if !api_request?(controller)
          return if bot_user?(controller.current_user)

          topic_id = extract_topic_id(controller)
          return if topic_id <= 0
          return if !required_header_present?(controller)

          ip = controller.request.remote_ip
          return if ip.blank?
          return if rate_limited?(topic_id, ip)

          ::Jobs.enqueue(
            :discourse_arz_tools_track_api_topic_view,
            topic_id: topic_id,
            ip: ip,
            user_id: controller.current_user&.id,
          )

          debug_log("enqueued API topic view for topic #{topic_id}")
        rescue StandardError => error
          Rails.logger.error(
            "[discourse-arz-tools] API topic view tracking failed: " \
              "#{error.class}: #{error.message}",
          )
        end

        def api_request?(controller)
          request = controller.request
          params = controller.params

          request.env["HTTP_API_KEY"].present? ||
            request.env["HTTP_API_USERNAME"].present? ||
            request.env["DISCOURSE_API_KEY"].present? ||
            request.env["HTTP_USER_API_KEY"].present? ||
            request.env["USER_API_KEY"].present? ||
            request.headers["Api-Key"].present? ||
            request.headers["Api-Username"].present? ||
            request.headers["User-Api-Key"].present? ||
            params[:api_key].present? ||
            params[:api_username].present?
        end

        def extract_topic_id(controller)
          topic_id = controller.instance_variable_get(:@topic)&.id
          topic_id ||= controller.params[:topic_id]
          topic_id ||= controller.params[:id]
          topic_id.to_i
        end

        def required_header_present?(controller)
          required_header =
            SiteSetting.discourse_arz_tools_api_topic_views_require_header.to_s.strip
          return true if required_header.blank?

          controller.request.headers[required_header].present?
        end

        def rate_limited?(topic_id, ip)
          max_per_minute =
            SiteSetting.discourse_arz_tools_api_topic_views_max_per_minute_per_ip.to_i
          return false if max_per_minute <= 0

          key = rate_limit_key(topic_id, ip)
          count = Discourse.redis.incr(key)
          Discourse.redis.expire(key, 60) if count == 1

          count > max_per_minute
        end

        def rate_limit_key(topic_id, ip)
          digest = Digest::SHA256.hexdigest("#{ip}:#{topic_id}")
          "discourse_arz_tools:api_topic_views:#{CACHE_VERSION}:rate_limit:#{digest}"
        end

        private

        def bot_user?(user)
          user&.bot?
        end

        def debug_log(message)
          return if ENV["DISCOURSE_ARZ_TOOLS_DEBUG"] != "true" && !Rails.env.development?

          Rails.logger.info("[discourse-arz-tools] #{message}")
        end
      end
    end
  end
end
