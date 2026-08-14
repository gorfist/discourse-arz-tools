# Batched Topic View Beacon Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox ('- [ ]') syntax for tracking.

**Goal:** Add an admin-authenticated topic-view intake endpoint that deduplicates visitors for eight hours in Redis and applies aggregated topic view increments to PostgreSQL once per hour.

**Architecture:** Nexus submits one authenticated event per visible idea page. A Lua-backed intake service validates and atomically rate-limits, deduplicates, and aggregates events without touching PostgreSQL; an idempotent hourly flusher rotates the Redis hash and applies bounded set-based SQL updates using a PostgreSQL batch ledger.

**Tech Stack:** Discourse 3.3+, Ruby, Rails/Active Record, PostgreSQL, Discourse Redis and DiscourseRedis::EvalHelper, RSpec, Sidekiq scheduled jobs, Rake.

## Global Constraints

- Only Nexus calls Discourse; the browser never receives a Discourse credential.
- Require a Discourse admin API request; an admin browser session is insufficient.
- Accept a positive topic_id and exactly one of external_user_id or ip.
- Limit external_user_id to 255 bytes and canonicalize guest addresses with IPAddr.
- Never store or log raw external user IDs or IP addresses.
- Deduplicate each visitor/topic pair for 28,800 seconds by default.
- Intake is Redis-only: no topic load, per-view job, TopicUser call, or PostgreSQL write.
- Flush at most hourly in SQL groups of 500 topics by default.
- Enforce a configurable global ceiling of 6,000 intake requests per minute.
- Keep the existing automatic API topic-view tracker independently configurable.
- A committed Redis batch must never be applied twice.

---

### Task 1: Atomic Redis Intake

**Files:**
- Create: lib/discourse_arz_tools/topic_views/intake.rb
- Create: spec/lib/discourse_arz_tools/topic_views/intake_spec.rb
- Modify: plugin.rb
- Modify: config/settings.yml
- Modify: config/locales/server.en.yml
- Modify: config/locales/server.fa_IR.yml

**Interfaces:**
- Produces: DiscourseArzTools::TopicViews::Intake.accept!(topic_id:, external_user_id: nil, ip: nil) returning :accepted, :duplicate, or :rate_limited.
- Produces: Intake::InvalidInput, Intake::Unavailable, Intake::PENDING_KEY.

- [ ] **Step 1: Write failing intake examples**

Create tests for first acceptance, repeat deduplication, canonical IPv6, separate user/IP namespaces, invalid identity combinations, 255-byte limit, safety limiting, Redis failure, and absence of raw identities in Redis keys. The central examples are:

~~~ruby
it "buffers only the first event for an identity and topic" do
  expect(described_class.accept!(topic_id: 202_277, external_user_id: "11222")).to eq(:accepted)
  expect(described_class.accept!(topic_id: 202_277, external_user_id: "11222")).to eq(:duplicate)
  expect(Discourse.redis.hget(described_class::PENDING_KEY, "202277").to_i).to eq(1)
end

it "canonicalizes IPv6 before deduplication" do
  expect(described_class.accept!(topic_id: 9, ip: "2001:0db8::1")).to eq(:accepted)
  expect(described_class.accept!(topic_id: 9, ip: "2001:db8:0:0:0:0:0:1")).to eq(:duplicate)
end

it "rejects ambiguous identity" do
  expect {
    described_class.accept!(topic_id: 9, ip: "192.0.2.1", external_user_id: "1")
  }.to raise_error(described_class::InvalidInput)
end
~~~

In before/after hooks, enable the setting, set TTL 28,800 and limit 6,000, and delete only test keys under Intake::PREFIX.

- [ ] **Step 2: Run the spec and confirm failure**

Run:

~~~bash
LOAD_PLUGINS=1 bundle exec rspec plugins/discourse-arz-tools/spec/lib/discourse_arz_tools/topic_views/intake_spec.rb
~~~

Expected: FAIL with uninitialized constant DiscourseArzTools::TopicViews.

- [ ] **Step 3: Add settings and locale text**

Add these server-only settings:

~~~yaml
  discourse_arz_tools_topic_view_beacon_enabled:
    type: bool
    default: false
    client: false
  discourse_arz_tools_topic_view_beacon_dedupe_seconds:
    type: integer
    default: 28800
    min: 60
    max: 604800
    client: false
  discourse_arz_tools_topic_view_beacon_max_requests_per_minute:
    type: integer
    default: 6000
    min: 1
    max: 100000
    client: false
  discourse_arz_tools_topic_view_beacon_sql_batch_size:
    type: integer
    default: 500
    min: 1
    max: 5000
    client: false
