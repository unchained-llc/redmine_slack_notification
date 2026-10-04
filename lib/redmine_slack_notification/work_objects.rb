# frozen_string_literal: true

require 'openssl'

module RedmineSlackNotification
  module WorkObjects
    module_function

    def integrations
      scopes = [RedmineSlackNotification.config]
      projects = RedmineSlackNotification.config['projects']
      if projects.is_a?(Hash)
        projects.each_value do |override|
          scopes << RedmineSlackNotification.merge_config(scopes.first, override) if override.is_a?(Hash)
        end
      end
      scopes.map do |scope|
        slack = scope['slack']
        next unless slack.is_a?(Hash)

        events = slack['events']
        next unless events.is_a?(Hash)

        secret = events['signing_secret'].to_s.strip
        secret = ENV['SLACK_SIGNING_SECRET'].to_s.strip if secret.empty?
        next if secret.empty? || events['app_id'].to_s.empty? || events['team_id'].to_s.empty?

        events.merge('signing_secret' => secret)
      end.compact.uniq
    end

    def verified_integration(body, timestamp, signature, now: Time.now.to_i, app_id: nil, team_id: nil)
      return unless timestamp.to_s.match?(/\A\d+\z/) && (now - timestamp.to_i).abs <= 300
      return unless signature.to_s.match?(/\Av0=[0-9a-f]{64}\z/)

      integrations.find do |integration|
        next false if app_id && integration['app_id'] != app_id
        next false if team_id && integration['team_id'] != team_id
        digest = OpenSSL::HMAC.hexdigest('SHA256', integration.fetch('signing_secret'), "v0:#{timestamp}:#{body}")
        # Fixed-size, constant-time comparison (also supports older OpenSSL gems).
        "v0=#{digest}".bytes.zip(signature.bytes).reduce(0) { |difference, (left, right)| difference | (left ^ right) }.zero?
      end
    end

    def integration_for(app_id, team_id, project: nil)
      if project
        slack = RedmineSlackNotification.effective_config(project)['slack']
        events = slack['events'] if slack.is_a?(Hash)
        return unless events.is_a?(Hash) && events['app_id'] == app_id && events['team_id'] == team_id
      end
      integrations.find { |integration| integration['app_id'] == app_id && integration['team_id'] == team_id }
    end

    def issue_for(event)
      value = event['entity_url'].to_s
      match = value.match(%r{/issues/([1-9]\d*)\z})
      return unless match && value == Formatter.url("/issues/#{match[1]}")
      reference = event['external_ref']
      return unless reference.is_a?(Hash) && reference['type'] == 'redmine_issue' &&
                    reference['id'] == Digest::SHA256.hexdigest(value)

      Issue.find_by(id: match[1].to_i)
    end

    def actions_enabled?(issue)
      ids = RedmineSlackNotification.effective_config.dig('slack', 'work_object_actions', 'issue_ids')
      ids.is_a?(Array) && ids.any? { |id| id.to_s == issue.id.to_s }
    end

    def editable_metadata(issue, viewer)
      metadata = Formatter.issue_work_object_details(issue)
      return metadata unless actions_enabled?(issue)

      fields = metadata.fetch('entity_payload').fetch('fields')
      if issue.attributes_editable?(viewer) && issue.safe_attribute?('status_id', viewer)
        statuses = issue.new_statuses_allowed_to(viewer)
        if statuses.any? { |status| status.id == issue.status_id }
          fields['status']['edit'] = {
            'enabled' => true,
            'select' => {
              'current_value' => issue.status_id.to_s,
              'static_options' => statuses.map { |status| {
                'value' => status.id.to_s,
                'text' => { 'type' => 'plain_text', 'text' => status.name.to_s }
              } }
            }
          }
        end
      end
      if issue.notes_addable?(viewer)
        metadata.fetch('entity_payload').fetch('custom_fields') << {
          'key' => 'new_comment', 'label' => 'コメントを追加', 'type' => 'string', 'value' => '',
          'edit' => { 'enabled' => true, 'optional' => true,
                      'text' => { 'max_length' => 3000 },
                      'placeholder' => { 'type' => 'plain_text', 'text' => 'コメントを入力' } }
        }
      end
      if issue.attributes_editable?(viewer) && issue.safe_attribute?('assigned_to_id', viewer) &&
         issue.assignable_users.include?(viewer)
        metadata.fetch('entity_payload')['actions'] = {
          'primary_actions' => [{ 'text' => '自分に割り当てる', 'action_id' => 'redmine_assign_to_me' }]
        }
      end
      metadata
    end

    # Explicit mappings take priority. Optional email matching never uses
    # display names to authorize access to Redmine data.
    def viewer_for(slack_id)
      return unless slack_id.to_s.match?(/\A[UW][A-Z0-9]+\z/)

      mapping = RedmineSlackNotification.user_mapping
      explicit_keys = mapping.select { |_key, value| value == slack_id }.keys
      unless explicit_keys.empty?
        users = explicit_keys.map do |key|
          User.find_by(login: key.to_s) || User.find_by(mail: key.to_s)
        end.compact.uniq { |user| user.id }
        return users.first if users.length == 1 && users.first.active?
        return nil
      end
      viewer_by_email(slack_id, mapping)
    end

    def viewer_by_email(slack_id, mapping)
      settings = RedmineSlackNotification.effective_config
      return unless settings.dig('slack', 'auto_map_users_by_email') == true
      token = RedmineSlackNotification.bot_token
      return if token.to_s.empty?

      # Fetch fresh identity data for each authorization; do not persist emails
      # or cache permissions in Redis, files, or process memory.
      response = RedmineSlackNotification.slack_api('users.info', { 'user' => slack_id }, token,
        form: true, open_timeout: 2, read_timeout: 3)
      member = response['user']
      return unless member.is_a?(Hash) && member['id'] == slack_id
      return if member['deleted'] || member['is_bot'] || member['is_app_user'] || member['is_stranger']
      team_id = settings.dig('slack', 'events', 'team_id').to_s
      return if !team_id.empty? && (member['team_id'] || member['team']) != team_id
      email = member.dig('profile', 'email').to_s.strip.downcase
      return if email.empty?

      users = User.active.joins(:email_addresses).where('LOWER(email_addresses.address) = ?', email).distinct.limit(2).to_a
      return unless users.length == 1
      viewer = users.first
      # A manual mapping of this Redmine identity to another Slack user wins.
      assigned = [mapping[viewer.login.to_s], mapping[viewer.mail.to_s]].select do |value|
        value.is_a?(String) && value.match?(/\A[UW][A-Z0-9]+\z/)
      end
      return if assigned.any? { |value| value != slack_id }

      viewer if viewer.active?
    rescue StandardError => e
      Rails.logger&.warn("RedmineSlackNotification: email user matching failed: #{e.class}")
      nil
    end

    def present_details(app_id, team_id, event)
      return unless event.is_a?(Hash) && event['type'] == 'entity_details_requested'
      return if event['trigger_id'].to_s.empty?
      issue = issue_for(event)
      return unless issue && integration_for(app_id, team_id, project: issue.project)

      RedmineSlackNotification.with_project(issue.project) do
        token = RedmineSlackNotification.bot_token(issue.project)
        return if token.to_s.empty?

        viewer = viewer_for(event['user'])
        allowed = RedmineSlackNotification.effective_config.dig('slack', 'work_object_previews') == true &&
                  issue.project.active? && !issue.is_private? && viewer && issue.visible?(viewer)
        request = { 'trigger_id' => event['trigger_id'] }
        if allowed
          request['metadata'] = editable_metadata(issue, viewer)
        else
          request['error'] = { 'status' => 'restricted' }
        end
        result = RedmineSlackNotification.slack_api('entity.presentDetails', request, token, form: true)
        Rails.logger&.info("RedmineSlackNotification: Work Object details issue=#{issue.id} result=#{allowed ? 'shown' : 'restricted'} warnings=#{Array(result['warnings']).inspect} messages=#{Array(result.dig('response_metadata', 'messages')).inspect}")
        result
      end
    end

    def process_interaction(app_id, team_id, payload)
      return unless payload.is_a?(Hash) && %w[block_actions view_submission].include?(payload['type'])
      source = payload['type'] == 'block_actions' ? payload['container'] : payload['view']
      return unless source.is_a?(Hash) && source['type'] == 'entity_detail'
      event = { 'entity_url' => source['entity_url'], 'external_ref' => source['external_ref'] }
      issue = issue_for(event)
      return unless issue && integration_for(app_id, team_id, project: issue.project)

      RedmineSlackNotification.with_project(issue.project) do
        return unless RedmineSlackNotification.effective_config.dig('slack', 'work_object_previews') == true &&
                      actions_enabled?(issue) && issue.project.active? && !issue.is_private?
        viewer = viewer_for(payload.dig('user', 'id'))
        return unless viewer && issue.visible?(viewer)

        outcome = if payload['type'] == 'block_actions'
          actions = payload['actions']
          return unless actions.is_a?(Array) && actions.length == 1
          action = actions.first
          return unless action.is_a?(Hash) && action['action_id'] == 'redmine_assign_to_me'
          update_issue(issue, viewer, assigned_to_id: viewer.id)
        else
          values = source.dig('state', 'values')
          return unless values.is_a?(Hash)
          status = values.dig('status', 'status.input', 'selected_option', 'value')
          comment = values.dig('new_comment', 'new_comment.input', 'value')
          return unless status.nil? || status.to_s.match?(/\A[1-9]\d*\z/)
          return unless comment.nil? || (comment.is_a?(String) && comment.length <= 3000)
          update_issue(issue, viewer, status_id: status, comment: comment)
        end
        Rails.logger&.info("RedmineSlackNotification: Work Object interaction issue=#{issue.id} result=#{outcome}")
        trigger = payload['trigger_id'].to_s
        return if trigger.empty?
        token = RedmineSlackNotification.bot_token(issue.project)
        return if token.to_s.empty?
        request = { 'trigger_id' => trigger }
        if outcome == :saved || outcome == :unchanged
          issue.reload
          request['metadata'] = editable_metadata(issue, viewer)
        else
          request['error'] = { 'status' => 'edit_error', 'custom_message' => 'この操作を実行できませんでした。権限と現在の状態を確認してください。' }
        end
        RedmineSlackNotification.slack_api('entity.presentDetails', request, token, form: true)
      end
    end

    def update_issue(issue, viewer, assigned_to_id: nil, status_id: nil, comment: nil)
      previous_user = User.current
      User.current = viewer
      issue.with_lock do
        next :restricted unless issue.project.active? && !issue.is_private? && issue.visible?(viewer) &&
                                actions_enabled?(issue)
        attrs = {}
        if assigned_to_id
          next :restricted unless issue.attributes_editable?(viewer) && issue.safe_attribute?('assigned_to_id', viewer) &&
                                  issue.assignable_users.include?(viewer)
          attrs['assigned_to_id'] = assigned_to_id.to_s unless issue.assigned_to_id == assigned_to_id
        end
        if status_id
          next :restricted unless issue.attributes_editable?(viewer) && issue.safe_attribute?('status_id', viewer) &&
                                  issue.new_statuses_allowed_to(viewer).any? { |status| status.id.to_s == status_id.to_s }
          attrs['status_id'] = status_id.to_s unless issue.status_id.to_s == status_id.to_s
        end
        note = comment.to_s.strip
        next :restricted if !note.empty? && !issue.notes_addable?(viewer)
        next :unchanged if attrs.empty? && note.empty?
        issue.init_journal(viewer, note)
        issue.send(:safe_attributes=, attrs, viewer) unless attrs.empty?
        issue.save! ? :saved : :restricted
      end
    rescue ActiveRecord::RecordInvalid
      :restricted
    ensure
      User.current = previous_user
    end
  end
end
