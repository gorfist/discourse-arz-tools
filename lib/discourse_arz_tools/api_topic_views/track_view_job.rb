# frozen_string_literal: true

module ::Jobs
  class DiscourseArzToolsTrackApiTopicView < ::Jobs::Base
    def execute(args)
      return if !SiteSetting.discourse_arz_tools_enabled
      return if !SiteSetting.discourse_arz_tools_api_topic_views_enabled

      topic_id = args[:topic_id].to_i
      return if topic_id <= 0

      updated =
        Topic
          .where(id: topic_id, deleted_at: nil)
          .update_all("views = views + 1")

      return if updated == 0

      track_user_visit(topic_id, args[:user_id])
    rescue StandardError => error
      Rails.logger.error(
        "[discourse-arz-tools] API topic view job failed: " \
          "#{error.class}: #{error.message}",
      )
      raise
    end

    private

    def track_user_visit(topic_id, user_id)
      return if user_id.blank?

      user = User.find_by(id: user_id)
      return if user.blank? || user.bot?

      TopicUser.track_visit!(topic_id, user.id)
    end
  end
end
