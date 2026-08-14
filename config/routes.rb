# frozen_string_literal: true

Discourse::Application.routes.draw do
  post "/discourse-arz-tools/topic-view" => "discourse_arz_tools_topic_views#create"
end
