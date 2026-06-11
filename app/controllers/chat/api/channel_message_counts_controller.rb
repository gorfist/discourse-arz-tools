# frozen_string_literal: true

class Chat::Api::ChannelMessageCountsController < Chat::ApiController
  before_action :ensure_logged_in
  before_action :ensure_plugin_enabled
  before_action :ensure_chat_enabled

  def index
    rate_limiter.performed!

    render json: ::DiscourseChatChannelMessageCounts::Cache.counts_for(guardian)
  end

  private

  def ensure_plugin_enabled
    return if SiteSetting.chat_channel_message_counts_enabled

    raise Discourse::InvalidAccess.new(
      nil,
      nil,
      custom_message: "chat_channel_message_counts.disabled",
    )
  end

  def ensure_chat_enabled
    return if SiteSetting.chat_enabled

    raise Discourse::InvalidAccess.new(
      nil,
      nil,
      custom_message: "chat_channel_message_counts.chat_disabled",
    )
  end

  def rate_limiter
    RateLimiter.new(
      current_user,
      "chat_channel_message_counts_api",
      SiteSetting.chat_channel_message_counts_rate_limit_per_minute.to_i,
      1.minute,
      apply_limit_to_staff: true,
    )
  end
end
