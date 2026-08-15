# frozen_string_literal: true

module Jobs
  class FlushDiscourseArzToolsTopicViews < ::Jobs::Scheduled
    every 1.hour

    def execute(args = nil)
      return if !SiteSetting.discourse_arz_tools_enabled
      return if !SiteSetting.discourse_arz_tools_topic_view_beacon_enabled

      ::DiscourseArzTools::TopicViews::Flusher.flush!
    end
  end
end
