# frozen_string_literal: true

class RedmineSlackDueDigestJob < ApplicationJob
  queue_as :slack

  MAX_ISSUES_PER_MESSAGE = 100

  def perform(user_id, scheduled_on, filters = nil)
    today = Date.current
    return unless scheduled_on == today.iso8601

    user = User.find_by(id: user_id)
    return unless user&.active?

    filters = {} unless filters.is_a?(Hash)
    groups = due_issues_for(user, today, filters)
    groups.each do |(token, slack_user_id), issues|
      dm = RedmineSlackNotification.slack_api('conversations.open', { 'users' => slack_user_id }, token)
      channel = dm.dig('channel', 'id')
      raise "Slack conversations.open returned no DM channel for Redmine user ##{user.id}" unless channel.to_s.match?(/\AD[A-Z0-9]+\z/)

      sorted = issues.sort_by { |issue| [issue.due_date, issue.project.name, issue.id] }
      sorted.each_slice(MAX_ISSUES_PER_MESSAGE).with_index do |batch, index|
        sleep(1) if index.positive?
        payload = RedmineSlackNotification.with_project(batch.first.project) do
          RedmineSlackNotification::Formatter.due_digest_payload(batch, today: today, part: index + 1,
                                                                  total_parts: (sorted.size + MAX_ISSUES_PER_MESSAGE - 1) / MAX_ISSUES_PER_MESSAGE)
        end
        RedmineSlackNotification.post_message(payload, channel, token)
      end
    end
  end

  private

  def due_issues_for(user, today, filters = {})
    max_days = filters.fetch('days') { RedmineSlackNotification.due_reminder_max_days_before }
    issues = Issue.joins(:status).where(issue_statuses: { is_closed: false })
                  .where(assigned_to_id: user.id)
                  .where('issues.due_date <= ?', today + max_days)
                  .includes(:project)
    issues = RedmineSlackNotification.due_reminder_filter_scope(issues, filters)
    groups = Hash.new { |hash, key| hash[key] = [] }
    issues.find_each do |issue|
      project = issue.project
      settings = RedmineSlackNotification.due_reminder_settings(project)
      next unless settings[:enabled] && issue.due_date <= today + filters.fetch('days', settings[:days_before])
      next unless project.active? && issue.visible?(user)
      RedmineSlackNotification.with_project(project) do
        token = RedmineSlackNotification.bot_token(project)
        slack_user_id = RedmineSlackNotification.slack_user_id_for(user)
        unless token.present? && slack_user_id
          Rails.logger.warn("RedmineSlackNotification: due reminder skipped for issue ##{issue.id} (token or Slack user mapping missing)")
          next
        end

        groups[[token, slack_user_id]] << issue
      end
    end
    groups
  end
end
