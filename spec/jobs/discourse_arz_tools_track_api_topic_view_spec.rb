# frozen_string_literal: true

RSpec.describe Jobs::DiscourseArzToolsTrackApiTopicView do
  fab!(:topic)
  fab!(:user)

  before do
    SiteSetting.discourse_arz_tools_enabled = true
    SiteSetting.discourse_arz_tools_api_topic_views_enabled = true
  end

  describe "#execute" do
    it "increments topic view count without loading and re-saving the topic" do
      expect {
        described_class.new.execute(topic_id: topic.id, user_id: nil)
      }.to change { topic.reload.views }.by(1)
    end

    it "tracks user visit when user is present" do
      expect {
        described_class.new.execute(topic_id: topic.id, user_id: user.id)
      }.to change { TopicUser.where(topic_id: topic.id, user_id: user.id).count }.by(1)
    end

    it "does not increment deleted topics" do
      topic.update!(deleted_at: Time.zone.now)

      expect {
        described_class.new.execute(topic_id: topic.id, user_id: nil)
      }.not_to change { topic.reload.views }
    end

    it "handles missing parameters gracefully" do
      expect { described_class.new.execute({}) }.not_to raise_error
    end

    it "does not track when the feature is disabled" do
      SiteSetting.discourse_arz_tools_api_topic_views_enabled = false

      expect {
        described_class.new.execute(topic_id: topic.id, user_id: nil)
      }.not_to change { topic.reload.views }
    end
  end
end
