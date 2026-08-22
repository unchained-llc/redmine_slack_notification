# frozen_string_literal: true

require_relative 'formatter'

module RedmineSlackNotification
  module JournalPatch
    def self.included(base)
      Rails.logger.warn('RedmineSlackNotification: Journal callback registered')
      base.after_create :notify_slack_journal_created
    end

    private

    def notify_slack_journal_created
      Rails.logger.warn("RedmineSlackNotification: Journal ##{id} callback invoked")
      issue = journalized
      return unless issue.is_a?(Issue)
      return if issue.is_private? || private_notes?

      payload = if notes.to_s.strip.present?
                  RedmineSlackNotification::Formatter.journal_payload(
                    issue,
                    actor: user,
                    notes: notes,
                    occurred_at: created_on,
                    details: details
                  )
                elsif details.any?
                  RedmineSlackNotification::Formatter.issue_payload(
                    issue,
                    actor: user,
                    action: 'updated',
                    details: details,
                    occurred_at: created_on
                  )
                else
                  return
                end
      RedmineSlackNotification.enqueue(payload, project: issue.project)
    end
  end
end
