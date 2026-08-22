# frozen_string_literal: true

require_relative 'formatter'

module UnchainedSlack
  module JournalPatch
    def self.included(base)
      Rails.logger.warn('UnchainedSlack: Journal callback registered')
      base.after_create :notify_slack_journal_created
    end

    private

    def notify_slack_journal_created
      Rails.logger.warn("UnchainedSlack: Journal ##{id} callback invoked")
      issue = journalized
      return unless issue.is_a?(Issue)

      payload = UnchainedSlack::Formatter.issue_payload(
        issue,
        actor: user,
        action: 'updated',
        details: details,
        notes: notes
      )
      UnchainedSlack.notify(payload, project: issue.project)
    end
  end
end
