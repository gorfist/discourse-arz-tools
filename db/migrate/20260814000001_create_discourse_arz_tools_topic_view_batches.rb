# frozen_string_literal: true

class CreateDiscourseArzToolsTopicViewBatches < ActiveRecord::Migration[7.0]
  def change
    create_table :discourse_arz_tools_topic_view_batches do |table|
      table.string :batch_id, null: false
      table.datetime :processed_at, null: false
    end

    add_index :discourse_arz_tools_topic_view_batches,
              :batch_id,
              unique: true,
              name: "idx_arz_tools_topic_view_batches_on_batch_id"
  end
end
