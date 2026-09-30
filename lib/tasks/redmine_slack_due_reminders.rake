# frozen_string_literal: true

namespace :redmine do
  namespace :slack do
    desc 'Queue daily Slack DM digests for assigned open issues approaching or past due'
    task due_reminders: :environment do
      user_id = ENV['USER_ID']
      if user_id
        abort 'USER_ID must be a positive Redmine user ID' unless user_id.match?(/\A[1-9]\d*\z/)

        user_id = user_id.to_i
        abort "Redmine user ##{user_id} not found" unless User.exists?(id: user_id)
      end

      today = Date.current
      max_days = RedmineSlackNotification.due_reminder_max_days_before
      scope = Issue.joins(:status).where(issue_statuses: { is_closed: false })
                   .where.not(assigned_to_id: nil)
                   .where('issues.due_date <= ?', today + max_days)
      scope = scope.where(assigned_to_id: user_id) if user_id
      user_ids = []
      scope.find_each do |issue|
        settings = RedmineSlackNotification.due_reminder_settings(issue.project)
        next unless settings[:enabled] && issue.due_date <= today + settings[:days_before]

        user_ids << issue.assigned_to_id
      end
      recipients = user_ids.uniq
      recipients.each { |id| RedmineSlackDueDigestJob.perform_later(id, today.iso8601) }
      recipient = user_id ? " (Redmine user ##{user_id})" : ''
      message = "RedmineSlackNotification: queued #{recipients.length} due reminder digest jobs for #{today}#{recipient}"
      Rails.logger.info(message)
      puts message if user_id
    end
  end
end
