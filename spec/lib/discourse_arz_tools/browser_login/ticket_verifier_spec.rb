# frozen_string_literal: true

require "securerandom"

RSpec.describe DiscourseArzTools::BrowserLogin::TicketVerifier do
  let(:identity) { { "external_id" => 42, "username" => "user42", "idp_device_id" => "device-42" } }
  let(:claims) do
    { "iss" => described_class::ISSUER, "aud" => described_class::AUDIENCE,
      "sub" => "42", "iat" => Time.now.to_i, "exp" => Time.now.to_i + 60,
      "jti" => SecureRandom.hex(16),
      "identity" => identity }
  end
  before { SiteSetting.discourse_connect_secret = "test-secret" }
  after do
    Array(@ticket_ids).uniq.each do |id|
      Discourse.redis.del("#{described_class::USED_TICKET_PREFIX}#{id}")
    end
  end

  def sign(payload, header = described_class::HEADER, secret = "test-secret")
    (@ticket_ids ||= []) << payload["jti"]
    segments = [header, payload].map { |value| Base64.urlsafe_encode64(JSON.generate(value), padding: false) }
    key = OpenSSL::HMAC.digest("sha256", secret, described_class::KEY_CONTEXT)
    signature = OpenSSL::HMAC.digest("sha256", key, segments.join("."))
    (segments << Base64.urlsafe_encode64(signature, padding: false)).join(".")
  end

  it "accepts a valid ticket once and rejects replay" do
    ticket = sign(claims)
    expect(described_class.verify(ticket)).to eq(identity)
    expect(described_class.verify(ticket)).to be_nil
  end

  it "accepts a separately issued ticket for the same identity" do
    expect(described_class.verify(sign(claims))).to eq(identity)
    expect(described_class.verify(sign(claims.merge("jti" => SecureRandom.hex(16))))).to eq(identity)
  end

  it "retains only the ID until the remaining expiry, without extending it on replay" do
    freeze_time
    ticket = sign(claims.merge("iat" => Time.now.to_i - 40, "exp" => Time.now.to_i + 20))
    expect(described_class.verify(ticket)).to eq(identity)
    key = "#{described_class::USED_TICKET_PREFIX}#{claims["jti"]}"
    expect(Discourse.redis.get(key)).to eq("1")
    expect(Discourse.redis.ttl(key)).to be_between(19, 20)
    allow(Discourse.redis).to receive(:set).and_call_original
    expect(described_class.verify(ticket)).to be_nil
    expect(Discourse.redis).to have_received(:set).with(key, "1", nx: true, ex: 20).once
    expect(Discourse.redis.ttl(key)).to be_between(19, 20)
  end

  it "allows only one concurrent verification of the same ticket" do
    ticket = sign(claims)
    ready, release = Queue.new, Queue.new
    threads = Array.new(8) do
      Thread.new do
        ready << true
        release.pop
        described_class.verify(ticket)
      end
    end
    8.times { ready.pop }
    8.times { release << true }
    results = threads.map(&:value)
    expect(results.count(identity)).to eq(1)
    expect(results.count(nil)).to eq(7)
  end

  it "rejects an expired ticket even after its consumed-ID entry is gone" do
    freeze_time
    ticket = sign(claims)
    expect(described_class.verify(ticket)).to eq(identity)
    Discourse.redis.del("#{described_class::USED_TICKET_PREFIX}#{claims["jti"]}")
    freeze_time(Time.now + 61)
    allow(Discourse.redis).to receive(:set).and_call_original
    expect(described_class.verify(ticket)).to be_nil
    expect(Discourse.redis).not_to have_received(:set)
  end

  it "fails closed when Redis cannot reserve the ID" do
    allow(Discourse.redis).to receive(:set).and_raise(StandardError, "Redis unavailable")
    expect(described_class.verify(sign(claims))).to be_nil
  end

  it "rejects missing and malformed IDs before touching Redis" do
    allow(Discourse.redis).to receive(:set).and_call_original
    expect(described_class.verify(sign(claims.except("jti")))).to be_nil
    [nil, "", 42, "a" * 31, "a" * 33, "A" * 32, "x" * 32].each do |id|
      expect(described_class.verify(sign(claims.merge("jti" => id)))).to be_nil
    end
    expect(Discourse.redis).not_to have_received(:set)
  end

  it "rejects a wrong signature" do
    expect(described_class.verify(sign(claims, described_class::HEADER, "wrong-secret"))).to be_nil
    expect(described_class.verify(sign(claims))).to eq(identity)
  end

  it "rejects invalid registered claims and identity binding" do
    allow(Discourse.redis).to receive(:set).and_call_original
    [
      { "iss" => "other" }, { "aud" => "other" }, { "sub" => "99" },
      { "exp" => Time.now.to_i - 1 }, { "iat" => Time.now.to_i + 30 },
      { "exp" => Time.now.to_i + 120 },
      { "identity" => identity.merge("idp_device_id" => "") },
    ].each do |change|
      expect(described_class.verify(sign(claims.merge(change)))).to be_nil
    end
    expect(Discourse.redis).not_to have_received(:set)
  end

  it "rejects algorithm and purpose substitution" do
    expect(described_class.verify(sign(claims, { "alg" => "none", "typ" => "arz-hub-login+jwt" }))).to be_nil
    expect(described_class.verify(sign(claims, { "alg" => "HS256", "typ" => "JWT" }))).to be_nil
  end

  it "accepts a signed Hub nonce and rejects malformed nonces" do
    bound_identity = identity.merge("hub_nonce" => "hub-nonce")
    expect(described_class.verify(sign(claims.merge("identity" => bound_identity)))).to eq(bound_identity)
    [nil, "", 42, "x" * 257].each do |nonce|
      expect(described_class.verify(sign(claims.merge("identity" => identity.merge("hub_nonce" => nonce))))).to be_nil
    end
  end


  it "rejects malformed and oversized credentials" do
    [nil, "", "x.y.z", "x" * 16_385].each { |ticket| expect(described_class.verify(ticket)).to be_nil }
  end
end
