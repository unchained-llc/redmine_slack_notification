# frozen_string_literal: true

namespace :redmine do
  namespace :slack do
    desc 'Queue Slack due reminders (days, tracker, project, users/USERS, version)'
    task due_reminders: :environment do
      abort 'USER_ID is unsupported; use users or USERS' if ENV.key?('USER_ID')
      abort 'Specify only one of users or USERS' if ENV.key?('users') && ENV.key?('USERS')

      options = {}
      if ENV.key?('days')
        days = Integer(ENV.fetch('days'), exception: false)
        abort 'days must be a nonnegative integer' unless days && days >= 0

        options['days'] = days
      end
      if ENV.key?('tracker')
        tracker_id = Integer(ENV.fetch('tracker'), exception: false)
        abort 'tracker must be an existing tracker ID' unless tracker_id && tracker_id.positive? && Tracker.exists?(id: tracker_id)

        options['tracker_id'] = tracker_id
      end
      if ENV.key?('project')
        project = ENV.fetch('project').strip
        abort 'project must be an existing project ID or identifier' if project.empty?

        options['project_id'] = Project.find(project).id
      end
      if ENV.key?('version')
        version = ENV.fetch('version').strip
        abort 'version must be an existing target version name' if version.empty?

        version_ids = Version.named(version).pluck(:id)
        abort "Target version #{version.inspect} not found" if version_ids.empty?

        options['version_ids'] = version_ids
      end

      filter = %w[users USERS].find { |name| ENV.key?(name) }
      requested_ids = nil
      if filter
        ids = ENV.fetch(filter).split(',', -1).map(&:strip)
        unless ids.any? && ids.all? { |id| id.match?(/\A[1-9]\d*\z/) }
          abort "#{filter} must contain positive Redmine user IDs separated by commas"
        end

        requested_ids = ids.map(&:to_i).uniq
        missing_id = requested_ids.find { |id| !User.exists?(id: id) }
        abort "Redmine user ##{missing_id} not found" if missing_id
      end

      today = Date.current
      max_days = options.fetch('days') { RedmineSlackNotification.due_reminder_max_days }
      scope = Issue.joins(:status).where(issue_statuses: { is_closed: false })
                   .where.not(assigned_to_id: nil)
                   .where('issues.due_date <= ?', today + max_days)
      scope = scope.where(assigned_to_id: requested_ids) if requested_ids
      scope = RedmineSlackNotification.due_reminder_filter_scope(scope, options)
      user_ids = []
      scope.find_each do |issue|
        settings = RedmineSlackNotification.due_reminder_settings(issue.project)
        next unless settings[:enabled] && issue.due_date <= today + options.fetch('days', settings[:days])

        user_ids << issue.assigned_to_id
      end
      recipients = user_ids.uniq
      recipients.each { |id| RedmineSlackDueDigestJob.perform_later(id, today.iso8601, options) }
      recipient = requested_ids ? " (Redmine users #{requested_ids.map { |id| "##{id}" }.join(', ')})" : ''
      message = "RedmineSlackNotification: queued #{recipients.length} due reminder digest jobs for #{today}#{recipient}"
      Rails.logger.info(message)
      puts message if requested_ids || options.any?
    end
  end
end
