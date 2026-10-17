# frozen_string_literal: true

require "uri"

class DiscourseArzToolsBrowserLoginController < ApplicationController
  requires_plugin ::DiscourseArzTools::PLUGIN_NAME
  ACCOUNTS_ORIGIN = "https://accounts.arzdigital.com"

  skip_before_action :redirect_to_login_if_required, :redirect_to_profile_if_required,
                     :check_xhr, :preload_json
  # This endpoint uses exact Origin validation and a signed short-lived credential
  # instead of a Hub CSRF token. All other Discourse endpoints retain normal CSRF.
  skip_before_action :verify_authenticity_token, only: %i[create preflight]
  before_action :allow_accounts_origin
  before_action :ensure_browser_login_enabled, only: :create

  def preflight
    raise Discourse::InvalidAccess unless request.headers["Access-Control-Request-Method"] == "POST"
    headers = request.headers["Access-Control-Request-Headers"].to_s.downcase.split(",").map(&:strip)
    raise Discourse::InvalidAccess unless (headers - ["content-type"]).empty?
    response.headers["Access-Control-Allow-Methods"] = "POST"
    response.headers["Access-Control-Allow-Headers"] = "Content-Type"
    response.headers["Access-Control-Max-Age"] = "600"
    head :no_content
  end

  def create
    return login_error(:unsupported_media_type) unless request.media_type == "application/json"
    return login_error(:bad_request) if request.query_parameters.key?("ticket")
    ticket = params[:ticket]
    unless ticket.is_a?(String) && ticket.bytesize <= 16_384
      return login_error(:bad_request)
    end
    RateLimiter.new(nil, "arz-browser-login-#{request.remote_ip}", 60, 1.minute).performed!
    identity = ::DiscourseArzTools::BrowserLogin::TicketVerifier.verify(ticket)
    return login_error(:unauthorized) if identity.nil?

    destination = nil
    explicit_login = identity.key?("hub_nonce")
    if explicit_login
      nonce = identity["hub_nonce"]
      return login_error(:bad_request) unless nonce.is_a?(String) && nonce.present?
      sso = DiscourseConnect.new(server_session: server_session)
      sso.nonce = nonce
      return login_error(:conflict) unless sso.nonce_valid?
      destination = safe_return_path(sso.return_path)
      # Consume before identity resolution or login can rotate the server session.
      sso.expire_nonce!
    elsif current_user.present? && !SiteSetting.discourse_arz_tools_sync_login_replace_existing_user
      # Apply the current replacement policy when accepting the login ticket.
      return render json: { success: true, session_preserved: true }
    elsif current_user.present? && current_user_matches_identity?(identity)
      # Same Accounts user: keep the session instead of issuing another auth token on every sync.
      return render json: { success: true, session_preserved: true }
    end

    raise Discourse::ReadOnly if @readonly_mode && !@staff_writes_only_mode
    return login_error(:forbidden) if ScreenedIpAddress.should_block?(request.remote_ip)

    user = ::DiscourseArzTools::WebviewAuth::IdentityResolver.resolve(
      identity, ip: request.remote_ip, server_session: server_session,
    )
    raise Discourse::ReadOnly if @staff_writes_only_mode && !user&.staff?
    return login_error(:forbidden) unless user&.active? && !user.suspended?
    # Match native DiscourseConnect: approval is required only when enabled.
    return login_error(:forbidden) if SiteSetting.must_approve_users? && !user.approved?
    # Replacing another browser session (explicit login or enabled replacement): end its
    # Hub auth token like native logout so it does not stay valid until expiry. This runs
    # only after every check passed, so a rejected ticket never logs anyone out.
    log_off_user if current_user.present?
    log_on_user(user, replay_anonymous_action: true)
    server_session[:arz_idp_device_id] = identity["idp_device_id"]
    if explicit_login
      render json: { success: true, redirect_url: "https://hub.arzdigital.com#{destination}" }
    else
      render json: { success: true }
    end
  end

  private

  def current_user_matches_identity?(identity)
    external_id = identity["external_id"].to_s
    external_id.present? &&
      SingleSignOnRecord.where(user_id: current_user.id, external_id: external_id).exists?
  end

  def login_error(status)
    render json: { success: false }, status: status
  end

  def safe_return_path(value)
    return "/" unless value.is_a?(String)
    return "/" if value.match?(/[\\\x00-\x20]/) || value.include?("/session/sso")
    if value.start_with?("https://")
      uri = URI.parse(value)
      return "/" unless uri.host == "hub.arzdigital.com" && uri.port == 443 && uri.userinfo.nil?
      value = uri.request_uri
    end
    value.match?(%r{\A/(?!/)}) ? value : "/"
  rescue URI::InvalidURIError
    "/"
  end

  def allow_accounts_origin
    raise Discourse::InvalidAccess unless request.headers["Origin"] == ACCOUNTS_ORIGIN
    response.headers["Access-Control-Allow-Origin"] = ACCOUNTS_ORIGIN
    response.headers["Access-Control-Allow-Credentials"] = "true"
    response.headers["Vary"] = [response.headers["Vary"], "Origin"].compact.join(", ")
    response.headers["Cache-Control"] = "private, no-store"
  end

  def ensure_browser_login_enabled
    raise Discourse::NotFound unless SiteSetting.discourse_arz_tools_enabled &&
      SiteSetting.discourse_arz_tools_sync_login_enabled && SiteSetting.enable_discourse_connect
  end
end