~~~

Add matching English and Persian descriptions stating that the endpoint is private, TTL is seconds, the limit is global per minute, and SQL batch size is topics per statement.

- [ ] **Step 4: Implement the intake service**

~~~ruby
# frozen_string_literal: true
require "ipaddr"
require "openssl"

module ::DiscourseArzTools
  module TopicViews
    class Intake
      VERSION = "v1"
      PREFIX = "discourse_arz_tools:topic_views:#{VERSION}"
      PENDING_KEY = "#{PREFIX}:pending"
      class InvalidInput < StandardError; end
      class Unavailable < StandardError; end

      SCRIPT = DiscourseRedis::EvalHelper.new <<~LUA
        local requests = redis.call("INCR", KEYS[1])
        if requests == 1 then redis.call("EXPIRE", KEYS[1], 60) end
        if requests > tonumber(ARGV[1]) then return -1 end
        local created = redis.call("SET", KEYS[2], "1", "NX", "EX", ARGV[2])
        if not created then return 0 end
        redis.call("HINCRBY", KEYS[3], ARGV[3], 1)
        return 1
      LUA

      class << self
        def accept!(topic_id:, external_user_id: nil, ip: nil)
          id = Integer(topic_id, exception: false)
          raise InvalidInput, "topic_id must be positive" if !id || id <= 0
          identity = normalize_identity(external_user_id, ip)
          digest = OpenSSL::HMAC.hexdigest("SHA256", Rails.application.secret_key_base, identity)
          minute_key = "#{PREFIX}:rate:#{Time.now.to_i / 60}"
          result = SCRIPT.eval(
            Discourse.redis,
            [minute_key, "#{PREFIX}:dedupe:#{id}:#{digest}", PENDING_KEY],
            [
              SiteSetting.discourse_arz_tools_topic_view_beacon_max_requests_per_minute.to_i,
              SiteSetting.discourse_arz_tools_topic_view_beacon_dedupe_seconds.to_i,
              id,
            ],
          )
          { 1 => :accepted, 0 => :duplicate, -1 => :rate_limited }.fetch(result.to_i)
        rescue InvalidInput
          raise
        rescue StandardError => error
          Rails.logger.error("[discourse-arz-tools] topic view intake unavailable: #{error.class}")
          raise Unavailable, "topic view intake unavailable"
        end

        private

        def normalize_identity(external_user_id, ip)
          raise InvalidInput, "supply exactly one identity" if
            [external_user_id.present?, ip.present?].count(true) != 1
          if external_user_id.present?
            value = external_user_id.to_s
            raise InvalidInput, "external_user_id is too long" if value.bytesize > 255
            "user:#{value}"
          else
            "ip:#{IPAddr.new(ip.to_s)}"
          end
        rescue IPAddr::InvalidAddressError
          raise InvalidInput, "ip is invalid"
        end
      end
    end
  end
end
~~~

Add a test-only key cleanup method and require the file in plugin.rb after initialization.
Do not log successful or duplicate intake events; only the exception class may appear in an intake failure log.

- [ ] **Step 5: Run tests and commit**

Run the Step 2 command; expected PASS. Then:

~~~bash
git add plugin.rb config/settings.yml config/locales/server.en.yml config/locales/server.fa_IR.yml lib/discourse_arz_tools/topic_views/intake.rb spec/lib/discourse_arz_tools/topic_views/intake_spec.rb
git commit -m "feat: buffer deduplicated topic views in Redis"
~~~

### Task 2: Private Admin API Endpoint

**Files:**
- Create: app/controllers/discourse_arz_tools_topic_views_controller.rb
- Create: config/routes.rb
- Create: spec/requests/topic_view_beacon_controller_spec.rb
- Modify: plugin.rb

**Interfaces:**
- Consumes: Intake.accept! and its three result symbols and two errors.
- Produces: POST /discourse-arz-tools/topic-view.json.

- [ ] **Step 1: Write failing request tests**

Fabricate admin and non-admin API keys. Test accepted and duplicate JSON, a non-API admin session (403), non-admin API key (403), disabled setting (403), invalid input (422), rate limit with Retry-After: 60 (429), Redis unavailable (503), and no SQL query matching FROM topics during accepted intake.

~~~ruby
post path,
     params: { topic_id: 202_277, external_user_id: "11222" },
     headers: { "HTTP_API_KEY" => admin_api_key.key, "HTTP_API_USERNAME" => admin.username }
