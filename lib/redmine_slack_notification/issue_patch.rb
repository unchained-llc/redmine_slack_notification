# frozen_string_literal: true

require_relative 'formatter'

module RedmineSlackNotification
  module IssuePatch
    def self.included(base)

      base.after_create :notify_slack_issue_created
      base.after_destroy :notify_slack_issue_deleted
    end

    private

    def notify_slack_issue_created
      return if is_private?

      RedmineSlackNotification.enqueue(
        RedmineSlackNotification::Formatter.issue_payload(self, actor: author, action: 'created'),
        project: self.project, event: 'issue_created'
      )
    end

    def notify_slack_issue_deleted
      return if is_private?

      RedmineSlackNotification.enqueue(
        RedmineSlackNotification::Formatter.issue_payload(self, actor: User.current, action: 'deleted'),
        project: self.project, event: 'issue_deleted'
      )
    end
  end
end
