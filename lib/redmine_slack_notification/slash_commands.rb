# frozen_string_literal: true

module RedmineSlackNotification
  module SlashCommands
    module_function

    PREFIX = 'redmine_command_'

    def message(key)
      value = Formatter.message('commands', key)
      return value unless key == 'help'

      command = RedmineSlackNotification.effective_config.dig('slack', 'slash_command').to_s
      value.gsub('%{command}') { Formatter.text(command.empty? ? '/redmine' : command) }
    end

    def integration?(app, team)
      events = RedmineSlackNotification.effective_config.dig('slack', 'events') || {}
      events['app_id'] == app && events['team_id'] == team && WorkObjects.integration_for(app, team)
    end

    def enabled?(project = nil)
      RedmineSlackNotification.effective_config(project).dig('slack', 'slash_command').to_s.start_with?('/')
    end

    def authorized_project?(project, app, team)
      project.active? && enabled?(project) && WorkObjects.integration_for(app, team, project: project)
    end

    def button(label, command)
      { 'type' => 'button', 'text' => { 'type' => 'plain_text', 'text' => label },
        'action_id' => PREFIX + 'run_' + Digest::SHA256.hexdigest(command), 'value' => command }
    end

    def section(text)
      Formatter.section_text(text)
    end

    def issue_blocks(issue, actions: true)
      blocks = [section("<#{Formatter.url("/issues/#{issue.id}")}|##{issue.id} #{Formatter.text(issue.subject)}>\n#{Formatter.text(issue.status.name)}")]
      if actions
        blocks << { 'type' => 'actions', 'elements' => [button(message('comment'), "comment #{issue.id}")] }
      end
      blocks
    end

    def run(app, team, user_id, channel, text)
      viewer = WorkObjects.viewer_for(user_id)
      return [section(message('denied'))] unless viewer
      command, argument = text.to_s.strip.split(/\s+/, 2)
      case command
      when nil, '', 'help'
        [section(message('help')), { 'type' => 'actions', 'elements' => %w[my due reminders new].map { |key| button(message(key), key) } }]
      when 'new'
        projects = Project.allowed_to(viewer, :add_issues).where(status: Project::STATUS_ACTIVE).order(:name).to_a
        projects.select! { |project| authorized_project?(project, app, team) }
        projects.select! { |project| project.identifier == argument } if argument && !argument.empty?
        return [section(message('empty'))] if projects.empty?
        # Prefer the current channel's project without excluding other choices.
        projects.sort_by! { |project| RedmineSlackNotification.channel_id(project) == channel ? 0 : 1 }
        [section(message('choose_project'))] + projects.first(20).map do |project|
          { 'type' => 'section', 'text' => { 'type' => 'plain_text', 'text' => project.name.to_s[0, 200] },
            'accessory' => button(message('new'), "create #{project.id}") }
        end
      when 'my', 'due', 'search'
        return [section(message('help'))] if command == 'search' && argument.to_s.strip.empty?
        scope = Issue.visible(viewer)
        if command == 'search'
          scope = scope.where('LOWER(issues.subject) LIKE ?', "%#{Issue.sanitize_sql_like(argument.downcase)}%")
        else
          scope = scope.open.where(assigned_to_id: viewer.id)
          scope = scope.where('issues.due_date <= ?', Date.current + 3).order(:due_date) if command == 'due'
        end
        rows = scope.order(updated_on: :desc).limit(100).to_a.select { |issue| authorized_project?(issue.project, app, team) }.first(10)
        return yield(rows.first) if rows.one? && block_given?
        rows.empty? ? [section(message('empty'))] : issue_list_payload(rows, command)
      else
        id = command.to_s.sub(/\A#/, '')
        return [section(message('help'))] unless id.match?(/\A[1-9]\d*\z/)
        issue = Issue.find_by(id: id)
        return [section(message('denied'))] unless issue && issue.visible?(viewer) && authorized_project?(issue.project, app, team)
        block_given? ? yield(issue) : issue_blocks(issue)
      end
    end

    def issue_list_payload(issues, command)
      { 'text' => message('results'),
        'blocks' => [section("📋 *#{Formatter.text(message('results'))}*")],
        'attachments' => [Formatter.due_digest_attachment(message(command), issues, Date.current,
                                                         Formatter.due_reminder_color('upcoming'))] }
    end

    def deliver(app, team, payload)
      return unless enabled? && integration?(app, team)
      text = payload['text'].to_s
      return deliver_reminders(app, team, payload) if text.strip == 'reminders'
      # Modal commands first show a button, so queued work never uses an expired trigger_id.
      result = if text.match?(/\Acomment\s+#?[1-9]\d*\s*\z/)
                 [{ 'type' => 'actions', 'elements' => [button(message('comment'), text.strip)] }]
               else
                 run(app, team, payload['user_id'], payload['channel_id'], text) { |issue| single_issue_payload(issue) }
               end
      result = { 'text' => message('results'), 'blocks' => result } if result.is_a?(Array)
      RedmineSlackNotification.slack_api('chat.postEphemeral', result.merge(
        'channel' => payload['channel_id'], 'user' => payload['user_id']
      ), RedmineSlackNotification.bot_token)
    end

    def single_issue_payload(issue)
      fallback = { 'text' => message('results'), 'blocks' => issue_blocks(issue) }
      global_token = RedmineSlackNotification.bot_token
      RedmineSlackNotification.with_project(issue.project) do
        return fallback unless RedmineSlackNotification.effective_config.dig('slack', 'work_object_previews') == true
        return fallback if issue.is_private? || RedmineSlackNotification.bot_token(issue.project) != global_token

        card = Formatter.with_issue_work_object({}, issue, actor: nil, action: 'updated')
        return fallback unless card.dig('metadata', 'entities')&.any?
        { 'text' => "##{issue.id} #{issue.subject}", 'metadata' => card['metadata'] }
      end
    end

    def deliver_reminders(app, team, payload)
      viewer = WorkObjects.viewer_for(payload['user_id'])
      token = RedmineSlackNotification.bot_token
      recipient = { 'channel' => payload['channel_id'], 'user' => payload['user_id'] }
      unless viewer
        return RedmineSlackNotification.slack_api('chat.postEphemeral', recipient.merge('text' => message('denied')), token)
      end

      today = Date.current
      groups = RedmineSlackDueDigestJob.new.due_issues_for(viewer, today)
      issues = groups.fetch([token, payload['user_id']], []).select do |issue|
        authorized_project?(issue.project, app, team)
      end.sort_by { |issue| [issue.due_date, issue.project.name, issue.id] }
      if issues.empty?
        return RedmineSlackNotification.slack_api('chat.postEphemeral', recipient.merge('text' => message('reminders_empty')), token)
      end

      size = RedmineSlackDueDigestJob::MAX_ISSUES_PER_MESSAGE
      issues.each_slice(size).with_index do |batch, index|
        sleep(1) if index.positive?
        digest = RedmineSlackNotification.with_project(batch.first.project) do
          Formatter.due_digest_payload(batch, today: today, part: index + 1,
                                      total_parts: (issues.size + size - 1) / size)
        end
        RedmineSlackNotification.slack_api('chat.postEphemeral', digest.merge(recipient), token)
      end
    end

    def handles?(payload)
      payload.dig('view', 'callback_id').to_s.start_with?(PREFIX) ||
        Array(payload['actions']).any? { |action| action.is_a?(Hash) && action['action_id'].to_s.start_with?(PREFIX) }
    end

    def input(key, label, element, optional: false)
      { 'type' => 'input', 'block_id' => key, 'optional' => optional,
        'label' => { 'type' => 'plain_text', 'text' => label }, 'element' => element.merge('action_id' => key) }
    end

    def field(key, multiline: false)
      input(key, message(key), { 'type' => 'plain_text_input', 'multiline' => multiline,
                                'max_length' => multiline ? 3000 : 255 }, optional: key == 'description')
    end

    def modal(kind, id, viewer)
      blocks = if kind == 'create'
                 project = Project.find_by(id: id)
                 trackers = Issue.new(project: project, author: viewer).allowed_target_trackers(viewer).to_a
                 return if trackers.empty? || trackers.length > 100
                 options = trackers.map { |t| { 'text' => { 'type' => 'plain_text', 'text' => t.name.to_s[0, 75] }, 'value' => t.id.to_s } }
                 [section("<#{Formatter.url("/projects/#{project.identifier}/issues/new")}|#{Formatter.text(message('full_form'))}>"), input('tracker', message('tracker'), { 'type' => 'static_select', 'options' => options }), field('subject'), field('description', multiline: true)]
               else
                 [field('comment', multiline: true)]
               end
      { 'type' => 'modal', 'callback_id' => PREFIX + kind, 'private_metadata' => id.to_s,
        'title' => { 'type' => 'plain_text', 'text' => message(kind == 'create' ? 'new' : 'comment') },
        'submit' => { 'type' => 'plain_text', 'text' => message('save') },
        'close' => { 'type' => 'plain_text', 'text' => message('cancel') }, 'blocks' => blocks }
    end

    def interaction(app, team, payload)
      previous = User.current
      return {} unless enabled? && integration?(app, team)
      viewer = WorkObjects.viewer_for(payload.dig('user', 'id'))
      unless viewer
        key = payload.dig('view', 'callback_id') == PREFIX + 'create' ? 'subject' : 'comment'
        return payload['type'] == 'view_submission' ? { 'response_action' => 'errors', 'errors' => { key => message('denied') } } : {}
      end
      if payload['type'] == 'block_actions'
        command = Array(payload['actions']).first&.fetch('value', '').to_s
        kind, id = command.split(/\s+/, 2)
        id = id.to_s.sub(/\A#/, '')
        if %w[create comment].include?(kind) && id.match?(/\A[1-9]\d*\z/)
          object = kind == 'create' ? Project.find_by(id: id) : Issue.find_by(id: id)
          project = kind == 'create' ? object : object&.project
          allowed = object && project && authorized_project?(project, app, team) &&
                    (kind == 'create' ? viewer.allowed_to?(:add_issues, project) : object.visible?(viewer) && object.notes_addable?(viewer) && !object.is_private?)
          return {} unless allowed
          view = modal(kind, id, viewer)
          return {} unless view
          RedmineSlackNotification.slack_api('views.open', { 'trigger_id' => payload['trigger_id'], 'view' => view }, RedmineSlackNotification.bot_token)
        else
          RedmineSlackCommandJob.perform_later(app, team, { 'user_id' => payload.dig('user', 'id'),
            'channel_id' => payload.dig('channel', 'id'), 'text' => command })
        end
        return {}
      end
      return {} unless payload['type'] == 'view_submission'
      view = payload.fetch('view')
      kind = view['callback_id'].delete_prefix(PREFIX)
      id = view['private_metadata'].to_s
      return {} unless id.match?(/\A[1-9]\d*\z/)
      values = view.dig('state', 'values') || {}
      error_key = kind == 'create' ? 'subject' : 'comment'
      User.current = viewer
      return { 'response_action' => 'errors', 'errors' => { error_key => message('denied') } } if view['id'].to_s.empty?
      key = "redmine_slack:submission:#{Digest::SHA256.hexdigest([app, team, viewer.id, view['id']].join(':'))}"
      cache = Rails.cache
      return {} if cache.read(key) == 'done'
      unless cache.write(key, 'pending', unless_exist: true, expires_in: 300)
        return { 'response_action' => 'errors', 'errors' => { error_key => message('processing') } }
      end
      result = save_form(kind, id, values, viewer, app, team, error_key)
      if result.empty?
        cache.write(key, 'done', expires_in: 86_400)
      else
        cache.delete(key)
      end
      result
    ensure
      User.current = previous
    end

    def save_form(kind, id, values, viewer, app, team, error_key)
      if kind == 'create'
        project = Project.find_by(id: id)
        if project && authorized_project?(project, app, team) && viewer.allowed_to?(:add_issues, project)
          issue = Issue.new(project: project, author: viewer)
          attrs = { 'subject' => values.dig('subject', 'subject', 'value'),
                    'description' => values.dig('description', 'description', 'value'),
                    'tracker_id' => values.dig('tracker', 'tracker', 'selected_option', 'value') }
          return { 'response_action' => 'errors', 'errors' => { error_key => message('denied') } } unless attrs['subject'].is_a?(String) && attrs['subject'].length.between?(1, 255) && attrs['description'].to_s.length <= 3000
          if issue.allowed_target_trackers(viewer).any? { |tracker| tracker.id.to_s == attrs['tracker_id'] }
            issue.send(:safe_attributes=, attrs, viewer)
            return {} if issue.save
            return { 'response_action' => 'errors', 'errors' => { error_key => issue.errors.full_messages.join('; ')[0, 1500] } }
          end
        end
      elsif kind == 'comment'
        issue = Issue.find_by(id: id)
        note = values.dig('comment', 'comment', 'value').to_s.strip
        if issue && authorized_project?(issue.project, app, team) && !note.empty? && note.length <= 3000
          outcome = WorkObjects.update_issue(issue, viewer, comment: note)
          return {} if outcome == :saved
        end
      end
      { 'response_action' => 'errors', 'errors' => { error_key => message('denied') } }
    end
  end
end