expect(response.status).to eq(200)
expect(response.parsed_body).to eq("counted" => true, "buffered" => true)
~~~

- [ ] **Step 2: Run the request spec and confirm the route failure**

~~~bash
LOAD_PLUGINS=1 bundle exec rspec plugins/discourse-arz-tools/spec/requests/topic_view_beacon_controller_spec.rb
~~~

Expected: FAIL with route not found.

- [ ] **Step 3: Add the route and controller**

~~~ruby
# config/routes.rb
Discourse::Application.routes.draw do
  post "/discourse-arz-tools/topic-view" => "discourse_arz_tools_topic_views#create"
end
~~~

~~~ruby
# app/controllers/discourse_arz_tools_topic_views_controller.rb
class DiscourseArzToolsTopicViewsController < ApplicationController
  before_action :ensure_admin_api_request
  before_action :ensure_feature_enabled

  def create
    result = ::DiscourseArzTools::TopicViews::Intake.accept!(
      topic_id: params[:topic_id],
      external_user_id: params[:external_user_id],
      ip: params[:ip],
    )
    return render(json: { counted: true, buffered: true }) if result == :accepted
    return render(json: { counted: false, reason: "duplicate" }) if result == :duplicate
    response.set_header("Retry-After", "60")
    render json: { counted: false, reason: "rate_limited" }, status: :too_many_requests
  rescue ::DiscourseArzTools::TopicViews::Intake::InvalidInput => error
    render json: { errors: [error.message] }, status: :unprocessable_entity
  rescue ::DiscourseArzTools::TopicViews::Intake::Unavailable
    render json: { errors: ["topic view intake unavailable"] }, status: :service_unavailable
  end

  private

  def ensure_admin_api_request
    raise Discourse::InvalidAccess if !is_api? || !current_user&.admin?
  end

  def ensure_feature_enabled
    return if SiteSetting.discourse_arz_tools_enabled &&
      SiteSetting.discourse_arz_tools_topic_view_beacon_enabled
    raise Discourse::InvalidAccess
  end
end
~~~

Require the controller from plugin.rb.

- [ ] **Step 4: Run focused tests and commit**

Run the Task 1 and Task 2 spec files together; expected PASS. Then:

~~~bash
git add plugin.rb config/routes.rb app/controllers/discourse_arz_tools_topic_views_controller.rb spec/requests/topic_view_beacon_controller_spec.rb
git commit -m "feat: expose private topic view beacon endpoint"
~~~

### Task 3: Idempotent Redis-to-PostgreSQL Flusher

**Files:**
- Create: db/migrate/20260814000001_create_discourse_arz_tools_topic_view_batches.rb
- Create: app/models/discourse_arz_tools/topic_views/batch.rb
- Create: lib/discourse_arz_tools/topic_views/flusher.rb
- Create: spec/lib/discourse_arz_tools/topic_views/flusher_spec.rb
- Modify: plugin.rb

**Interfaces:**
- Consumes: Intake::PENDING_KEY.
- Produces: Flusher.flush! returning :flushed, :empty, or :locked.
- Produces: durable unique batch markers.

- [ ] **Step 1: Add the migration and model**

~~~ruby
class CreateDiscourseArzToolsTopicViewBatches < ActiveRecord::Migration[7.0]
  def change
    create_table :discourse_arz_tools_topic_view_batches do |t|
      t.string :batch_id, null: false
      t.datetime :processed_at, null: false
    end
    add_index :discourse_arz_tools_topic_view_batches,
              :batch_id,
              unique: true,
              name: "idx_arz_tools_topic_view_batches_on_batch_id"
  end
end
~~~

~~~ruby
module ::DiscourseArzTools
  module TopicViews
    class Batch < ActiveRecord::Base
      self.table_name = "discourse_arz_tools_topic_view_batches"
    end
  end
end
~~~

Require the model in plugin.rb.

- [ ] **Step 2: Write failing flusher tests**

Test: aggregated increments, missing/deleted topics ignored, configured SQL group bound, active intake left untouched while retrying a processing batch, PostgreSQL failure retaining processing data and rolling back the marker, simulated failure after commit not double-applying, malformed fields discarded without affecting valid fields, empty result, and an existing lock returning :locked in under 200 ms.

