# frozen_string_literal: true

# name: discourse-arz-tools
# about: Arzdigital Discourse API tools for cached chat metrics and API topic view tracking.
# version: 0.2.0
# authors: Nima Malekpour, Discourse Community
# url: https://github.com/gorfist/discourse-arz-tools
# required_version: 3.3.0

enabled_site_setting :discourse_arz_tools_enabled

module ::DiscourseArzTools
  PLUGIN_NAME = "discourse-arz-tools"
end

after_initialize do
  require_relative "lib/discourse_arz_tools/chat_channel_message_counts/cache"
  require_relative "lib/discourse_arz_tools/api_topic_views/track_view_job"
  require_relative "lib/discourse_arz_tools/api_topic_views/request_logger"

  ::DiscourseArzTools::ApiTopicViews::RequestLogger.register!
end
