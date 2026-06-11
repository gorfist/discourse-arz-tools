# frozen_string_literal: true

RSpec.describe Jobs::RefreshChatChannelMessageCounts do
  before do
    SiteSetting.chat_enabled = true
    SiteSetting.chat_channel_message_counts_enabled = true
  end

  it "refreshes the cache when enabled" do
    expect(::DiscourseChatChannelMessageCounts::Cache).to receive(:refresh_if_needed!)

    described_class.new.execute
  end

  it "does not refresh when the plugin is disabled" do
    SiteSetting.chat_channel_message_counts_enabled = false

    expect(::DiscourseChatChannelMessageCounts::Cache).not_to receive(:refresh_if_needed!)

    described_class.new.execute
  end

  it "does not refresh when chat is disabled" do
    SiteSetting.chat_enabled = false

    expect(::DiscourseChatChannelMessageCounts::Cache).not_to receive(:refresh_if_needed!)

    described_class.new.execute
  end
end
