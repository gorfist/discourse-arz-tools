# frozen_string_literal: true

RSpec.describe Chat::Api::DiscourseArzToolsChannelMessageCountsController do
  fab!(:user)

  before do
    SiteSetting.chat_enabled = true
    SiteSetting.enable_public_channels = true
    SiteSetting.chat_allowed_groups = Group::AUTO_GROUPS[:everyone]
    SiteSetting.discourse_arz_tools_enabled = true
    SiteSetting.discourse_arz_tools_chat_channel_message_counts_enabled = true
  end

  describe "#index" do
    it "rejects anonymous requests" do
      get "/chat/api/channel-message-counts.json"

      expect(response.status).to eq(403)
    end

    it "allows logged-in users" do
      sign_in(user)

      get "/chat/api/channel-message-counts.json"

      expect(response.status).to eq(200)
      expect(response.parsed_body).to include("counts", "cached_at", "cache_ttl_seconds")
    end

    it "does not refresh counts from the request path" do
      sign_in(user)

      expect(::DiscourseArzTools::ChatChannelMessageCounts::Cache).not_to receive(:refresh!)
      expect(::DiscourseArzTools::ChatChannelMessageCounts::Cache).not_to receive(
        :refresh_if_needed!,
      )

      get "/chat/api/channel-message-counts.json"
    end

    it "returns cached counts for visible public channels and excludes deleted messages" do
      public_channel = Fabricate(:category_channel)
      zero_message_channel = Fabricate(:category_channel)
      direct_message_channel = Fabricate(:direct_message_channel, users: [user])
      visible_message = Fabricate(:chat_message, chat_channel: public_channel, user:)
      deleted_message = Fabricate(:chat_message, chat_channel: public_channel, user:)
      Fabricate(:chat_message, chat_channel: direct_message_channel, user:)
      deleted_message.update!(deleted_at: Time.zone.now)

      ::DiscourseArzTools::ChatChannelMessageCounts::Cache.refresh!

      sign_in(user)
      get "/chat/api/channel-message-counts.json"

      expect(response.status).to eq(200)
      expect(response.parsed_body["counts"]).to include(
        public_channel.id.to_s => 1,
        zero_message_channel.id.to_s => 0,
      )
      expect(response.parsed_body["counts"]).not_to have_key(direct_message_channel.id.to_s)
      expect(visible_message.reload.deleted_at).to be_nil
    end

    it "excludes public channels hidden by category permissions" do
      group = Fabricate(:group)
      hidden_channel = Fabricate(:private_category_channel, group:)

      ::DiscourseArzTools::ChatChannelMessageCounts::Cache.refresh!

      sign_in(user)
      get "/chat/api/channel-message-counts.json"

      expect(response.status).to eq(200)
      expect(response.parsed_body["counts"]).not_to have_key(hidden_channel.id.to_s)
    end

    it "allows standard Discourse API key authentication" do
      api_key = Fabricate(:api_key, user:)

      get "/chat/api/channel-message-counts.json",
          headers: {
            "Api-Key" => api_key.key,
            "Api-Username" => user.username,
          }

      expect(response.status).to eq(200)
    end

    it "rate limits excessive calls" do
      RateLimiter.enable
      SiteSetting.discourse_arz_tools_chat_channel_message_counts_rate_limit_per_minute = 1
      sign_in(user)

      get "/chat/api/channel-message-counts.json"
      get "/chat/api/channel-message-counts.json"

      expect(response.status).to eq(429)
    ensure
      RateLimiter.disable
    end
  end
end
