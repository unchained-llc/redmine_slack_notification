# frozen_string_literal: true

module Slackmine
  module ThreadCommentBatch
    MAX_MESSAGES = 20
    module_function

    def timing(project)
      settings = Slackmine.effective_config(project).dig('slack', 'thread_comment_batch') || {}
      settings = {} unless settings.is_a?(Hash)
      wait = seconds(settings['wait_seconds'], 0)
      [wait, [seconds(settings['max_wait_seconds'], 300), wait].max]
    end

    def seconds(value, default)
      value.is_a?(Numeric) && value.finite? && value >= 0 ? [value.to_f, 3600].min : default
    end

    def schedule(app_id, team_id, event, wait)
      SlackmineThreadCommentJob.set(wait: wait).perform_later(app_id, team_id, event, true)
      :waiting
    end

    def collect(issue, app_id, team_id, event)
      wait, maximum = timing(issue.project)
      return [event] if wait.zero?
      # Slack is the buffer. Every job reconstructs the same deterministic
      # group; the existing Issue lock + first-post Journal identity deduplicates it.
      messages = []
      cursor = nil
      10.times do
        body = { 'channel' => event['channel'], 'ts' => event['thread_ts'], 'limit' => 100 }
        body['cursor'] = cursor if cursor
        response = Slackmine.slack_api('conversations.replies', body, Slackmine.bot_token(issue.project), form: true)
        messages.concat(Array(response['messages']))
        cursor = response.dig('response_metadata', 'next_cursor').to_s
        break if cursor.empty? && !response['has_more']
        # Never form an inconsistent batch from truncated history.
        raise 'Slack thread batching history is incomplete' if cursor.empty?
      end
      raise 'Slack thread batching history exceeds 1000 messages' unless cursor.to_s.empty?
      replies = messages.select { |message| message.is_a?(Hash) }.map do |message|
        message.merge('type' => 'message', 'channel' => event['channel'], 'thread_ts' => event['thread_ts'])
      end.select { |message| ThreadComments.reply_event?(message) }
         .uniq { |message| message['ts'] }.sort_by { |message| ThreadComments.posted_at(message['ts']) }
      # The accepted event remains authoritative if Slack history has changed.
      return [event] unless replies.any? { |reply| reply['ts'] == event['ts'] }
      groups = []
      replies.each do |reply|
        time = ThreadComments.posted_at(reply['ts'])
        current = groups.last
        if current.nil? || current.last['user'] != reply['user'] || current.size >= MAX_MESSAGES ||
           time - ThreadComments.posted_at(current.last['ts']) >= wait ||
           time - ThreadComments.posted_at(current.first['ts']) >= maximum
          groups << [reply]
        else
          current << reply
        end
      end
      index = groups.index { |items| items.any? { |reply| reply['ts'] == event['ts'] } }
      group = groups[index]
      # A later group closes this run. Do not let A -> B -> A merge A's
      # separate turns, or extend a closed turn's deadline.
      now = Time.now.utc
      return group if index < groups.size - 1 && ThreadComments.posted_at(groups[index + 1].first['ts']) <= now
      deadline = [ThreadComments.posted_at(group.last['ts']) + wait,
                  ThreadComments.posted_at(group.first['ts']) + maximum].min
      remaining = deadline - now
      if remaining > 0 && group.size < MAX_MESSAGES
        schedule(app_id, team_id, event, remaining)
        return nil
      end
      group
    end
  end
end
