# frozen_string_literal: true

namespace :chat_channel_message_counts do
  desc "Check whether the recommended partial index exists"
  task check_index: :environment do
    if ::DiscourseChatChannelMessageCounts::Cache.recommended_index_exists?
      puts "Recommended chat_messages partial index exists."
    else
      puts "Recommended index is missing."
      puts "Run during a quiet window: rake chat_channel_message_counts:create_index"
    end
  end

  desc "Create the recommended partial index concurrently"
  task create_index: :environment do
    ::DiscourseChatChannelMessageCounts::Cache.create_recommended_index!
    puts "Recommended chat_messages partial index exists or was created."
  end
end
