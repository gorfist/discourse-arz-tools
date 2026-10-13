# frozen_string_literal: true

class DiscourseArzToolsBrowserLogoutController < ApplicationController
  requires_plugin ::DiscourseArzTools::PLUGIN_NAME
  ACCOUNTS_ORIGIN = "https://accounts.arzdigital.com"

  skip_before_action :redirect_to_login_if_required, :redirect_to_profile_if_required,
                     :check_xhr, :preload_json
  # A mandatory exact browser Origin replaces token-based CSRF on these routes only.
  skip_before_action :verify_authenticity_token, only: %i[destroy preflight]
  before_action :allow_accounts_origin

  def preflight
    raise Discourse::InvalidAccess unless request.headers["Access-Control-Request-Method"] == "POST"
    requested_headers = request.headers["Access-Control-Request-Headers"].to_s.downcase.split(",").map(&:strip)
    raise Discourse::InvalidAccess unless (requested_headers - ["content-type"]).empty?

    response.headers["Access-Control-Allow-Methods"] = "POST"
    response.headers["Access-Control-Allow-Headers"] = "Content-Type"
    response.headers["Access-Control-Max-Age"] = "600"
    head :no_content
  end

  def destroy
    unless request.media_type == "application/json"
      return render json: { success: false }, status: :unsupported_media_type
    end

    # Match native Discourse session destruction, including log_out_strict policy.
    reset_session
    log_off_user
    # Prevent the after-action refresh from rotating/reissuing a just-ended session.
    clear_current_user
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
end
