# frozen_string_literal: true

module ::DiscourseArzTools
  module WebviewAuth
    class IdentityResolver
      REQUIRED_FIELDS = %w[external_id email username name].freeze

      def self.resolve(identity, ip:, server_session:)
        return nil unless identity.is_a?(Hash)
        return nil unless REQUIRED_FIELDS.all? { |field| identity[field].to_s.present? }

        sso = DiscourseConnect.new(server_session: server_session)
        sso.external_id = identity["external_id"].to_s
        sso.email = identity["email"].to_s
        sso.username = identity["username"].to_s
        sso.name = identity["name"].to_s
        sso.avatar_url = identity["avatar_url"].to_s.presence
        sso.website = identity["website"].to_s.presence
        sso.avatar_force_update = identity["avatar_force_update"] == true
        sso.suppress_welcome_message = identity["suppress_welcome_message"] == true
        sso.add_groups = group_names(identity["add_groups"])
        sso.remove_groups = group_names(identity["remove_groups"])

        sso.lookup_or_create_user(ip)
      end

      def self.group_names(groups)
        Array(groups).filter_map { |group| group.to_s.strip.presence }.join(",")
      end
      private_class_method :group_names
    end
  end
end
