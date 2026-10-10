# frozen_string_literal: true

RSpec.describe DiscourseArzToolsBrowserLoginController do
  fab!(:user)
  let(:path) { "/discourse-arz-tools/browser-login" }
  let(:headers) { { "HTTP_ORIGIN" => "https://accounts.arzdigital.com" } }
  let(:identity) { { "external_id" => "42", "email" => user.email, "username" => user.username, "idp_device_id" => "device-42" } }

  before do
    SiteSetting.discourse_arz_tools_enabled = true
    SiteSetting.discourse_arz_tools_browser_login_enabled = true
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

  it "logs in through a browser form and redirects to the saved Hub page" do
    start_hub_login("/t/example/123?foo=bar")
    post path, params: { ticket: "ticket" }, headers: headers
    expect(response.status).to eq(302)
    expect(URI.parse(response.headers["Location"]).request_uri).to eq("/t/example/123?foo=bar")
    expect(cookies["_t"]).to be_present
    expect(UserAuthToken.where(user_id: user.id)).to exist

    post path, params: { ticket: "ticket" }, headers: headers
    expect(response.status).to eq(409)
  end

  it "completes explicit login with the Accounts identity even when Hub has another user" do
    sign_in(Fabricate(:user))
    start_hub_login("/latest")
    post path, params: { ticket: "ticket" }, headers: headers
    expect(response.status).to eq(302)
    get "/session/current.json"
    expect(response.parsed_body.dig("current_user", "id")).to eq(user.id)
  end

  it "rejects form tickets without a valid browser-session nonce" do
    post path, params: { ticket: "ticket" }, headers: headers
    expect(response.status).to eq(400)
    allow(::DiscourseArzTools::BrowserLogin::TicketVerifier).to receive(:verify)
      .and_return(identity.merge("hub_nonce" => "wrong-browser-nonce"))
    post path, params: { ticket: "ticket" }, headers: headers
    expect(response.status).to eq(409)
    expect(cookies["_t"]).to be_blank
    expect(::DiscourseArzTools::WebviewAuth::IdentityResolver).not_to have_received(:resolve)
  end

  it "rejects explicit-login tickets submitted as background JSON" do
    start_hub_login("/latest")
    post path, params: { ticket: "ticket" }, headers: headers, as: :json
    expect(response.status).to eq(400)
    expect(cookies["_t"]).to be_blank
  end

  it "shows the themed Persian error page for an invalid browser form ticket" do
    allow(::DiscourseArzTools::BrowserLogin::TicketVerifier).to receive(:verify).and_return(nil)

    post path, params: { ticket: "ticket" }, headers: headers

    expect(response.status).to eq(401)
    expect(response.media_type).to eq("text/html")
    expect(response.body).to include("ورود به هاب ناموفق بود.")
    expect(response.body).to include("لطفاً به هاب برگردید و دوباره ورود را شروع کنید.")
    expect(response.body).to include('id="discourse-error"')
    expect(response.body).to include("page-not-found")
    expect(response.body).to include("<html")
    expect(cookies["_t"]).to be_blank
    expect(::DiscourseArzTools::WebviewAuth::IdentityResolver).not_to have_received(:resolve)

    post path, params: { ticket: "ticket" }, headers: headers, as: :json

    expect(response.status).to eq(401)
    expect(response.media_type).to eq("application/json")
    expect(response.parsed_body).to eq("success" => false)
  end

  it "rejects tickets in the URL and the old JSON-suffixed route" do
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
    expect(::DiscourseArzTools::BrowserLogin::TicketVerifier).not_to have_received(:verify)
    expect(::DiscourseArzTools::WebviewAuth::IdentityResolver).not_to have_received(:resolve)
    expect(UserAuthToken.count).to eq(token_count)

    get "/session/current.json"
    expect(response.parsed_body.dig("current_user", "id")).to eq(existing_user.id)
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

  it "rejects disabled synchronization" do
    SiteSetting.discourse_arz_tools_browser_login_enabled = false
    post path, params: { ticket: "ticket" }, headers: headers, as: :json
    expect(response.status).to eq(404)
  end
end
