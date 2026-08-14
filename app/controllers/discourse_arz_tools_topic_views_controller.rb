# frozen_string_literal: true

class DiscourseArzToolsTopicViewsController < ApplicationController
  requires_plugin ::DiscourseArzTools::PLUGIN_NAME

  before_action :ensure_admin_api_request
  before_action :ensure_feature_enabled

  def create
    result =
      ::DiscourseArzTools::TopicViews::Intake.accept!(
        topic_id: params[:topic_id],
        external_user_id: params[:external_user_id],
        ip: params[:ip],
      )

    case result
    when :accepted
      render json: { counted: true, buffered: true }
    when :duplicate
      render json: { counted: false, reason: "duplicate" }
    when :rate_limited
      response.set_header("Retry-After", "60")
      render json: { counted: false, reason: "rate_limited" }, status: :too_many_requests
    end
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
