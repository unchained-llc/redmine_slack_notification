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

    # Resolve only explicit mappings; display-name matching cannot authorize
    # access to Redmine data. Ambiguous, locked, or missing users are denied.
    def viewer_for(slack_id)
      return unless slack_id.to_s.match?(/\A[UW][A-Z0-9]+\z/)

      users = RedmineSlackNotification.user_mapping.map do |key, value|
        next unless value == slack_id

        User.find_by(login: key.to_s) || User.find_by(mail: key.to_s)
      end.compact.uniq { |user| user.id }
      users.first if users.length == 1 && users.first.active?
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
          request['metadata'] = Formatter.issue_work_object_details(issue)
        else
          request['error'] = { 'status' => 'restricted' }
        end
        result = RedmineSlackNotification.slack_api('entity.presentDetails', request, token, form: true)
        Rails.logger&.info("RedmineSlackNotification: Work Object details issue=#{issue.id} result=#{allowed ? 'shown' : 'restricted'} warnings=#{Array(result['warnings']).inspect} messages=#{Array(result.dig('response_metadata', 'messages')).inspect}")
        result
      end
    end
  end
end
