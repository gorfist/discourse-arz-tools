# frozen_string_literal: true

module Jobs
  class RefreshChatChannelMessageCounts < ::Jobs::Scheduled
    every 12.hours

    def execute(args = nil)
      return if !SiteSetting.chat_channel_message_counts_enabled
      return if !SiteSetting.chat_enabled

      ::DiscourseChatChannelMessageCounts::Cache.refresh_if_needed!
    end
  end
end