~~~ruby
it "does not apply a committed batch twice" do
  described_class.install_processing_batch_for_test!("batch-1", topic.id => 4)
  allow(Discourse.redis).to receive(:del).and_raise("cleanup failed")
  expect { described_class.flush! }.to raise_error("cleanup failed")
  allow(Discourse.redis).to receive(:del).and_call_original
  expect(described_class.flush!).to eq(:flushed)
  expect(topic.reload.views).to eq(original_views + 4)
end
~~~

- [ ] **Step 3: Run the flusher spec and confirm failure**

~~~bash
RAILS_ENV=test bundle exec rake db:migrate
LOAD_PLUGINS=1 bundle exec rspec plugins/discourse-arz-tools/spec/lib/discourse_arz_tools/topic_views/flusher_spec.rb
~~~

Expected: FAIL with missing Flusher.

- [ ] **Step 4: Implement non-blocking locking and atomic rotation**

Use fixed processing and lock keys. The rotation Lua script must return the current processing batch first; otherwise rename pending to processing and write a UUID in the same script.

~~~ruby
ROTATE_SCRIPT = DiscourseRedis::EvalHelper.new <<~LUA
  if redis.call("EXISTS", KEYS[2]) == 1 then
    return redis.call("HGET", KEYS[2], ARGV[1])
  end
  if redis.call("EXISTS", KEYS[1]) == 0 then return nil end
  redis.call("RENAME", KEYS[1], KEYS[2])
  redis.call("HSET", KEYS[2], ARGV[1], ARGV[2])
  return ARGV[2]
LUA

def flush!
  token = SecureRandom.hex(16)
  return :locked if !Discourse.redis.set(LOCK_KEY, token, nx: true, ex: 1_800)
  begin
    batch_id = ROTATE_SCRIPT.eval(
      Discourse.redis,
      [Intake::PENDING_KEY, PROCESSING_KEY],
      [BATCH_FIELD, SecureRandom.uuid],
    )
    return :empty if batch_id.blank?
    apply_once!(batch_id, valid_pairs(Discourse.redis.hgetall(PROCESSING_KEY)))
    Discourse.redis.del(PROCESSING_KEY)
    :flushed
  ensure
    RELEASE_SCRIPT.eval(Discourse.redis, [LOCK_KEY], [token])
  end
end
~~~

RELEASE_SCRIPT must delete LOCK_KEY only when its value equals token. Test-only helpers may clear the three feature keys and install processing hashes only when Rails.env.test?.

- [ ] **Step 5: Implement ledger-backed bounded SQL updates**

~~~ruby
def apply_once!(batch_id, pairs)
  Batch.transaction do
    inserted = Batch.insert_all(
      [{ batch_id: batch_id, processed_at: Time.zone.now }],
      unique_by: :idx_arz_tools_topic_view_batches_on_batch_id,
      returning: %w[id],
    )
    apply_pairs!(pairs) if inserted.rows.any?
  end
end

