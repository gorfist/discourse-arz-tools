# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "uri"

module ::DiscourseArzTools
  module WebviewAuth
    class IdpClient
      def initialize(access_token)
        @access_token = access_token
      end

      def fetch_identity
        endpoint = SiteSetting.discourse_arz_tools_webview_auth_idp_url.to_s
        secret = SiteSetting.discourse_connect_secret.to_s
        return nil if endpoint.blank? || secret.blank? || @access_token.blank?

        uri = URI.parse(endpoint)
        return nil unless uri.is_a?(URI::HTTPS)

        request = Net::HTTP::Get.new(uri)
        request["Authorization"] = "Bearer #{@access_token}"
        request["X-Hub-Signature"] = OpenSSL::HMAC.hexdigest("sha256", secret, @access_token)

        timeout = SiteSetting.discourse_arz_tools_webview_auth_timeout_seconds.to_i
        http = Net::HTTP.new(uri.host, uri.port, :ENV)
        http.use_ssl = true
        http.open_timeout = timeout
        http.read_timeout = timeout

        response = http.request(request)
        return nil unless response.is_a?(Net::HTTPSuccess)

        payload = JSON.parse(response.body)
        return nil unless payload["status"] == "success" && payload["data"].is_a?(Hash)

        payload["data"]
      rescue URI::InvalidURIError, JSON::ParserError, Net::OpenTimeout, Net::ReadTimeout,
             OpenSSL::SSL::SSLError, SocketError => error
        Rails.logger.warn(
          "[discourse-arz-tools] WebView IDP request failed: #{error.class}",
        )
        nil
      end
    end
  end
end
