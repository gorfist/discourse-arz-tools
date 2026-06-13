# frozen_string_literal: true

RSpec.describe DiscourseArzTools::ApiTopicViews::RequestLogger do
  fab!(:topic)
  fab!(:user)

  let(:headers) { {} }
  let(:env) { { "HTTP_API_KEY" => "key", "HTTP_API_USERNAME" => user.username } }
  let(:request) { double("request", env: env, headers: headers, remote_ip: "192.0.2.1") }
  let(:response) { double("response", status: 200) }
  let(:controller) do
    double(
      "controller",
      request: request,
      response: response,
      params: { topic_id: topic.id },
      current_user: user,
    )
  end

  before do
    SiteSetting.discourse_arz_tools_enabled = true
    SiteSetting.discourse_arz_tools_api_topic_views_enabled = true
    SiteSetting.discourse_arz_tools_api_topic_views_require_header = ""
    SiteSetting.discourse_arz_tools_api_topic_views_max_per_minute_per_ip = 0
  end

  describe ".track!" do
    it "enqueues API topic view tracking for eligible API topic responses" do
      expect {
        described_class.track!(controller)
      }.to change { Jobs::DiscourseArzToolsTrackApiTopicView.jobs.size }.by(1)
    end

    it "skips non-200 responses" do
      allow(response).to receive(:status).and_return(404)

      expect {
        described_class.track!(controller)
      }.not_to change { Jobs::DiscourseArzToolsTrackApiTopicView.jobs.size }
    end

    it "skips non-API requests" do
      env.clear

      expect {
        described_class.track!(controller)
      }.not_to change { Jobs::DiscourseArzToolsTrackApiTopicView.jobs.size }
    end

    it "honors the optional required header" do
      SiteSetting.discourse_arz_tools_api_topic_views_require_header = "X-Count-As-View"

      expect {
        described_class.track!(controller)
      }.not_to change { Jobs::DiscourseArzToolsTrackApiTopicView.jobs.size }

      headers["X-Count-As-View"] = "true"
      expect {
        described_class.track!(controller)
      }.to change { Jobs::DiscourseArzToolsTrackApiTopicView.jobs.size }.by(1)
    end

    it "rate limits before enqueueing jobs" do
      SiteSetting.discourse_arz_tools_api_topic_views_max_per_minute_per_ip = 1
      Discourse.redis.del(described_class.rate_limit_key(topic.id, "192.0.2.1"))

      expect {
        described_class.track!(controller)
        described_class.track!(controller)
      }.to change { Jobs::DiscourseArzToolsTrackApiTopicView.jobs.size }.by(1)
    end
  end
end
