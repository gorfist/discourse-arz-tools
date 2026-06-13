# frozen_string_literal: true

RSpec.describe Jobs::RefreshDiscourseArzToolsChatChannelMessageCounts do
  before do
    SiteSetting.chat_enabled = true
    SiteSetting.discourse_arz_tools_enabled = true
    SiteSetting.discourse_arz_tools_chat_channel_message_counts_enabled = true
  end

  it "refreshes the cache when enabled" do
    expect(::DiscourseArzTools::ChatChannelMessageCounts::Cache).to receive(:refresh_if_needed!)

    described_class.new.execute
  end

  it "does not refresh when the plugin is disabled" do
    SiteSetting.discourse_arz_tools_enabled = false

    expect(::DiscourseArzTools::ChatChannelMessageCounts::Cache).not_to receive(
      :refresh_if_needed!,
    )

    described_class.new.execute
  end

  it "does not refresh when chat is disabled" do
    SiteSetting.chat_enabled = false

    expect(::DiscourseArzTools::ChatChannelMessageCounts::Cache).not_to receive(
      :refresh_if_needed!,
    )

    described_class.new.execute
  end
end