def apply_pairs!(pairs)
  pairs.each_slice(SiteSetting.discourse_arz_tools_topic_view_beacon_sql_batch_size.to_i) do |slice|
    values = slice.map { |topic_id, count| "(#{topic_id}, #{count})" }.join(", ")
    DB.exec(<<~SQL)
      UPDATE topics
      SET views = topics.views + increments.view_count
      FROM (VALUES #{values}) AS increments(topic_id, view_count)
      WHERE topics.id = increments.topic_id
        AND topics.deleted_at IS NULL
    SQL
  end
end
~~~

Only integers produced by Integer(value, exception: false), strictly greater than zero, may enter values. Log malformed counters without their raw fields. The marker and every SQL group stay in one transaction.
Measure each flush with Process.clock_gettime and emit one aggregate completion log containing the batch ID, valid topic count, discarded field count, and duration. Failure logs contain the batch ID and exception class but never Redis field contents. Retain processed-batch ledger rows indefinitely so a delayed processing hash cannot become eligible for a second application.

- [ ] **Step 6: Run migration/specs and commit**

Run the migration, intake spec, and flusher spec. Expected: PASS, with the batch-size test observing no statement larger than its bound. Then:

~~~bash
git add plugin.rb db/migrate/20260814000001_create_discourse_arz_tools_topic_view_batches.rb app/models/discourse_arz_tools/topic_views/batch.rb lib/discourse_arz_tools/topic_views/flusher.rb spec/lib/discourse_arz_tools/topic_views/flusher_spec.rb
git commit -m "feat: flush topic views in idempotent batches"
~~~

### Task 4: Hourly Job and Manual Flush

**Files:**
- Create: app/jobs/scheduled/flush_discourse_arz_tools_topic_views.rb
- Create: spec/jobs/flush_discourse_arz_tools_topic_views_spec.rb
- Modify: lib/tasks/discourse_arz_tools.rake
- Modify: plugin.rb

**Interfaces:**
- Consumes: Flusher.flush!.
- Produces: Jobs::FlushDiscourseArzToolsTopicViews and rake discourse_arz_tools:topic_views:flush.

- [ ] **Step 1: Write the failing scheduled-job tests**

Test that both master and beacon settings must be enabled and that one enabled execution calls Flusher.flush! exactly once.

- [ ] **Step 2: Run and confirm the missing job failure**

~~~bash
LOAD_PLUGINS=1 bundle exec rspec plugins/discourse-arz-tools/spec/jobs/flush_discourse_arz_tools_topic_views_spec.rb
~~~

- [ ] **Step 3: Implement and register the hourly job**

~~~ruby
module Jobs
  class FlushDiscourseArzToolsTopicViews < ::Jobs::Scheduled
    every 1.hour

    def execute(args = nil)
      return if !SiteSetting.discourse_arz_tools_enabled
      return if !SiteSetting.discourse_arz_tools_topic_view_beacon_enabled
      ::DiscourseArzTools::TopicViews::Flusher.flush!
    end
  end
end
~~~

Require it in plugin.rb.

- [ ] **Step 4: Add the manual task**

~~~ruby
namespace :discourse_arz_tools do
  namespace :topic_views do
    desc "Flush buffered discourse-arz-tools topic views now"
    task flush: :environment do
      result = ::DiscourseArzTools::TopicViews::Flusher.flush!
      puts "Topic view flush result: #{result}"
    end
  end
end
~~~

Preserve the existing chat-count namespaces.

- [ ] **Step 5: Run and commit**

Run the job and flusher specs and rake -T discourse_arz_tools:topic_views. Expected: PASS and one listed flush task.

~~~bash
git add plugin.rb app/jobs/scheduled/flush_discourse_arz_tools_topic_views.rb spec/jobs/flush_discourse_arz_tools_topic_views_spec.rb lib/tasks/discourse_arz_tools.rake
git commit -m "feat: schedule hourly topic view flushes"
~~~

### Task 5: Documentation and Full Verification

**Files:**
- Modify: README.md
- Modify: plugin.rb
- Verify: all changed files

**Interfaces:**
- Consumes the finished endpoint, settings, flusher, and rake task.
- Produces a documented plugin release version 0.3.0.

- [ ] **Step 1: Document Nexus usage**

Add authenticated and guest curl examples, 200/422/429/503 responses, Retry-After, the one-hour delay, all four settings, HMAC privacy, manual flush, no TopicUser updates, and the recommendation to disable discourse_arz_tools_api_topic_views_enabled after Nexus switches to explicit events.

~~~bash
curl -X POST \
  -H "Api-Key: ADMIN_API_KEY" \
  -H "Api-Username: system" \
  -H "Content-Type: application/json" \
  -d '{"topic_id":202277,"external_user_id":"11222"}' \
  https://hub.arzdigital.com/discourse-arz-tools/topic-view.json
~~~

Include the guest body {"topic_id":202277,"ip":"203.0.113.42"} and warn that Nexus must derive identity/IP from trusted server context.

- [ ] **Step 2: Bump plugin version**

Change version 0.2.0 to 0.3.0. Keep required_version 3.3.0 unless tests prove a higher floor is necessary.

- [ ] **Step 3: Run all specs**

~~~bash
LOAD_PLUGINS=1 bundle exec rspec plugins/discourse-arz-tools/spec
~~~

Expected: all existing and new specs PASS.

- [ ] **Step 4: Run syntax and diff checks**

~~~bash
find app config db lib spec -name '*.rb' -print0 | xargs -0 -n1 ruby -c
git diff --check
git status --short
git diff --stat main...HEAD
~~~

Expected: Syntax OK for every Ruby file, silent diff check, and only scoped feature/design/plan files changed.

- [ ] **Step 5: Perform a test-environment smoke test**

Send the same valid test event twice with an admin API key. Expect counted true then duplicate. Run:

~~~bash
RAILS_ENV=production bundle exec rake discourse_arz_tools:topic_views:flush
~~~

Expect the test topic views to increase exactly once and no raw identity under discourse_arz_tools:topic_views:* Redis keys.

- [ ] **Step 6: Commit documentation**

~~~bash
git add README.md plugin.rb
git commit -m "docs: document batched topic view beacon"
~~~

Record the exact Discourse commit/version and full spec result in the implementation handoff.
