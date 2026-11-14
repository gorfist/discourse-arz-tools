# frozen_string_literal: true

module ::DiscourseArzTools
  # Reuse Rails' request-scoped tags so existing Started/Completed lines can be
  # correlated with a worker timeout. Rails also cleans up tags on exceptions
  # and when the response body closes; no extra log calls are introduced.
  module RequestLogTags
    private

    def compute_tags(request)
      super + ["pid=#{Process.pid}", "request_id=#{request.request_id}"]
    end
  end
end
