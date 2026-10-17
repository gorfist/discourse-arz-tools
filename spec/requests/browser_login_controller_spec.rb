# frozen_string_literal: true

require "securerandom"

RSpec.describe DiscourseArzToolsBrowserLoginController do
  fab!(:user)
  let(:path) { "/discourse-arz-tools/browser-login" }
  let(:headers) { { "HTTP_ORIGIN" => "https://accounts.arzdigital.com" } }
  let(:identity) { { "external_id" => "42", "email" => user.email, "username" => user.username, "idp_device_id" => "device-42" } }

  before do
    SiteSetting.discourse_arz_tools_enabled = true
    SiteSetting.discourse_arz_tools_sync_login_enabled = true
    SiteSetting.discourse_arz_tools_sync_login_replace_existing_user = false
    SiteSetting.enable_discourse_connect = true
    SiteSetting.discourse_connect_secret = "test-secret"
    SiteSetting.discourse_connect_url = "https://accounts.arzdigital.com/auth/login"
    SiteSetting.discourse_connect_csrf_protection = true
    @previous_csrf = described_class.allow_forgery_protection
    described_class.allow_forgery_protection = true
    allow(::DiscourseArzTools::BrowserLogin::TicketVerifier).to receive(:verify).with("ticket").and_return(identity)
    allow(::DiscourseArzTools::WebviewAuth::IdentityResolver).to receive(:resolve).and_return(user)
  end
  after { described_class.allow_forgery_protection = @previous_csrf }

  def start_hub_login(return_path)
    get "/session/sso", params: { return_path: return_path }
    expect(response.status).to eq(302)
    query = Rack::Utils.parse_query(URI.parse(response.headers["Location"]).query)
    nonce = Rack::Utils.parse_query(Base64.decode64(query.fetch("sso"))).fetch("nonce")
    allow(::DiscourseArzTools::BrowserLogin::TicketVerifier).to receive(:verify)
      .with("ticket").and_return(identity.merge("hub_nonce" => nonce))
    nonce
  end

  describe "real signed single-use tickets" do
    before do
      allow(::DiscourseArzTools::BrowserLogin::TicketVerifier).to receive(:verify).and_call_original
      allow(::DiscourseArzTools::WebviewAuth::IdentityResolver).to receive(:resolve).and_call_original
      SingleSignOnRecord.create!(user_id: user.id, external_id: "42", last_payload: "")
    end

    after do
      Array(@signed_ticket_ids).each do |id|
        Discourse.redis.del("#{::DiscourseArzTools::BrowserLogin::TicketVerifier::USED_TICKET_PREFIX}#{id}")
      end
    end

    def signed_hub_ticket(nonce: nil)
      verifier = ::DiscourseArzTools::BrowserLogin::TicketVerifier
      ticket_id = SecureRandom.hex(16)
      (@signed_ticket_ids ||= []) << ticket_id
      signed_identity = identity.merge("name" => "Test User")
      signed_identity["hub_nonce"] = nonce if nonce
      claims = { "iss" => verifier::ISSUER, "aud" => verifier::AUDIENCE, "sub" => "42",
                 "iat" => Time.now.to_i, "exp" => Time.now.to_i + 60,
                 "jti" => ticket_id, "identity" => signed_identity }
      segments = [verifier::HEADER, claims].map do |value|
        Base64.urlsafe_encode64(JSON.generate(value), padding: false)
      end
      key = OpenSSL::HMAC.digest("sha256", SiteSetting.discourse_connect_secret, verifier::KEY_CONTEXT)
      signature = OpenSSL::HMAC.digest("sha256", key, segments.join("."))
      (segments << Base64.urlsafe_encode64(signature, padding: false)).join(".")
    end

    it "creates a real JSON login session once and rejects replay without changing the session" do
      ticket = signed_hub_ticket
      post path, params: { ticket: ticket }, headers: headers, as: :json
      expect(response.status).to eq(200)
      expect(cookies["_t"]).to be_present
      token_count = UserAuthToken.count

      post path, params: { ticket: ticket }, headers: headers, as: :json
      expect(response.status).to eq(401)
      expect(UserAuthToken.count).to eq(token_count)
      get "/session/current.json"
      expect(response.parsed_body.dig("current_user", "id")).to eq(user.id)
    end

    it "consumes tickets even when preserving an existing session" do
      sign_in(user)
      ticket = signed_hub_ticket
      token_count = UserAuthToken.count
      post path, params: { ticket: ticket }, headers: headers, as: :json
      expect(response.status).to eq(200)
      expect(response.parsed_body).to eq("success" => true, "session_preserved" => true)

      post path, params: { ticket: ticket }, headers: headers, as: :json
      expect(response.status).to eq(401)
      expect(UserAuthToken.count).to eq(token_count)
    end

    it "consumes a real explicit JSON ticket and keeps native nonce validation" do
      ticket = signed_hub_ticket(nonce: start_hub_login("/latest"))
      post path, params: { ticket: ticket }, headers: headers, as: :json
      expect(response.status).to eq(200)
      expect(response.parsed_body["redirect_url"]).to eq("https://hub.arzdigital.com/latest")
      expect(cookies["_t"]).to be_present

      post path, params: { ticket: ticket }, headers: headers, as: :json
      expect(response.status).to eq(401)
    end

    it "retains the reservation after a rejected nonce and requires a new ticket" do
      ticket = signed_hub_ticket(nonce: "wrong-browser-nonce")
      post path, params: { ticket: ticket }, headers: headers, as: :json
      expect(response.status).to eq(409)
      expect(cookies["_t"]).to be_blank

      post path, params: { ticket: ticket }, headers: headers, as: :json
      expect(response.status).to eq(401)
      expect(cookies["_t"]).to be_blank
    end
  end

  it "rejects form and text requests without consuming a ticket or creating a session" do
    post path, params: { ticket: "ticket" }, headers: headers
    expect(response.status).to eq(415)
    expect(response.media_type).to eq("application/json")
    expect(response.parsed_body).to eq("success" => false)
    post path, params: "ticket=ticket", headers: headers.merge("CONTENT_TYPE" => "text/plain")
    expect(response.status).to eq(415)
    expect(cookies["_t"]).to be_blank
    expect(::DiscourseArzTools::BrowserLogin::TicketVerifier).not_to have_received(:verify)
    expect(::DiscourseArzTools::WebviewAuth::IdentityResolver).not_to have_received(:resolve)
  end

  it "completes explicit background login and returns the saved destination without redirecting" do
    start_hub_login("/t/example/123?foo=bar")
    post path, params: { ticket: "ticket" }, headers: headers, as: :json
    expect(response.status).to eq(200)
    expect(response.parsed_body).to eq(
      "success" => true,
      "redirect_url" => "https://hub.arzdigital.com/t/example/123?foo=bar",
    )
    expect(response.headers["Location"]).to be_blank
    expect(response.headers["Access-Control-Allow-Credentials"]).to eq("true")
    expect(cookies["_t"]).to be_present
    get "/session/current.json"
    expect(response.parsed_body.dig("current_user", "id")).to eq(user.id)

    post path, params: { ticket: "ticket" }, headers: headers, as: :json
    expect(response.status).to eq(409)
    expect(response.parsed_body).to eq("success" => false)
  end

  it "switches an existing Hub identity for explicit background login" do
    sign_in(Fabricate(:user))
    start_hub_login("/latest")
    post path, params: { ticket: "ticket" }, headers: headers, as: :json
    expect(response.status).to eq(200)
    expect(response.parsed_body).to eq(
      "success" => true,
      "redirect_url" => "https://hub.arzdigital.com/latest",
    )
    get "/session/current.json"
    expect(response.parsed_body.dig("current_user", "id")).to eq(user.id)
  end

  it "rejects background nonce tickets from another browser, including signed-in browsers" do
    [nil, "", 42, "wrong-browser-nonce"].each do |nonce|
      allow(::DiscourseArzTools::BrowserLogin::TicketVerifier).to receive(:verify)
        .with("ticket").and_return(identity.merge("hub_nonce" => nonce))
      post path, params: { ticket: "ticket" }, headers: headers, as: :json
      expect(response.status).to eq(nonce == "wrong-browser-nonce" ? 409 : 400)
      expect(response.parsed_body).to eq("success" => false)
      expect(cookies["_t"]).to be_blank
    end
    expect(::DiscourseArzTools::WebviewAuth::IdentityResolver).not_to have_received(:resolve)

    existing_user = Fabricate(:user)
    sign_in(existing_user)
    post path, params: { ticket: "ticket" }, headers: headers, as: :json
    expect(response.status).to eq(409)
    expect(::DiscourseArzTools::WebviewAuth::IdentityResolver).not_to have_received(:resolve)
    get "/session/current.json"
    expect(response.parsed_body.dig("current_user", "id")).to eq(existing_user.id)
  end

  it "rejects invalid signed tickets even when a Hub session already exists" do
    sign_in(Fabricate(:user))
    allow(::DiscourseArzTools::BrowserLogin::TicketVerifier).to receive(:verify).and_return(nil)
    post path, params: { ticket: "ticket" }, headers: headers, as: :json
    expect(response.status).to eq(401)
    expect(response.parsed_body).to eq("success" => false)
    expect(::DiscourseArzTools::WebviewAuth::IdentityResolver).not_to have_received(:resolve)
  end

  it "requires body credentials and the exact extensionless endpoint" do
    post "#{path}?ticket=ticket", params: {}, headers: headers, as: :json
    expect(response.status).to eq(400)
    post "#{path}.json", params: { ticket: "ticket" }, headers: headers, as: :json
    expect(response.status).to eq(404)
  end

  it "restricts the saved destination to a safe Hub path" do
    controller = described_class.new
    expect(controller.send(:safe_return_path, "/t/example/123?foo=bar")).to eq("/t/example/123?foo=bar")
    expect(controller.send(:safe_return_path, "https://hub.arzdigital.com/latest")).to eq("/latest")
    [nil, "https://evil.example/", "//evil.example/", "/\\evil.example/", "/session/sso", "/path\n"].each do |path|
      expect(controller.send(:safe_return_path, path)).to eq("/")
    end
  end

  it "creates a Discourse cookie from an Accounts POST without a Hub CSRF token" do
    SiteSetting.login_required = true
    post path, params: { ticket: "ticket" }, headers: headers, as: :json
    expect(response.status).to eq(200)
    expect(response.parsed_body).to eq("success" => true)
    expect(cookies["_t"]).to be_present
    expect(UserAuthToken.where(user_id: user.id)).to exist
    expect(response.headers["Access-Control-Allow-Origin"]).to eq(headers["HTTP_ORIGIN"])
    expect(response.headers["Access-Control-Allow-Credentials"]).to eq("true")
  end

  it "keeps an existing Hub user instead of switching to the ticket user" do
    existing_user = Fabricate(:user)
    sign_in(existing_user)
    token_count = UserAuthToken.count

    post path, params: { ticket: "ticket" }, headers: headers, as: :json

    expect(response.status).to eq(200)
    expect(response.parsed_body).to eq("success" => true, "session_preserved" => true)
    expect(::DiscourseArzTools::BrowserLogin::TicketVerifier).to have_received(:verify).with("ticket")
    expect(::DiscourseArzTools::WebviewAuth::IdentityResolver).not_to have_received(:resolve)
    expect(UserAuthToken.count).to eq(token_count)

    get "/session/current.json"
    expect(response.parsed_body.dig("current_user", "id")).to eq(existing_user.id)
  end

  it "replaces an existing Hub user during automatic synchronization when enabled" do
    SiteSetting.discourse_arz_tools_sync_login_replace_existing_user = true
    existing_user = Fabricate(:user)
    sign_in(existing_user)

    post path, params: { ticket: "ticket" }, headers: headers, as: :json

    expect(response.status).to eq(200)
    expect(response.parsed_body).to eq("success" => true)
    expect(::DiscourseArzTools::BrowserLogin::TicketVerifier).to have_received(:verify).with("ticket")
    expect(::DiscourseArzTools::WebviewAuth::IdentityResolver).to have_received(:resolve)
    get "/session/current.json"
    expect(response.parsed_body.dig("current_user", "id")).to eq(user.id)
  end

  it "preserves the session without a new auth token when the ticket user is already signed in" do
    SiteSetting.discourse_arz_tools_sync_login_replace_existing_user = true
    SingleSignOnRecord.create!(user_id: user.id, external_id: "42", last_payload: "")
    sign_in(user)
    token_count = UserAuthToken.count

    post path, params: { ticket: "ticket" }, headers: headers, as: :json

    expect(response.status).to eq(200)
    expect(response.parsed_body).to eq("success" => true, "session_preserved" => true)
    expect(::DiscourseArzTools::WebviewAuth::IdentityResolver).not_to have_received(:resolve)
    expect(UserAuthToken.count).to eq(token_count)
    get "/session/current.json"
    expect(response.parsed_body.dig("current_user", "id")).to eq(user.id)
  end

  it "ends the replaced user's Hub auth token instead of leaving it valid" do
    SiteSetting.discourse_arz_tools_sync_login_replace_existing_user = true
    existing_user = Fabricate(:user)
    sign_in(existing_user)
    get "/session/current.json"
    expect(UserAuthToken.where(user_id: existing_user.id)).to exist

    post path, params: { ticket: "ticket" }, headers: headers, as: :json

    expect(response.status).to eq(200)
    expect(UserAuthToken.where(user_id: existing_user.id)).not_to exist
    expect(UserAuthToken.where(user_id: user.id)).to exist
    get "/session/current.json"
    expect(response.parsed_body.dig("current_user", "id")).to eq(user.id)
  end

  it "uses the current replacement option when accepting a ticket" do
    SiteSetting.discourse_arz_tools_sync_login_replace_existing_user = true
    existing_user = Fabricate(:user)
    sign_in(existing_user)

    SiteSetting.discourse_arz_tools_sync_login_replace_existing_user = false
    post path, params: { ticket: "ticket" }, headers: headers, as: :json
    expect(response.parsed_body).to eq("success" => true, "session_preserved" => true)
    expect(::DiscourseArzTools::WebviewAuth::IdentityResolver).not_to have_received(:resolve)
    get "/session/current.json"
    expect(response.parsed_body.dig("current_user", "id")).to eq(existing_user.id)
  end

  it "does not replace an existing session with an invalid ticket or suspended user" do
    SiteSetting.discourse_arz_tools_sync_login_replace_existing_user = true
    existing_user = Fabricate(:user)
    sign_in(existing_user)
    allow(::DiscourseArzTools::BrowserLogin::TicketVerifier).to receive(:verify).and_return(nil)
    post path, params: { ticket: "ticket" }, headers: headers, as: :json
    expect(response.status).to eq(401)
    expect(::DiscourseArzTools::WebviewAuth::IdentityResolver).not_to have_received(:resolve)

    allow(::DiscourseArzTools::BrowserLogin::TicketVerifier).to receive(:verify).and_return(identity)
    user.update!(suspended_till: 1.day.from_now)
    post path, params: { ticket: "ticket" }, headers: headers, as: :json
    expect(response.status).to eq(403)
    get "/session/current.json"
    expect(response.parsed_body.dig("current_user", "id")).to eq(existing_user.id)
    expect(UserAuthToken.where(user_id: existing_user.id)).to exist
  end

  it "still requires the original browser nonce for explicit login when replacement is enabled" do
    SiteSetting.discourse_arz_tools_sync_login_replace_existing_user = true
    existing_user = Fabricate(:user)
    sign_in(existing_user)
    allow(::DiscourseArzTools::BrowserLogin::TicketVerifier).to receive(:verify)
      .and_return(identity.merge("hub_nonce" => "wrong-browser-nonce"))
    post path, params: { ticket: "ticket" }, headers: headers, as: :json
    expect(response.status).to eq(409)
    expect(::DiscourseArzTools::WebviewAuth::IdentityResolver).not_to have_received(:resolve)
    get "/session/current.json"
    expect(response.parsed_body.dig("current_user", "id")).to eq(existing_user.id)

    start_hub_login("/latest")
    post path, params: { ticket: "ticket" }, headers: headers, as: :json
    expect(response.status).to eq(200)
    expect(response.parsed_body["redirect_url"]).to eq("https://hub.arzdigital.com/latest")
    get "/session/current.json"
    expect(response.parsed_body.dig("current_user", "id")).to eq(user.id)
  end

  it "requires a ticket without reporting session state for unrelated payloads" do
    post path, params: { unexpected: true }, headers: headers, as: :json
    expect(response.status).to eq(400)
    expect(response.parsed_body).not_to have_key("logged_in")
    expect(response.parsed_body).not_to have_key("replace_existing_user")
    expect(::DiscourseArzTools::BrowserLogin::TicketVerifier).not_to have_received(:verify)
    expect(::DiscourseArzTools::WebviewAuth::IdentityResolver).not_to have_received(:resolve)
  end

  it "allows only the exact Accounts origin" do
    [nil, "https://evil.example", "https://accounts.arzdigital.com.evil.example"].each do |origin|
      post path, params: { ticket: "ticket" }, headers: { "HTTP_ORIGIN" => origin }, as: :json
      expect(response.status).to eq(403)
    end
    expect(::DiscourseArzTools::BrowserLogin::TicketVerifier).not_to have_received(:verify)
  end

  it "answers a credentialed JSON preflight" do
    options path, headers: headers.merge("HTTP_ACCESS_CONTROL_REQUEST_METHOD" => "POST", "HTTP_ACCESS_CONTROL_REQUEST_HEADERS" => "content-type")
    expect(response.status).to eq(204)
    expect(response.headers["Access-Control-Allow-Methods"]).to eq("POST")
    expect(response.headers["Access-Control-Allow-Credentials"]).to eq("true")
  end

  it "rejects unsupported preflight headers" do
    options path, headers: headers.merge("HTTP_ACCESS_CONTROL_REQUEST_METHOD" => "POST", "HTTP_ACCESS_CONTROL_REQUEST_HEADERS" => "authorization")
    expect(response.status).to eq(403)
  end

  it "rejects missing credentials and invalid tickets without cookies" do
    post path, params: {}, headers: headers, as: :json
    expect(response.status).to eq(400)
    allow(::DiscourseArzTools::BrowserLogin::TicketVerifier).to receive(:verify).and_return(nil)
    post path, params: { ticket: "ticket" }, headers: headers, as: :json
    expect(response.status).to eq(401)
    expect(cookies["_t"]).to be_blank
  end

  it "rejects suspended users" do
    user.update!(suspended_till: 1.day.from_now)
    post path, params: { ticket: "ticket" }, headers: headers, as: :json
    expect(response.status).to eq(403)
    expect(cookies["_t"]).to be_blank
  end

  [false, true].each do |explicit_login|
    describe(explicit_login ? "explicit Hub login approval" : "automatic Hub login approval") do
      before { start_hub_login("/latest") if explicit_login }

      it "allows an unapproved user when approval is not required" do
        SiteSetting.must_approve_users = false
        user.update!(approved: false, approved_at: nil, approved_by_id: nil)

        post path, params: { ticket: "ticket" }, headers: headers, as: :json

        expect(response.status).to eq(200)
        expect(response.parsed_body["success"]).to eq(true)
        expect(cookies["_t"]).to be_present
        expect(user.reload.approved?).to eq(false)
        get "/session/current.json"
        expect(response.parsed_body.dig("current_user", "id")).to eq(user.id)
      end

      it "rejects an unapproved user when approval is required" do
        SiteSetting.must_approve_users = true
        user.update!(approved: false, approved_at: nil, approved_by_id: nil)

        post path, params: { ticket: "ticket" }, headers: headers, as: :json

        expect(response.status).to eq(403)
        expect(response.parsed_body).to eq("success" => false)
        expect(cookies["_t"]).to be_blank
      end

      it "allows an approved user when approval is required" do
        SiteSetting.must_approve_users = true
        user.update!(approved: true)

        post path, params: { ticket: "ticket" }, headers: headers, as: :json

        expect(response.status).to eq(200)
        expect(response.parsed_body["success"]).to eq(true)
        expect(cookies["_t"]).to be_present
      end

      it "still rejects an inactive user when approval is not required" do
        SiteSetting.must_approve_users = false
        user.update!(active: false, approved: false)

        post path, params: { ticket: "ticket" }, headers: headers, as: :json

        expect(response.status).to eq(403)
        expect(cookies["_t"]).to be_blank
      end

      it "still rejects a suspended user when approval is not required" do
        SiteSetting.must_approve_users = false
        user.update!(approved: false, suspended_till: 1.day.from_now)

        post path, params: { ticket: "ticket" }, headers: headers, as: :json

        expect(response.status).to eq(403)
        expect(cookies["_t"]).to be_blank
      end
    end
  end

  it "rejects disabled synchronization" do
    SiteSetting.discourse_arz_tools_sync_login_enabled = false
    post path, params: { ticket: "ticket" }, headers: headers, as: :json
    expect(response.status).to eq(404)
  end
end
