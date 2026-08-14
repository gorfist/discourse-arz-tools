# frozen_string_literal: true

RSpec.describe Jobs::FlushDiscourseArzToolsTopicViews do
  before do
    SiteSetting.discourse_arz_tools_enabled = true
    SiteSetting.discourse_arz_tools_topic_view_beacon_enabled = true
    allow(::DiscourseArzTools::TopicViews::Flusher).to receive(:flush!).and_return(:empty)
  end

  it "flushes buffered views when enabled" do
    described_class.new.execute

    expect(::DiscourseArzTools::TopicViews::Flusher).to have_received(:flush!).once
  end

  it "does nothing when the beacon is disabled" do
    SiteSetting.discourse_arz_tools_topic_view_beacon_enabled = false

    described_class.new.execute

    expect(::DiscourseArzTools::TopicViews::Flusher).not_to have_received(:flush!)
  end

  it "does nothing when the plugin is disabled" do
    SiteSetting.discourse_arz_tools_enabled = false

    described_class.new.execute

    expect(::DiscourseArzTools::TopicViews::Flusher).not_to have_received(:flush!)
  end
end
