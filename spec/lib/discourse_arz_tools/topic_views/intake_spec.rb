# frozen_string_literal: true

RSpec.describe DiscourseArzTools::TopicViews::Intake do
  before do
    SiteSetting.discourse_arz_tools_topic_view_beacon_enabled = true
    SiteSetting.discourse_arz_tools_topic_view_beacon_dedupe_seconds = 28_800
    SiteSetting.discourse_arz_tools_topic_view_beacon_max_requests_per_minute = 6_000
    described_class.clear_test_keys!
  end

  after { described_class.clear_test_keys! }

  it "accepts the first user and topic pair and deduplicates the second" do
    expect(described_class.accept!(topic_id: 202_277, external_user_id: "11222")).to eq(:accepted)
    expect(described_class.accept!(topic_id: 202_277, external_user_id: "11222")).to eq(:duplicate)

    expect(Discourse.redis.hget(described_class::PENDING_KEY, "202277").to_i).to eq(1)
  end

  it "canonicalizes guest IP addresses before deduplication" do
    expect(described_class.accept!(topic_id: 9, ip: "2001:0db8::1")).to eq(:accepted)
    expect(described_class.accept!(topic_id: 9, ip: "2001:db8:0:0:0:0:0:1")).to eq(:duplicate)
  end

  it "keeps authenticated and guest identities separate" do
    expect(described_class.accept!(topic_id: 9, external_user_id: "203.0.113.5")).to eq(:accepted)
    expect(described_class.accept!(topic_id: 9, ip: "203.0.113.5")).to eq(:accepted)
  end

  it "allows the same identity to count different topics" do
    expect(described_class.accept!(topic_id: 9, external_user_id: "11222")).to eq(:accepted)
    expect(described_class.accept!(topic_id: 10, external_user_id: "11222")).to eq(:accepted)
  end

  it "does not expose raw identity values in Redis keys" do
    described_class.accept!(topic_id: 9, external_user_id: "private-user-id")

    expect(described_class.test_keys.join(" ")).not_to include("private-user-id")
  end

  it "rejects invalid topic and identity input" do
    expect { described_class.accept!(topic_id: 0, ip: "203.0.113.5") }.to raise_error(
      described_class::InvalidInput,
    )
    expect { described_class.accept!(topic_id: 9) }.to raise_error(described_class::InvalidInput)
    expect {
      described_class.accept!(topic_id: 9, ip: "203.0.113.5", external_user_id: "1")
    }.to raise_error(described_class::InvalidInput)
    expect { described_class.accept!(topic_id: 9, ip: "not-an-ip") }.to raise_error(
      described_class::InvalidInput,
    )
    expect {
      described_class.accept!(topic_id: 9, external_user_id: "x" * 256)
    }.to raise_error(described_class::InvalidInput)
  end

  it "rate limits before adding another pending view" do
    SiteSetting.discourse_arz_tools_topic_view_beacon_max_requests_per_minute = 1

    expect(described_class.accept!(topic_id: 1, ip: "192.0.2.1")).to eq(:accepted)
    expect(described_class.accept!(topic_id: 2, ip: "192.0.2.2")).to eq(:rate_limited)
    expect(Discourse.redis.hget(described_class::PENDING_KEY, "2")).to be_nil
  end

  it "wraps Redis failures as unavailable" do
    allow(described_class::SCRIPT).to receive(:eval).and_raise("redis down")

    expect { described_class.accept!(topic_id: 1, ip: "192.0.2.1") }.to raise_error(
      described_class::Unavailable,
    )
  end
end
