# frozen_string_literal: true

RSpec.describe DiscourseArzTools::BrowserLogin::TicketVerifier do
  let(:identity) { { "external_id" => 42, "username" => "user42", "idp_device_id" => "device-42" } }
  let(:claims) do
    { "iss" => described_class::ISSUER, "aud" => described_class::AUDIENCE,
      "sub" => "42", "iat" => Time.now.to_i, "exp" => Time.now.to_i + 60,
      "identity" => identity }
  end
  before { SiteSetting.discourse_connect_secret = "test-secret" }

  def sign(payload, header = described_class::HEADER, secret = "test-secret")
    segments = [header, payload].map { |value| Base64.urlsafe_encode64(JSON.generate(value), padding: false) }
    key = OpenSSL::HMAC.digest("sha256", secret, described_class::KEY_CONTEXT)
    signature = OpenSSL::HMAC.digest("sha256", key, segments.join("."))
    (segments << Base64.urlsafe_encode64(signature, padding: false)).join(".")
  end

  it "accepts repeated verification of a valid ticket" do
    ticket = sign(claims)
    expect(described_class.verify(ticket)).to eq(identity)
    expect(described_class.verify(ticket)).to eq(identity)
  end

  it "rejects a wrong signature" do
    expect(described_class.verify(sign(claims, described_class::HEADER, "wrong-secret"))).to be_nil
    expect(described_class.verify(sign(claims))).to eq(identity)
  end

  it "rejects invalid registered claims and identity binding" do
    [
      { "iss" => "other" }, { "aud" => "other" }, { "sub" => "99" },
      { "exp" => Time.now.to_i - 1 }, { "iat" => Time.now.to_i + 30 },
      { "exp" => Time.now.to_i + 120 },
      { "identity" => identity.merge("idp_device_id" => "") },
    ].each do |change|
      expect(described_class.verify(sign(claims.merge(change)))).to be_nil
    end
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
