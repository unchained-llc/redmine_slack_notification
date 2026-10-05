# frozen_string_literal: true

module Slackmine
  module ThreadComments
    module_function

    def enabled?(project)
      Slackmine.effective_config(project).dig('slack', 'thread_comments') == true
    end

    def reply_event?(event)
      event.is_a?(Hash) && event['type'] == 'message' &&
        [nil, '', 'thread_broadcast', 'file_share'].include?(event['subtype']) &&
        !event['bot_id'] && !event['app_id'] && !event['edited'] &&
        event['user'].to_s.match?(/\A[UW][A-Z0-9]+\z/) &&
        event['channel'].to_s.match?(/\A[CG][A-Z0-9]+\z/) &&
        event['thread_ts'].to_s.match?(/\A\d+\.\d+\z/) &&
        posted_at(event['ts']) && event['ts'] != event['thread_ts'] &&
        (event['text'].nil? || event['text'].is_a?(String)) &&
        (!event['text'].to_s.strip.empty? || Array(event['files']).any?)
    end

    def contexts(app_id, team_id, channel)
      base = Slackmine.config
      candidates = [nil]
      projects = base['projects']
      candidates.concat(projects.keys.map { |key| Project.find_by(identifier: key) }.compact) if projects.is_a?(Hash)
      auto_scopes = [base] + (projects.is_a?(Hash) ? projects.values.select { |value| value.is_a?(Hash) } : [])
      if auto_scopes.any? { |scope| scope.dig('slack', 'auto_map_channels_by_name') == true }
        candidates.concat(Project.active.to_a)
      end
      candidates.uniq.select do |project|
        settings = Slackmine.effective_config(project)
        slack = settings['slack']
        events = slack['events'] if slack.is_a?(Hash)
        configured_channel = project ? Slackmine.channel_id(project) : (slack['default_channel_id'] if slack.is_a?(Hash))
        slack.is_a?(Hash) && slack['thread_comments'] == true && events.is_a?(Hash) &&
          events['app_id'] == app_id && events['team_id'] == team_id && configured_channel == channel
      end
    end

    def accepted_reply?(app_id, team_id, event)
      reply_event?(event) && !contexts(app_id, team_id, event['channel']).empty?
    end

    def issue_from_parent(message, app_id, thread_ts)
      return unless message.is_a?(Hash) && message['ts'] == thread_ts && message['bot_id'] &&
                    (message['app_id'] || message.dig('bot_profile', 'app_id')) == app_id
      # Accept our subject section or our own Work Object unfurl. Never scan
      # user comments or arbitrary links for a target Issue.
      Array(message['attachments']).each do |attachment|
        next unless attachment.is_a?(Hash)
        if attachment['is_app_unfurl'] == true && attachment['app_id'] == app_id &&
           attachment['bot_id'] == message['bot_id']
          url = attachment['from_url'].to_s
          id = url.match(%r{/issues/([1-9]\d*)\z})
          if id && url == Formatter.url("/issues/#{id[1]}") && attachment['title_link'] == url
            return Issue.find_by(id: id[1].to_i)
          end
        end
        subject = attachment.dig('blocks', 1, 'text', 'text').to_s
        match = subject.match(/\A\*<([^|>]+)\|/)
        next unless match
        url = match[1]
        id = url.match(%r{/issues/([1-9]\d*)\z})
        next unless id && url == Formatter.url("/issues/#{id[1]}")
        return Issue.find_by(id: id[1].to_i)
      end
      issue_from_history_unfurl(message)
    end

    def issue_from_history_unfurl(message)
      # conversations.history may reduce an entity unfurl to from_url/id.
      # The parent app/bot was authenticated above. Bind this reduced URL to
      # the first Issue reference in our notification fallback, never notes.
      attachments = Array(message['attachments']).select { |item| item.is_a?(Hash) }
      notification = attachments.find { |item| item['blocks'].is_a?(Array) && item['fallback'].is_a?(String) }
      reference = notification && notification['fallback'].match(/(?:\A|\s)#([1-9]\d*):/)
      return unless reference

      urls = attachments.select { |item| (item.keys - %w[from_url id]).empty? }
                        .map { |item| item['from_url'] }.compact.uniq
      return unless urls == [Formatter.url("/issues/#{reference[1]}")]

      Issue.find_by(id: reference[1].to_i)
    end

    def process(app_id, team_id, event)
      return unless reply_event?(event)
      tried_tokens = []
      contexts(app_id, team_id, event['channel']).each do |context|
        token = Slackmine.bot_token(context)
        next if token.to_s.empty? || tried_tokens.include?(token)
        tried_tokens << token
        response = Slackmine.slack_api('conversations.history', {
          'channel' => event['channel'], 'oldest' => event['thread_ts'], 'latest' => event['thread_ts'],
          'inclusive' => true, 'limit' => 1
        }, token, form: true)
        issue = issue_from_parent(Array(response['messages']).first, app_id, event['thread_ts'])
        next unless issue && enabled?(issue.project) &&
                    Slackmine.channel_id(issue.project) == event['channel'] &&
                    WorkObjects.integration_for(app_id, team_id, project: issue.project) &&
                    Slackmine.bot_token(issue.project) == token

        Slackmine.with_project(issue.project) do
          result = persist_reply(issue, event, team_id)
          # A duplicate never creates a second Journal or a second feedback post.
          return if result == :duplicate
          key = result == :saved ? 'saved' : (result == :image_failed ? 'image_failed' : 'restricted')
          text = Formatter.interpolate(Formatter.message('thread_comments', key), { id: issue.id, product_name: Formatter.message('work_objects', 'product_name') },
                                       fallback: Formatter::DEFAULT_MESSAGES.dig('thread_comments', key))
          text = Formatter.link_issue_reference(text, issue.id)
          begin
            Slackmine.slack_api('chat.postMessage', {
              'channel' => event['channel'], 'thread_ts' => event['thread_ts'], 'text' => text,
              'unfurl_links' => false, 'unfurl_media' => false
            }, token)
          rescue StandardError => e
            # Saving already succeeded. Feedback failure must not replay a note.
            Rails.logger&.error("Slackmine: thread comment feedback failed: #{e.class}")
          end
          Rails.logger&.info("Slackmine: thread comment issue=#{issue.id} result=#{result}")
        end
        return
      end
      nil
    end

    def source_marker(team_id, event)
      "[Slack reply: #{team_id}/#{event['channel']}/#{event['ts']}]"
    end

    def posted_at(timestamp)
      match = timestamp.to_s.match(/\A(\d{1,12})\.(\d{1,6})\z/)
      return unless match
      # Parse integers, not a Float: current epoch values lose microseconds
      # when converted through floating point.
      Time.at(match[1].to_i, match[2].ljust(6, '0').to_i, :microsecond).utc
    end

    def persist_reply(issue, event, team_id)
      previous_user = User.current
      previous_origin = Thread.current[:slackmine_thread_comment]
      previous_images = Thread.current[:slackmine_thread_images]
      original_project = issue.project.identifier
      Thread.current[:slackmine_thread_comment] = true
      uploads = []
      timestamp = posted_at(event['ts'])
      return :restricted unless timestamp

      issue.with_lock do
        next :restricted unless issue.project.identifier == original_project && enabled?(issue.project)
        # Keep recognizing the initial version's visible markers on retries.
        marker = source_marker(team_id, event)
        legacy_duplicate = issue.journals.where('notes LIKE ?', "%#{marker}%").any? do |journal|
          journal.notes.to_s.end_with?("\n\n#{marker}")
        end
        next :duplicate if legacy_duplicate
        viewer = WorkObjects.viewer_for(event['user'])
        allowed = viewer && issue.project.active? && !issue.is_private? && issue.visible?(viewer) &&
                  issue.notes_addable?(viewer) && event['text'].to_s.length <= 10_000
        next :restricted unless allowed
        # The existing comment author and original posting time identify a
        # retry, even after the comment text has been edited in Redmine.
        next :duplicate if issue.journals.exists?(user_id: viewer.id, created_on: timestamp)
        next :restricted if Array(event['files']).any? && !issue.attachments_addable?(viewer)

        response = Slackmine.slack_api('chat.getPermalink',
          { 'channel' => event['channel'], 'message_ts' => event['ts'] },
          Slackmine.bot_token(issue.project), form: true)
        url = response['permalink'].to_s
        target = LinkCards.parse(url)
        next :restricted unless target && target['channel'] == event['channel'] &&
                                posted_at(target['ts']) == timestamp

        # History omits thread replies; preserve the parent timestamp so the
        # existing quote importer can retrieve this reply through replies API.
        uri = URI.parse(url)
        uri.query = URI.encode_www_form(URI.decode_www_form(uri.query.to_s).reject { |key, _| key == 'thread_ts' } +
                                       [['thread_ts', event['thread_ts']]])
        User.current = viewer
        journal = issue.init_journal(viewer, uri.to_s)
        uploads = ThreadImages.download(event, Slackmine.bot_token(issue.project))
        # The Issue row lock's transaction includes both attachments and Journal.
        # Validate every image before saving any, then use the Issue association
        # so Redmine records attachment additions in this same Journal.
        attachments = uploads.map { |file| Attachment.new(file: file, author: viewer) }
        attachments.each { |attachment| raise ActiveRecord::RecordInvalid.new(attachment) unless attachment.valid? }
        attachments.each do |attachment|
          attachment.save!
          issue.attachments << attachment
        end
        unless attachments.empty?
          images = attachments.map do |attachment|
            path = attachment.filename
            Setting.text_formatting == 'textile' ? "!#{path}!" : "![](#{path})"
          end
          journal.notes = uri.to_s + "\n\n" + images.join("\n\n")
        end
        journal.created_on = timestamp
        # A new imported note is not an edit. Redmine displays "edited" when
        # updated_on differs from created_on; later edits keep normal timestamps.
        journal.updated_on = timestamp
        Thread.current[:slackmine_thread_images] = { url: uri.to_s, ids: attachments.map(&:id) }
        issue.save!
        raise 'Slack reply Journal was not persisted' unless journal.persisted?
        :saved
      end
    rescue ThreadImages::ImportError => error
      Rails.logger&.warn("Slackmine: thread image rejected: #{error.message}")
      :image_failed
    rescue ActiveRecord::RecordInvalid
      :restricted
    ensure
      uploads.each(&:close!) if uploads
      User.current = previous_user
      Thread.current[:slackmine_thread_comment] = previous_origin
      Thread.current[:slackmine_thread_images] = previous_images
    end
  end
end
