# frozen_string_literal: true

RSpec.describe DiscourseArzTools::ChatChannelMessageCounts::Cache do
  fab!(:user)

  before do
    SiteSetting.chat_enabled = true
    SiteSetting.enable_public_channels = true
    SiteSetting.chat_allowed_groups = Group::AUTO_GROUPS[:everyone]
    SiteSetting.discourse_arz_tools_enabled = true
    SiteSetting.discourse_arz_tools_chat_channel_message_counts_enabled = true
    described_class.clear!
  end

  after { described_class.clear! }

  describe ".refresh!" do
    it "stores counts for non-deleted messages only" do
      channel = Fabricate(:category_channel)
      Fabricate(:chat_message, chat_channel: channel, user:)
      deleted_message = Fabricate(:chat_message, chat_channel: channel, user:)
      deleted_message.update!(deleted_at: Time.zone.now)

      payload = described_class.refresh!

      expect(payload[:counts][channel.id.to_s]).to eq(1)
      expect(payload[:cached_at]).to be_present
    end

    it "serves stale cached data when refresh fails" do
      channel = Fabricate(:category_channel)
      Fabricate(:chat_message, chat_channel: channel, user:)
      stale_payload = described_class.refresh!

      described_class::FRESH_CACHE_KEY.tap { |key| Discourse.cache.delete(key) }
      allow(DB).to receive(:query).and_raise(PG::Error.new("boom"))

      expect(described_class.refresh!).to eq(stale_payload)
    end
  end

  describe ".refresh_if_needed!" do
    it "does not rebuild counts when the fresh cache exists" do
      described_class.refresh!

      expect(DB).not_to receive(:query)

      described_class.refresh_if_needed!
    end
  end

  describe ".counts_for" do
    it "returns zero for visible public channels missing from the cached count map" do
      channel = Fabricate(:category_channel)
      Discourse.cache.write(
        described_class::FRESH_CACHE_KEY,
        { counts: {}, cached_at: Time.zone.now.iso8601 },
        expires_in: 12.hours,
      )

      result = described_class.counts_for(Guardian.new(user))

      expect(result[:counts]).to include(channel.id.to_s => 0)
    end
  end
end
