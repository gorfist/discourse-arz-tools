# frozen_string_literal: true

# name: discourse-chat-channel-message-counts
# about: Cached API for public Discourse chat channel message counts.
# version: 0.1.0
# authors: Nima Malekpour
# url: https://github.com/gorfist/discourse-chat-channel-message-counts
# required_version: 3.3.0

enabled_site_setting :chat_channel_message_counts_enabled

module ::DiscourseChatChannelMessageCounts
  PLUGIN_NAME = "discourse-chat-channel-message-counts"
end

after_initialize do
  require_relative "lib/discourse_chat_channel_message_counts/cache"
end
