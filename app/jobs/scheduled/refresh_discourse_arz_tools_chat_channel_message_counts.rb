# frozen_string_literal: true

module Jobs
  class RefreshDiscourseArzToolsChatChannelMessageCounts < ::Jobs::Scheduled
    every 12.hours

    def execute(args = nil)
      return if !SiteSetting.discourse_arz_tools_enabled
      return if !SiteSetting.discourse_arz_tools_chat_channel_message_counts_enabled
      return if !SiteSetting.chat_enabled

      ::DiscourseArzTools::ChatChannelMessageCounts::Cache.refresh_if_needed!
    end
  end
end
