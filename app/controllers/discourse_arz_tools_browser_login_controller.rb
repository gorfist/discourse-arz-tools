# frozen_string_literal: true

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
    # Automatic synchronization must preserve an existing browser session.
    if current_user.present?
      return render json: { success: true, session_preserved: true }
    end
    ticket = params[:ticket]
    unless ticket.is_a?(String) && ticket.bytesize <= 16_384
      return render json: { success: false }, status: :bad_request
    end
    RateLimiter.new(nil, "arz-browser-login-#{request.remote_ip}", 60, 1.minute).performed!
    identity = ::DiscourseArzTools::BrowserLogin::TicketVerifier.verify(ticket)
    return render(json: { success: false }, status: :unauthorized) if identity.nil?

    user = ::DiscourseArzTools::WebviewAuth::IdentityResolver.resolve(
      identity, ip: request.remote_ip, server_session: server_session,
    )
    unless user&.active? && !user.suspended? && user.approved?
      return render json: { success: false }, status: :forbidden
    end
    log_on_user(user, replay_anonymous_action: true)
    server_session[:arz_idp_device_id] = identity["idp_device_id"]
    render json: { success: true }
  end

  private

  def allow_accounts_origin
    raise Discourse::InvalidAccess unless request.headers["Origin"] == ACCOUNTS_ORIGIN
    response.headers["Access-Control-Allow-Origin"] = ACCOUNTS_ORIGIN
    response.headers["Access-Control-Allow-Credentials"] = "true"
    response.headers["Vary"] = [response.headers["Vary"], "Origin"].compact.join(", ")
    response.headers["Cache-Control"] = "private, no-store"
  end

  def ensure_browser_login_enabled
    raise Discourse::NotFound unless SiteSetting.discourse_arz_tools_enabled &&
      SiteSetting.discourse_arz_tools_browser_login_enabled && SiteSetting.enable_discourse_connect
  end
end
