# frozen_string_literal: true

Chat::Engine.routes.append do
  namespace :api, defaults: { format: :json } do
    get "/channel-message-counts" => "channel_message_counts#index"
  end
end
