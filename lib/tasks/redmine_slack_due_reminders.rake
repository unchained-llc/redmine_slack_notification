# frozen_string_literal: true

namespace :redmine do
  namespace :slack do
    desc 'Queue daily Slack DM digests for assigned open issues approaching or past due'
    task due_reminders: :environment do
      filters = %w[USERS users USER_ID].select { |name| ENV.key?(name) }
      abort 'Specify only one of USERS, users, or USER_ID' if filters.length > 1

      filter = filters.first
      requested_ids = nil
      if filter
        ids = ENV.fetch(filter).split(',', -1).map(&:strip)
        unless ids.any? && ids.all? { |id| id.match?(/\A[1-9]\d*\z/) } &&
               (filter != 'USER_ID' || ids.length == 1)
          abort "#{filter} must contain positive Redmine user IDs separated by commas"
        end

        requested_ids = ids.map(&:to_i).uniq
        missing_id = requested_ids.find { |id| !User.exists?(id: id) }
        abort "Redmine user ##{missing_id} not found" if missing_id
      end

      today = Date.current
      max_days = RedmineSlackNotification.due_reminder_max_days_before
      scope = Issue.joins(:status).where(issue_statuses: { is_closed: false })
                   .where.not(assigned_to_id: nil)
                   .where('issues.due_date <= ?', today + max_days)
      scope = scope.where(assigned_to_id: requested_ids) if requested_ids
      user_ids = []
      scope.find_each do |issue|
        settings = RedmineSlackNotification.due_reminder_settings(issue.project)
        next unless settings[:enabled] && issue.due_date <= today + settings[:days_before]

        user_ids << issue.assigned_to_id
      end
      recipients = user_ids.uniq
      recipients.each { |id| RedmineSlackDueDigestJob.perform_later(id, today.iso8601) }
      recipient = requested_ids ? " (Redmine users #{requested_ids.map { |id| "##{id}" }.join(', ')})" : ''
      message = "RedmineSlackNotification: queued #{recipients.length} due reminder digest jobs for #{today}#{recipient}"
      Rails.logger.info(message)
      puts message if requested_ids
    end
  end
end
