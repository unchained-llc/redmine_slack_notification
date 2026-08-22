# frozen_string_literal: true

require_relative 'formatter'

module UnchainedSlack
  module IssuePatch
    def self.included(base)
      Rails.logger.warn('UnchainedSlack: Issue callback registered')
      base.after_create :notify_slack_issue_created
    end

    private

    def notify_slack_issue_created
      UnchainedSlack.notify(
        UnchainedSlack::Formatter.issue_payload(self, actor: author, action: 'created'),
        project: self.project
      )
    end
  end
end
