# frozen_string_literal: true

# name: discourse-arz-tools
# about: Arzdigital Discourse API tools for cached chat metrics and API topic view tracking.
# version: 0.3.0
# authors: Nima Malekpour, Discourse Community
# url: https://github.com/gorfist/discourse-arz-tools
# required_version: 3.3.0

enabled_site_setting :discourse_arz_tools_enabled

module ::DiscourseArzTools
  PLUGIN_NAME = "discourse-arz-tools"
end

after_initialize do
  require_relative "app/controllers/discourse_arz_tools_topic_views_controller"

  Discourse::Application.routes.append do
    post "/discourse-arz-tools/topic-view" => "discourse_arz_tools_topic_views#create"
  end

  if defined?(::Chat::Engine)
    require_relative "app/controllers/chat/api/discourse_arz_tools_channel_message_counts_controller"

    ::Chat::Engine.routes.append do
      namespace :api, defaults: { format: :json } do
        get "/channel-message-counts" => "discourse_arz_tools_channel_message_counts#index"
      end
    end
  else
    Rails.logger.warn(
      "[discourse-arz-tools] chat engine is unavailable; " \
        "chat channel message counts endpoint was not registered",
    )
  end

  require_relative "app/jobs/scheduled/refresh_discourse_arz_tools_chat_channel_message_counts"
  require_relative "lib/discourse_arz_tools/chat_channel_message_counts/cache"
  require_relative "lib/discourse_arz_tools/api_topic_views/track_view_job"
  require_relative "lib/discourse_arz_tools/api_topic_views/request_logger"
  require_relative "lib/discourse_arz_tools/topic_views/intake"
  require_relative "app/models/discourse_arz_tools/topic_views/batch"
  require_relative "lib/discourse_arz_tools/topic_views/flusher"
  require_relative "app/jobs/scheduled/flush_discourse_arz_tools_topic_views"

  ::DiscourseArzTools::ApiTopicViews::RequestLogger.register!
end
