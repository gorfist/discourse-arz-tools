# frozen_string_literal: true

module ::DiscourseArzTools
  module WebviewAuth
    class RequestAuthenticator
      TOPIC_PATH = %r{\A/t/}.freeze

      class << self
        def register!
          return if @registered

          ::ApplicationController.class_eval do
            prepend_before_action :discourse_arz_tools_authenticate_webview

            private

            def discourse_arz_tools_authenticate_webview
              ::DiscourseArzTools::WebviewAuth::RequestAuthenticator.authenticate!(self)
            end
          end

          @registered = true
        rescue StandardError => error
          Rails.logger.error(
            "[discourse-arz-tools] failed to register WebView authentication: " \
              "#{error.class}: #{error.message}",
          )
        end

        def authenticate!(controller)
          return if !SiteSetting.discourse_arz_tools_enabled
          return if !SiteSetting.discourse_arz_tools_webview_auth_enabled
          return if !controller.request.get?
          return if !controller.request.path.match?(TOPIC_PATH)
          return if controller.current_user.present?

          access_token = bearer_token(controller.request.headers["Authorization"])
          return if access_token.blank?

          identity = IdpClient.new(access_token).fetch_identity
          return if identity.nil?

          user = IdentityResolver.resolve(
            identity,
            ip: controller.request.remote_ip,
            server_session: controller.server_session,
          )
          return if user.nil? || !user.active? || user.suspended?

          controller.log_on_user(user, replay_anonymous_action: true)
        rescue StandardError => error
          Rails.logger.warn(
            "[discourse-arz-tools] WebView authentication failed: #{error.class}",
          )
        end

        private

        def bearer_token(authorization)
          match = authorization.to_s.match(/\ABearer\s+(.+)\z/)
          match && match[1].strip.presence
        end
      end
    end
  end
end
