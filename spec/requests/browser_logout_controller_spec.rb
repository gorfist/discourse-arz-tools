# frozen_string_literal: true

RSpec.describe DiscourseArzToolsBrowserLogoutController do
  fab!(:user)
  let(:path) { "/discourse-arz-tools/browser-logout" }
  let(:headers) { { "HTTP_ORIGIN" => "https://accounts.arzdigital.com" } }

  before do
    SiteSetting.discourse_arz_tools_enabled = true
    SiteSetting.log_out_strict = false
    @previous_csrf = described_class.allow_forgery_protection
    described_class.allow_forgery_protection = true
  end
  after { described_class.allow_forgery_protection = @previous_csrf }

  it "ends the current cookie session while retaining a second browser session" do
    sign_in(user)
    other_token = UserAuthToken.generate!(user_id: user.id)

    post path, params: {}, headers: headers, as: :json

    expect(response.status).to eq(200)
    expect(response.parsed_body).to eq("success" => true)
    expect(cookies["_t"]).to be_blank
    expect(UserAuthToken.where(user_id: user.id).pluck(:id)).to eq([other_token.id])
    expect(response.headers["Location"]).to be_blank
    expect(response.headers["Access-Control-Allow-Origin"]).to eq(headers["HTTP_ORIGIN"])
    expect(response.headers["Access-Control-Allow-Credentials"]).to eq("true")
    expect(response.headers["Vary"]).to include("Origin")
    expect(response.headers["Cache-Control"]).to include("no-store")

    get "/session/current.json"
    expect(response.status).to eq(404)
  end

  it "succeeds idempotently for guests even when login is required" do
    SiteSetting.login_required = true
    2.times do
      post path, params: {}, headers: headers, as: :json
      expect(response.status).to eq(200)
      expect(response.parsed_body).to eq("success" => true)
    end
  end

  it "honors native Discourse strict logout when administrators enable it" do
    SiteSetting.log_out_strict = true
    sign_in(user)
    UserAuthToken.generate!(user_id: user.id)

    post path, params: {}, headers: headers, as: :json

    expect(response.status).to eq(200)
    expect(UserAuthToken.where(user_id: user.id)).not_to exist
    expect(cookies["_t"]).to be_blank
  end

  it "rejects missing or spoofed Origins without ending the Hub session" do
    sign_in(user)
    [nil, "null", "https://hub.arzdigital.com", "https://arzdigital.com",
     "https://accounts.arzdigital.com.evil.example"].each do |origin|
      post path, params: {}, headers: { "HTTP_ORIGIN" => origin }, as: :json
      expect(response.status).to eq(403)
      expect(response.headers["Access-Control-Allow-Origin"]).to be_blank
    end
    get "/session/current.json"
    expect(response.parsed_body.dig("current_user", "id")).to eq(user.id)
  end

  it "rejects a form POST without terminating a session" do
    sign_in(user)
    post path, params: { unused: "value" }, headers: headers
    expect(response.status).to eq(415)
    get "/session/current.json"
    expect(response.parsed_body.dig("current_user", "id")).to eq(user.id)
  end

  it "answers only the permitted credentialed JSON preflight" do
    options path, headers: headers.merge(
      "HTTP_ACCESS_CONTROL_REQUEST_METHOD" => "POST",
      "HTTP_ACCESS_CONTROL_REQUEST_HEADERS" => "content-type",
    )
    expect(response.status).to eq(204)
    expect(response.headers["Access-Control-Allow-Methods"]).to eq("POST")
    expect(response.headers["Access-Control-Allow-Headers"]).to eq("Content-Type")
    expect(response.headers["Access-Control-Allow-Credentials"]).to eq("true")

    options path, headers: headers.merge("HTTP_ACCESS_CONTROL_REQUEST_METHOD" => "DELETE")
    expect(response.status).to eq(403)
    options path, headers: headers.merge(
      "HTTP_ACCESS_CONTROL_REQUEST_METHOD" => "POST",
      "HTTP_ACCESS_CONTROL_REQUEST_HEADERS" => "authorization",
    )
    expect(response.status).to eq(403)
    options path, headers: { "HTTP_ORIGIN" => "https://evil.example", "HTTP_ACCESS_CONTROL_REQUEST_METHOD" => "POST" }
    expect(response.status).to eq(403)
  end

  it "does not depend on browser login being enabled" do
    SiteSetting.discourse_arz_tools_sync_login_enabled = false
    post path, params: {}, headers: headers, as: :json
    expect(response.status).to eq(200)
  end

  it "does not permit logout when the plugin is disabled" do
    sign_in(user)
    SiteSetting.discourse_arz_tools_enabled = false
    post path, params: {}, headers: headers, as: :json
    expect(response.status).to eq(404)
    expect(UserAuthToken.where(user_id: user.id)).to exist
  end
end
