# frozen_string_literal: true

RSpec.describe DiscourseArzToolsTopicViewsController do
  fab!(:admin)
  fab!(:user)
  fab!(:admin_api_key, refind: false) { Fabricate(:api_key, user: admin) }
  fab!(:user_api_key, refind: false) { Fabricate(:api_key, user: user) }

  let(:path) { "/discourse-arz-tools/topic-view.json" }

  before do
    SiteSetting.discourse_arz_tools_enabled = true
    SiteSetting.discourse_arz_tools_topic_view_beacon_enabled = true
    SiteSetting.discourse_arz_tools_topic_view_beacon_dedupe_seconds = 28_800
    SiteSetting.discourse_arz_tools_topic_view_beacon_max_requests_per_minute = 6_000
    ::DiscourseArzTools::TopicViews::Intake.clear_test_keys!
  end

  after { ::DiscourseArzTools::TopicViews::Intake.clear_test_keys! }

  def api_headers(api_key, username)
    { "HTTP_API_KEY" => api_key.key, "HTTP_API_USERNAME" => username }
  end

  it "buffers an authenticated visitor view for an admin API request" do
    allow(::DiscourseArzTools::TopicViews::Intake).to receive(:accept!).and_return(:accepted)

    queries =
      track_sql_queries do
        post path,
             params: { topic_id: 202_277, external_user_id: "11222" },
             headers: api_headers(admin_api_key, admin.username)
      end

    expect(response.status).to eq(200)
    expect(response.parsed_body).to eq("counted" => true, "buffered" => true)
    expect(::DiscourseArzTools::TopicViews::Intake).to have_received(:accept!).with(
      topic_id: "202277",
      external_user_id: "11222",
      ip: nil,
    )
    sql = queries.map { |query| query.respond_to?(:sql) ? query.sql : query.to_s }
    expect(sql.grep(/FROM\s+"?topics"?/i)).to be_empty
  end

  it "returns a normal duplicate response" do
    allow(::DiscourseArzTools::TopicViews::Intake).to receive(:accept!).and_return(:duplicate)

    post path,
         params: { topic_id: 1, ip: "192.0.2.1" },
         headers: api_headers(admin_api_key, admin.username)

    expect(response.status).to eq(200)
    expect(response.parsed_body).to eq("counted" => false, "reason" => "duplicate")
  end

  it "integrates admin authentication, Redis buffering, and deduplication" do
    headers = api_headers(admin_api_key, admin.username)
    params = { topic_id: 202_277, ip: "192.0.2.10" }

    post path, params: params, headers: headers
    expect(response.parsed_body).to eq("counted" => true, "buffered" => true)

    post path, params: params, headers: headers
    expect(response.parsed_body).to eq("counted" => false, "reason" => "duplicate")
    expect(
      Discourse.redis.hget(::DiscourseArzTools::TopicViews::Intake::PENDING_KEY, "202277").to_i,
    ).to eq(1)
  end

  it "rejects an admin browser session without API authentication" do
    sign_in(admin)

    post path,
         params: { topic_id: 1, ip: "192.0.2.1" },
         headers: { "HTTP_X_REQUESTED_WITH" => "XMLHttpRequest" }

    expect(response.status).to eq(403)
  end

  it "rejects a non-admin API user" do
    post path,
         params: { topic_id: 1, ip: "192.0.2.1" },
         headers: api_headers(user_api_key, user.username)

    expect(response.status).to eq(403)
  end

  it "returns validation errors" do
    post path,
         params: { topic_id: 0, ip: "bad" },
         headers: api_headers(admin_api_key, admin.username)

    expect(response.status).to eq(422)
  end

  it "returns a retry hint when rate limited" do
    allow(::DiscourseArzTools::TopicViews::Intake).to receive(:accept!).and_return(:rate_limited)

    post path,
         params: { topic_id: 1, ip: "192.0.2.1" },
         headers: api_headers(admin_api_key, admin.username)

    expect(response.status).to eq(429)
    expect(response.headers["Retry-After"]).to eq("60")
  end

  it "returns service unavailable when Redis intake fails" do
    allow(::DiscourseArzTools::TopicViews::Intake).to receive(:accept!).and_raise(
      ::DiscourseArzTools::TopicViews::Intake::Unavailable,
    )

    post path,
         params: { topic_id: 1, ip: "192.0.2.1" },
         headers: api_headers(admin_api_key, admin.username)

    expect(response.status).to eq(503)
  end

  it "is unavailable when the feature setting is disabled" do
    SiteSetting.discourse_arz_tools_topic_view_beacon_enabled = false

    post path,
         params: { topic_id: 1, ip: "192.0.2.1" },
         headers: api_headers(admin_api_key, admin.username)

    expect(response.status).to eq(403)
  end
end
