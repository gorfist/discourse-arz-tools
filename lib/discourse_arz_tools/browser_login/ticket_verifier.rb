# frozen_string_literal: true

require "base64"
require "json"
require "openssl"

module ::DiscourseArzTools
  module BrowserLogin
    class TicketVerifier
      KEY_CONTEXT = "arz-hub-browser-login-v1"
      ISSUER = "https://idp.arzdigital.com"
      AUDIENCE = "https://hub.arzdigital.com"
      HEADER = { "alg" => "HS256", "typ" => "arz-hub-login+jwt" }.freeze
      MAX_TTL = 60

      def self.verify(ticket)
        return nil unless ticket.is_a?(String) && ticket.bytesize <= 16_384
        segments = ticket.split(".", -1)
        return nil unless segments.length == 3
        header_bytes, payload_bytes, signature = segments.map { |value| decode_segment(value) }
        return nil unless signature.bytesize == 32
        secret = SiteSetting.discourse_connect_secret.to_s
        return nil if secret.empty?
        key = OpenSSL::HMAC.digest("sha256", secret, KEY_CONTEXT)
        expected = OpenSSL::HMAC.digest("sha256", key, segments.first(2).join("."))
        return nil unless OpenSSL.fixed_length_secure_compare(expected, signature)
        return nil unless JSON.parse(header_bytes) == HEADER

        claims = JSON.parse(payload_bytes)
        return nil unless claims.is_a?(Hash) && claims["iss"] == ISSUER && claims["aud"] == AUDIENCE
        issued_at, expires_at = claims.values_at("iat", "exp")
        now = Time.now.to_i
        return nil unless issued_at.is_a?(Integer) && expires_at.is_a?(Integer) &&
          issued_at <= now + 5 && expires_at > now &&
          expires_at > issued_at && expires_at - issued_at <= MAX_TTL
        identity = claims["identity"]
        return nil unless identity.is_a?(Hash) && claims["sub"].is_a?(String) &&
          !claims["sub"].empty? && identity["external_id"].to_s == claims["sub"] &&
          identity["idp_device_id"].is_a?(String) && !identity["idp_device_id"].empty?

        identity
      rescue StandardError => error
        Rails.logger.warn("[discourse-arz-tools] browser login ticket rejected: #{error.class}")
        nil
      end

      def self.decode_segment(value)
        raise ArgumentError unless value.match?(/\A[A-Za-z0-9_-]+\z/)
        bytes = Base64.urlsafe_decode64(value)
        raise ArgumentError unless Base64.urlsafe_encode64(bytes, padding: false) == value
        bytes
      end
      private_class_method :decode_segment
    end
  end
end
