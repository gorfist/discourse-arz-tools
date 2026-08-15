# frozen_string_literal: true

RSpec.describe DiscourseArzTools::TopicViews::Flusher do
  fab!(:topic_a) { Fabricate(:topic, views: 10) }
  fab!(:topic_b) { Fabricate(:topic, views: 20) }

  before do
    SiteSetting.discourse_arz_tools_topic_view_beacon_sql_batch_size = 500
    described_class.clear_test_keys!
    ::DiscourseArzTools::TopicViews::Batch.delete_all
  end

  after { described_class.clear_test_keys! }

  def add_pending(topic_id, count)
    Discourse.redis.hset(
      ::DiscourseArzTools::TopicViews::Intake::PENDING_KEY,
      topic_id.to_s,
      count.to_s,
    )
  end

  it "applies aggregated counts and clears the processing hash" do
    add_pending(topic_a.id, 7)
    add_pending(topic_b.id, 3)

    expect(described_class.flush!).to eq(:flushed)
    expect(topic_a.reload.views).to eq(17)
    expect(topic_b.reload.views).to eq(23)
    expect(::DiscourseArzTools::TopicViews::Batch.count).to eq(1)
    expect(Discourse.redis.exists?(described_class::PROCESSING_KEY)).to eq(false)
  end

  it "ignores deleted and nonexistent topics" do
    topic_b.update!(deleted_at: Time.zone.now)
    add_pending(topic_b.id, 4)
    add_pending(99_999_999, 8)

    expect { described_class.flush! }.not_to change { topic_b.reload.views }
  end

  it "leaves new pending intake untouched while retrying a processing batch" do
    described_class.install_processing_batch_for_test!("retry-batch", topic_a.id => 2)
    add_pending(topic_b.id, 5)

    expect(described_class.flush!).to eq(:flushed)
    expect(topic_a.reload.views).to eq(12)
    expect(topic_b.reload.views).to eq(20)
    expect(
      Discourse.redis.hget(::DiscourseArzTools::TopicViews::Intake::PENDING_KEY, topic_b.id.to_s).to_i,
    ).to eq(5)
  end

  it "retains processing data when PostgreSQL fails" do
    add_pending(topic_a.id, 2)
    allow(described_class).to receive(:apply_pairs!).and_raise(ActiveRecord::StatementInvalid)

    expect { described_class.flush! }.to raise_error(ActiveRecord::StatementInvalid)
    expect(Discourse.redis.exists?(described_class::PROCESSING_KEY)).to eq(true)
    expect(::DiscourseArzTools::TopicViews::Batch.count).to eq(0)
  end

  it "does not apply a committed batch twice after Redis cleanup fails" do
    described_class.install_processing_batch_for_test!("committed-batch", topic_a.id => 4)
    allow(described_class).to receive(:delete_processing!).and_raise("redis cleanup failed")

    expect { described_class.flush! }.to raise_error("redis cleanup failed")

    allow(described_class).to receive(:delete_processing!).and_call_original
    expect(described_class.flush!).to eq(:flushed)
    expect(topic_a.reload.views).to eq(14)
  end

  it "discards malformed fields while applying valid counters" do
    described_class.install_processing_batch_for_test!(
      "mixed-batch",
      topic_a.id => 2,
      "invalid" => 3,
      topic_b.id => -1,
    )

    expect(described_class.flush!).to eq(:flushed)
    expect(topic_a.reload.views).to eq(12)
    expect(topic_b.reload.views).to eq(20)
  end

  it "bounds the number of topics in each SQL statement" do
    SiteSetting.discourse_arz_tools_topic_view_beacon_sql_batch_size = 1
    add_pending(topic_a.id, 1)
    add_pending(topic_b.id, 1)

    queries = track_sql_queries { described_class.flush! }
    sql = queries.map { |query| query.respond_to?(:sql) ? query.sql : query.to_s }

    expect(sql.grep(/UPDATE topics/i).length).to eq(2)
  end

  it "returns empty when no views are pending" do
    expect(described_class.flush!).to eq(:empty)
  end

  it "returns locked without waiting when another owner holds the lock" do
    Discourse.redis.set(described_class::LOCK_KEY, "other", ex: described_class::LOCK_SECONDS)
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    expect(described_class.flush!).to eq(:locked)
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at).to be < 0.2
  end
end
