# frozen_string_literal: true

module ::DiscourseArzTools
  module TopicViews
    class Batch < ActiveRecord::Base
      self.table_name = "discourse_arz_tools_topic_view_batches"

      validates :batch_id, presence: true, uniqueness: true
      validates :processed_at, presence: true
    end
  end
end
