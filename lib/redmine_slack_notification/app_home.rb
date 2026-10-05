# frozen_string_literal: true

module RedmineSlackNotification
  module AppHome
    module_function

    PREFIX = 'redmine_home_'
    SECTIONS = %w[updated this_week my reported].freeze
    FILTERS = (['all'] + SECTIONS).freeze
    LIMIT = 10

    def message(key)
      Formatter.message('app_home', key)
    end

    # Home uses the shared app and identity mapping. Project overrides can
    # exclude data, but cannot switch the viewer to a different Redmine user.
    def enabled?(app, team)
      settings = RedmineSlackNotification.effective_config(nil).dig('slack') || {}
      settings['app_home'] == true && settings.dig('events', 'app_id') == app &&
        settings.dig('events', 'team_id') == team && WorkObjects.integration_for(app, team) &&
        !RedmineSlackNotification.bot_token(nil).to_s.empty?
    end

    def handles?(payload)
      payload['type'] == 'block_actions' && payload.dig('view', 'type') == 'home' &&
        payload.dig('view', 'callback_id') == 'redmine_home' &&
        Array(payload['actions']).one? && payload['actions'].first.is_a?(Hash) &&
        payload['actions'].first['action_id'].to_s.match?(/\Aredmine_home_(?:filter|refresh|detail(?:_[1-9]\d*)?)\z/)
    end

    def allowed_projects(viewer, app, team, slack_id)
      identities = { identity_settings(nil) => viewer }
      Project.allowed_to(viewer, :view_issues).where(status: Project::STATUS_ACTIVE).to_a.select do |project|
        next false unless project_enabled?(project, app, team)
        RedmineSlackNotification.with_project(project) do
          key = identity_settings(project)
          identities[key] = WorkObjects.viewer_for(slack_id) unless identities.key?(key)
          mapped = identities[key]
          mapped && mapped.id == viewer.id
        end
      end.map(&:id)
    end

    # Reuse fresh identity checks only within this publish operation, avoiding
    # one users.info request per project when all share the same configuration.
    def identity_settings(project)
      settings = RedmineSlackNotification.effective_config(project)
      [settings['users'], settings.dig('slack', 'auto_map_users_by_email'), RedmineSlackNotification.bot_token(project)]
    end

    def project_enabled?(project, app, team)
      project.active? && RedmineSlackNotification.effective_config(project).dig('slack', 'app_home') == true &&
        WorkObjects.integration_for(app, team, project: project)
    end

    def button(text, action, value)
      { 'type' => 'button', 'text' => { 'type' => 'plain_text', 'text' => text },
        'action_id' => PREFIX + action, 'value' => value }
    end

    def view(viewer, app, team, slack_id, filter, notice: nil)
      options = FILTERS.map { |key| { 'text' => { 'type' => 'plain_text', 'text' => message(key) }, 'value' => key } }
      blocks = [{ 'type' => 'header', 'text' => { 'type' => 'plain_text', 'text' => message('title') } },
                { 'type' => 'actions', 'block_id' => PREFIX + 'controls_' + filter, 'elements' => [
                  { 'type' => 'static_select', 'action_id' => PREFIX + 'filter', 'options' => options,
                    'initial_option' => options.find { |option| option['value'] == filter } },
                  button(message('refresh'), 'refresh', filter)
                ] }]
      blocks << Formatter.section_text(Formatter.text(notice)) if notice
      unless viewer
        blocks << Formatter.section_text(Formatter.text(message('unmapped')))
        return home_view(blocks, filter)
      end
      projects = allowed_projects(viewer, app, team, slack_id)
      sections = filter == 'all' ? SECTIONS : [filter]
      sections.each do |key|
        add_group(blocks, key, my_page_rows(viewer, projects, key))
      end
      blocks << { 'type' => 'context', 'elements' => [{ 'type' => 'plain_text', 'text' => message('limit') }] }
      home_view(blocks, filter)
    end

    # Use Redmine's query engine so "me" includes group assignments and the
    # week/date, journal visibility, issue visibility and sort rules match My Page.
    def my_page_rows(viewer, projects, key)
      previous_user = User.current
      User.current = viewer
      query = IssueQuery.new(name: message(key), user: viewer)
      query.add_filter('status_id', 'o', [''])
      query.add_filter('project.status', '=', [Project::STATUS_ACTIVE.to_s])
      case key
      when 'updated'
        query.add_filter('updated_by', '=', ['me'])
      when 'this_week'
        query.add_filter('assigned_to_id', '=', ['me'])
        query.add_filter('due_date', 'w', [''])
      when 'my'
        query.add_filter('assigned_to_id', '=', ['me'])
      when 'reported'
        query.add_filter('author_id', '=', ['me'])
      end
      query.column_names = ['subject']
      query.sort_criteria = case key
                            when 'this_week' then [['project', 'asc']]
                            when 'my' then [['priority', 'desc'], ['updated_on', 'desc']]
                            else [['updated_on', 'desc']]
                            end
      query.issues(limit: LIMIT + 1, include: [:assigned_to], conditions: { project_id: projects })
    ensure
      User.current = previous_user
    end

    def home_view(blocks, filter)
      { 'type' => 'home', 'callback_id' => 'redmine_home', 'private_metadata' => filter, 'blocks' => blocks }
    end

    def add_group(blocks, key, scope)
      rows = scope.is_a?(Array) ? scope : scope.includes(:project, :status, :assigned_to).limit(LIMIT + 1).to_a
      count = rows.length > LIMIT ? "#{LIMIT}+" : rows.length.to_s
      blocks << { 'type' => 'divider' }
      caption = "#{message(key)} · #{count}"
      if rows.empty?
        blocks << Formatter.section_text("*#{Formatter.text(caption)}*")
        blocks << Formatter.section_text(Formatter.text(message('empty')))
        return
      end
      edit_label = Formatter.message('work_objects', 'edit_issue').to_s[0, 40]
      headers = (%w[subject status assignee due_date].map { |label| Formatter.field_label(label).to_s[0, 40] } +
                  [edit_label]).map { |label| { 'type' => 'raw_text', 'text' => label } }
      table_rows = rows.first(LIMIT).map do |issue|
        assignee = issue.assigned_to ? issue.assigned_to.name : Formatter.message('values', 'unassigned')
        due_date = issue.due_date ? issue.due_date.iso8601 : '—'
        title = { 'type' => 'rich_text', 'elements' => [{ 'type' => 'rich_text_section', 'elements' => [
          { 'type' => 'link', 'url' => Formatter.url("/issues/#{issue.id}"),
            'text' => "##{issue.id} #{issue.subject}"[0, 200], 'style' => { 'bold' => true } },
          { 'type' => 'text', 'text' => "\n#{issue.project.name.to_s[0, 60]}" }
        ] }] }
        status = { 'type' => 'raw_text', 'text' => issue.status.name.to_s[0, 60] }
        assigned = { 'type' => 'raw_text', 'text' => assignee.to_s[0, 60] }
        due = { 'type' => 'raw_text', 'text' => due_date }
        edit = { 'type' => 'action_cell',
                 'element' => button(edit_label, "detail_#{issue.id}", issue.id.to_s),
                 'fallback' => { 'type' => 'raw_text', 'text' => edit_label } }
        [title, status, assigned, due, edit]
      end
      blocks << { 'type' => 'data_table', 'block_id' => PREFIX + key, 'caption' => caption,
                  'page_size' => 5, 'rows' => [headers] + table_rows }
    end

    def publish(app, team, slack_id, filter = 'all', notice: nil)
      return unless FILTERS.include?(filter)
      RedmineSlackNotification.with_project(nil) do
        return unless enabled?(app, team) && slack_id.to_s.match?(/\A[UW][A-Z0-9]+\z/)
        viewer = WorkObjects.viewer_for(slack_id)
        RedmineSlackNotification.slack_api('views.publish', {
          'user_id' => slack_id, 'view' => view(viewer, app, team, slack_id, filter, notice: notice)
        }, RedmineSlackNotification.bot_token(nil), form: true)
      end
    end

    def interaction(app, team, payload)
      return {} unless handles?(payload)
      action = payload['actions'].first
      user_id = payload.dig('user', 'id')
      if action['action_id'].start_with?(PREFIX + 'detail')
        open_detail(app, team, user_id, action['value'], payload['trigger_id'], payload.dig('view', 'private_metadata'))
      else
        # A refresh can arrive before the selected filter's publish completes.
        # Read this control's state rather than the button's previous value;
        # Slack can also retain state entries from earlier control blocks.
        filter = if action['action_id'] == PREFIX + 'filter'
                   action.dig('selected_option', 'value')
                 else
                   payload.dig('view', 'state', 'values', action['block_id'], PREFIX + 'filter', 'selected_option', 'value') || action['value']
                 end
        if FILTERS.include?(filter) && enabled?(app, team)
          RedmineSlackAppHomeJob.perform_later(app, team, user_id, filter)
        end
      end
      {}
    end

    def open_detail(app, team, slack_id, id, trigger, filter)
      return unless id.is_a?(String) && id.match?(/\A[1-9]\d*\z/) && !trigger.to_s.empty? && FILTERS.include?(filter)
      RedmineSlackNotification.with_project(nil) do
        return unless enabled?(app, team)
        viewer = WorkObjects.viewer_for(slack_id)
        issue = Issue.find_by(id: id.to_i)
        return unless viewer && issue && issue.visible?(viewer) && project_enabled?(issue.project, app, team)
        form = nil
        RedmineSlackNotification.with_project(issue.project) do
          mapped = WorkObjects.viewer_for(slack_id)
          return unless mapped && mapped.id == viewer.id
          source = { 'entity_url' => Formatter.url("/issues/#{issue.id}"), 'app_home' => filter }
          source['external_ref'] = { 'type' => 'redmine_issue', 'id' => Digest::SHA256.hexdigest(source['entity_url']) }
          if !issue.is_private? && WorkObjects.actions_enabled?(issue) &&
             RedmineSlackNotification.effective_config.dig('slack', 'work_object_previews') == true
            keys = WorkObjects.button_keys(issue, detail: true)
            form = WorkObjects.edit_modal(issue, viewer, source) if keys.include?('edit_issue')
            form ||= WorkObjects.edit_modal(issue, viewer, source, comment_only: true) if keys.include?('add_comment')
          end
        end
        summary = Formatter.section_text("*##{issue.id} #{Formatter.text(issue.subject.to_s[0, 200])}*\n" \
          "#{Formatter.text(issue.status.name)}\n<#{Formatter.url("/issues/#{issue.id}")}|#{Formatter.text(message('open'))}>")
        form ||= { 'type' => 'modal', 'title' => { 'type' => 'plain_text', 'text' => message('detail') },
                   'close' => { 'type' => 'plain_text', 'text' => Formatter.message('work_objects', 'cancel') }, 'blocks' => [] }
        form['blocks'].unshift(summary)
        RedmineSlackNotification.slack_api('views.open', { 'trigger_id' => trigger, 'view' => form },
                                         RedmineSlackNotification.bot_token(nil), form: true)
      end
    end
  end
end
