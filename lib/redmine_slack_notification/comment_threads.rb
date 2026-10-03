# frozen_string_literal: true

module RedmineSlackNotification
  module CommentThreads
    module_function

    def latest_thread(issue_id, channel, token)
      app_id = RedmineSlackNotification.effective_config.dig('slack', 'events', 'app_id')
      return if app_id.to_s.empty?

      cursor = nil
      # Bound API requests; do not retain a local thread mapping or scan the
      # entire channel. History is returned newest first.
      3.times do
        request = { 'channel' => channel, 'limit' => 100 }
        request['cursor'] = cursor if cursor
        response = RedmineSlackNotification.slack_api('conversations.history', request, token, form: true)
        Array(response['messages']).each do |message|
          next unless notification_for_issue?(message, issue_id, app_id)

          return message['ts']
        end
        cursor = response.dig('response_metadata', 'next_cursor').to_s.strip
        break if cursor.empty?
      end
      nil
    rescue StandardError => e
      # Lookup failure must not prevent delivery of the normal notification.
      Rails.logger&.warn("RedmineSlackNotification: comment thread lookup failed: #{e.class}")
      nil
    end

    def notification_for_issue?(message, issue_id, app_id)
      return false unless message.is_a?(Hash) && message['bot_id'] &&
                          (message['app_id'] || message.dig('bot_profile', 'app_id')) == app_id &&
                          message['ts'].to_s.match?(/\A\d+\.\d+\z/)
      # Ignore broadcast replies, which history can return as channel items.
      return false if message['thread_ts'] && message['thread_ts'] != message['ts']

      expected_url = Formatter.url("/issues/#{issue_id}")
      Array(message['attachments']).any? do |attachment|
        next false unless attachment.is_a?(Hash)

        subject = attachment.dig('blocks', 1, 'text', 'text').to_s
        match = subject.match(/\A\*<([^|>]+)\|/)
        match && match[1] == expected_url
      end
    end
  end
end
